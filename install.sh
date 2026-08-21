#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - main entry point
# Designed to run inside an Ubuntu Proot-Distro environment on Android
# (also works on plain Linux). Detect -> plan -> install -> verify -> run.
# Idempotent and self-healing: safe to run over and over again.
#
# Usage: ./install.sh [options]
#   -y, --yes              assume yes for all prompts
#   -n, --dry-run          simulate; change nothing
#       --report           print hardware report and exit
#       --profile <auto|full|standard|light|minimal>
#       --env <auto|proot|termux|linux>
#       --source <auto|pypi|git>
#       --port <n>         web UI port (default 8080)
#       --url <u>          public WEBUI_URL
#       --data-dir <path>  Open WebUI data directory
#       --python <3.11|3.12>
#       --with-extras "pkg pkg"
#       --with-ollama / --no-ollama
#       --openai-base-url <url>   OpenAI-compatible gateway (e.g. OmniRoute
#                                 http://127.0.0.1:20128/v1); also used for
#                                 RAG embeddings. No Ollama needed.
#       --openai-api-key <key>    gateway key (default: omni / optional)
#       --embedding-model <m>     RAG embedding model for the gateway
#       --allow-build      permit source builds as last resort
#       --version <x.y.z|latest>
#       --no-service       do not start the server at the end
#       --update           run the smart updater after installing
#       --force            bypass safety guards (e.g. 32-bit ARM)
# ============================================================================

set -uo pipefail

# --- Locate and load libraries -------------------------------------------------
OWI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/common.sh
source "$OWI_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$OWI_SCRIPT_DIR/lib/detect.sh"
# shellcheck source=lib/packages.sh
source "$OWI_SCRIPT_DIR/lib/packages.sh"
# shellcheck source=lib/config.sh
source "$OWI_SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/repair.sh
source "$OWI_SCRIPT_DIR/lib/repair.sh"
# shellcheck source=lib/service.sh
source "$OWI_SCRIPT_DIR/lib/service.sh"
# shellcheck source=lib/update-core.sh
source "$OWI_SCRIPT_DIR/lib/update-core.sh"

# --- CLI parsing --------------------------------------------------------------
usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)          OWI_YES=1 ;;
    -n|--dry-run)      OWI_DRY_RUN=1 ;;
    --report)          OWI_DO_REPORT=1 ;;
    --profile)         OWI_PROFILE="${2:?--profile needs a value}"; shift ;;
    --env)             OWI_ENV_KIND="${2:?--env needs a value}"; shift ;;
    --source)          OWI_SOURCE_MODE="${2:?--source needs a value}"; shift ;;
    --port)            OWI_PORT="${2:?--port needs a value}"; shift ;;
    --url)             OWI_URL="${2:?--url needs a value}"; shift ;;
    --data-dir)        OWI_DATA_DIR="${2:?--data-dir needs a value}"; shift ;;
    --python)          OWI_PYTHON="${2:?--python needs a value}"; shift ;;
    --with-extras)     OWI_WITH_EXTRAS="${2:?--with-extras needs a value}"; shift ;;
    --with-ollama)     OWI_OLLAMA_MODE="install" ;;
    --no-ollama)       OWI_OLLAMA_MODE="none" ;;
    --openai-base-url) OWI_OPENAI_BASE_URL="${2:?--openai-base-url needs a value}"; shift ;;
    --openai-api-key)  OWI_OPENAI_API_KEY="${2:?--openai-api-key needs a value}"; shift ;;
    --embedding-model) OWI_RAG_EMBEDDING_MODEL="${2:?--embedding-model needs a value}"; shift ;;
    --allow-build)     OWI_ALLOW_BUILD=1 ;;
    --version)         OWI_OPENWEBUI_VERSION="${2:?--version needs a value}"; shift ;;
    --no-service)      OWI_START_SERVICE=0 ;;
    --update)          OWI_RUN_UPDATE=1 ;;
    --force)           OWI_FORCE=1 ;;
    -h|--help)         usage ;;
    *)                 ow_die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# --- Pre-flight ----------------------------------------------------------------
ow_banner
ensure_dir "$LOG_DIR"
[[ "${OWI_DRY_RUN:-0}" == "1" ]] && ow_warn "DRY-RUN mode: no changes will be made"

detect_all

if [[ "${OWI_DO_REPORT:-0}" == "1" ]]; then
  print_report
  exit 0
fi

# environment sanity
case "$HW_ENV_KIND" in
  proot|linux)
    [[ "$HW_ENV_KIND" == "proot" ]] && ow_info "detected Ubuntu Proot-Distro environment"
    ;;
  termux)
    # uv-managed CPython (glibc) cannot run on Termux's bionic libc; the
    # supported path is Ubuntu under proot-distro, bootstrapped for us.
    ow_err "running inside native Termux is not supported by this installer."
    ow_err "Use the Ubuntu proot path instead, from Termux:"
    ow_err "  bash termux-bootstrap.sh"
    exit 1
    ;;
  *) ow_die "cannot determine environment (got '$HW_ENV_KIND'); use --env" ;;
esac

if [[ "$HW_ARCH_FAMILY" == "armhf" && "${OWI_FORCE:-0}" != "1" ]]; then
  ow_err "32-bit ARM is not supported: the heavy prebuilt wheels Open WebUI needs"
  ow_err "(torch, onnxruntime, pyarrow, ...) do not exist for armv7/armhf."
  ow_err "Use a 64-bit Android device (aarch64), or pass --force to attempt anyway."
  exit 1
fi

ow_step "Hardware report"
print_report

# storage check
FREE_MB="$(num_or_zero "$HW_STORAGE_FREE_MB")"
NEED_MB=$INSTALL_LIGHT_NEED_MB
case "$INSTALL_PROFILE" in full|standard) NEED_MB=$INSTALL_FULL_NEED_MB ;; esac
if (( FREE_MB > 0 && FREE_MB < NEED_MB )); then
  ow_warn "only $(human_size "$FREE_MB") free; profile '$INSTALL_PROFILE' needs ~$(human_size "$NEED_MB")"
  if [[ "${OWI_FORCE:-0}" != "1" ]]; then
    ow_err "not enough free storage. Free up space, or use a lighter profile:"
    ow_err "  ./install.sh --profile light   (needs ~$(human_size "$INSTALL_LIGHT_NEED_MB"))"
    exit 1
  fi
fi

effective_source_mode

# final confirmation
ow_step "Install plan"
printf '  environment : %s\n' "$HW_ENV_KIND"
printf '  arch        : %s (%s)\n' "$HW_ARCH" "$HW_ARCH_FAMILY"
printf '  soc / gpu   : %s / %s\n' "$HW_SOC_VENDOR" "$HW_GPU"
printf '  ram / cores : %s MB / %s\n' "$HW_RAM_MB" "$HW_CORES"
printf '  free space  : %s\n' "$(human_size "$FREE_MB")"
printf '  profile     : %s\n' "$INSTALL_PROFILE"
printf '  python      : %s (uv-managed)\n' "$OWI_PYTHON"
printf '  source mode : %s\n' "$SOURCE_MODE"
printf '  install dir : %s\n' "$OWI_INSTALL_DIR"
printf '  data dir    : %s\n' "$OWI_DATA_DIR"
printf '  port        : %s\n' "$OWI_PORT"
if [[ -n "${OWI_OPENAI_BASE_URL:-}" ]]; then
  printf '  gateway     : %s (OpenAI-compatible; Ollama not required)\n' "$OWI_OPENAI_BASE_URL"
fi
confirm "Proceed with this plan?" || { ow_info "aborted by user"; exit 1; }

# --- Phase 1: system packages ---------------------------------------------------
install_system_packages

# --- Phase 2: uv + python + venv --------------------------------------------------
ensure_uv
ensure_python
ensure_venv

# --- Phase 3: install Open WebUI ---------------------------------------------------
if [[ -n "${OWI_OPENWEBUI_VERSION:-}" && "$OWI_OPENWEBUI_VERSION" != "latest" ]]; then
  install_openwebui "$OWI_OPENWEBUI_VERSION" || ow_die "installation failed - see $LOG_DIR"
else
  latest="$(pypi_latest_version 2>/dev/null || echo latest)"
  install_openwebui "${latest:-latest}" || ow_die "installation failed - see $LOG_DIR"
fi
verify_openwebui_installed || ow_die "installed package failed verification - run ./update.sh --repair"

# Pre-compile Python bytecode (detached, best-effort): makes every later
# start faster, because imports no longer compile on first use. A partially
# completed pass is still beneficial, so we never block on it.
if ! is_dry_run && [[ "${OWI_COMPILEALL:-1}" == "1" ]] && [[ -d "$VENV_DIR/lib" ]]; then
  ow_info "pre-compiling Python bytecode in the background (one-time; speeds up every start)..."
  (
    SP="$(echo "$VENV_DIR"/lib/*/site-packages)"
    [[ -d "$SP" ]] && timeout 300 "$VENV_DIR/bin/python" -m compileall -q -j 2 "$SP" >/dev/null 2>&1
  ) &
fi

# --- Phase 4: configuration ---------------------------------------------------------
apply_env_file

# --- Phase 5: verify + self-heal -----------------------------------------------------
if ! health_check; then
  ow_warn "post-install health check found issues:"
  print_health | sed 's/^/  /'
  if ! is_dry_run; then repair_env; else ow_info "(dry-run: repair skipped)"; fi
fi

# --- Phase 6: service -----------------------------------------------------------------
if [[ "${OWI_START_SERVICE:-1}" == "1" ]]; then
  svc_start || ow_warn "service start failed; use ./openwebui-ctl logs to investigate"
fi

# --- Phase 7: record state + smart update ----------------------------------------------
write_state

if [[ "${OWI_RUN_UPDATE:-0}" == "1" ]]; then
  run_update
fi

# --- Phase 8: persist control tools inside the rootfs -----------------------------------
# When launched via termux-bootstrap.sh, the project folder is only bind-mounted
# into the container for the duration of that login session. Once it exits,
# /root/openwebui-autoinstaller disappears, so 'openwebui-ctl' would be missing
# on later logins. Copy the tools into the persistent install dir and add
# PATH-wide wrappers so control works from any fresh login.
persist_tools() {
  local dst="$OWI_INSTALL_DIR/tools"
  if is_dry_run; then
    dry_msg "copy project scripts -> $dst  (+ /usr/local/bin wrappers)"
    return 0
  fi
  ensure_dir "$dst"
  if [[ -f "$OWI_ROOT_DIR/install.sh" ]]; then
    cp -r "$OWI_ROOT_DIR/install.sh" "$OWI_ROOT_DIR/update.sh" "$OWI_ROOT_DIR/openwebui-ctl" \
          "$OWI_ROOT_DIR/termux-bootstrap.sh" "$OWI_ROOT_DIR/conf" "$OWI_ROOT_DIR/lib" "$dst/" 2>/dev/null \
      || ow_warn "could not persist control tools to $dst"
  fi
  if [[ -w /usr/local/bin ]]; then
    cat > /usr/local/bin/openwebui-ctl <<EOF
#!/bin/bash
exec bash "$dst/openwebui-ctl" "\$@"
EOF
    cat > /usr/local/bin/webui-update <<EOF
#!/bin/bash
exec bash "$dst/update.sh" "\$@"
EOF
    chmod +x /usr/local/bin/openwebui-ctl /usr/local/bin/webui-update 2>/dev/null || true
    ow_ok "control tools persisted - use 'openwebui-ctl' / 'webui-update' from any login"
  else
    ow_ok "control tools persisted at $dst"
    ow_info "(/usr/local/bin not writable; call 'bash $dst/openwebui-ctl' instead)"
  fi
}
persist_tools

# --- Done -------------------------------------------------------------------------------
ow_step "Installation complete"
printf '  Web UI    : %s\n' "http://127.0.0.1:${OWI_PORT}"
printf '  Update    : %s\n' "bash ./update.sh  (or: webui-update)"
printf '  Control   : %s\n' "openwebui-ctl {start|stop|restart|status|logs|watch}"
printf '  Logs      : %s\n' "$LOG_DIR/openwebui.log"
printf '  Data      : %s\n' "$OWI_DATA_DIR"
if [[ -n "${OWI_OPENAI_BASE_URL:-}" ]]; then
  printf '\n  Tip: Open WebUI is wired to your OpenAI-compatible gateway:\n'
  printf '       %s  (chat + RAG embeddings; no Ollama required)\n' "$OWI_OPENAI_BASE_URL"
  printf '       If models do not appear, restart with: openwebui-ctl restart\n'
elif [[ "$INSTALL_PROFILE" == "full" || "$INSTALL_PROFILE" == "standard" ]]; then
  printf '\n  Tip: local RAG embeddings (sentence-transformers) are configured.\n'
else
  printf '\n  Tip: RAG embeddings are set to use Ollama (RAG_EMBEDDING_ENGINE=ollama).\n'
  printf '       Install Ollama (termux-bootstrap.sh --with-ollama) or set an\n'
  printf '       OpenAI-compatible embedding API in %s\n' "$ENV_FILE"
fi
printf '\n  First run: create your admin account in the browser (first user = admin).\n'
