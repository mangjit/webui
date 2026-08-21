#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - package management
# System packages (apt in Ubuntu proot / pkg in Termux) and Python packages
# via uv (prebuilt wheels only by default; source builds are last resort).
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# System package manager dispatch
# ---------------------------------------------------------------------------
sys_cmd() {
  # sys_cmd update|install <args...>
  local op="$1"; shift
  case "$HW_ENV_KIND" in
    termux)
      if [[ "$op" == "update" ]]; then
        run_logged pkg-update pkg update -y
      else
        run_logged pkg-install pkg install -y "$@"
      fi
      ;;
    *)
      if [[ "$op" == "update" ]]; then
        run_logged apt-update env DEBIAN_FRONTEND=noninteractive apt-get update -y
      else
        run_logged apt-install env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      fi
      ;;
  esac
}

# Ubuntu renamed some packages (t64 transition: libmagic1 -> libmagic1t64,
# libssl3 -> libssl3t64, ...). If the requested name is not installed but its
# t64 counterpart is, treat it as satisfied.
pkg_aliases() {
  case "$1" in
    libmagic1)   echo "libmagic1t64" ;;
    libssl3)     echo "libssl3t64" ;;
    *)           echo "" ;;
  esac
}

sys_pkg_installed() {
  # sys_pkg_installed <pkg> -> 0 if installed
  local pkg="$1" alias
  dpkg -s "$pkg" >/dev/null 2>&1 && return 0
  alias="$(pkg_aliases "$pkg")"
  [[ -n "$alias" ]] && dpkg -s "$alias" >/dev/null 2>&1
}

sys_update_once() {
  if [[ "${SYS_UPDATED:-0}" != "1" ]]; then
    ow_step "Updating system package indexes"
    if is_dry_run; then dry_msg "apt-get/pkg update"; else
      retry 3 5 sys_cmd update || ow_warn "system package index update failed (continuing)"
    fi
    SYS_UPDATED=1
  fi
}

sys_install() {
  # sys_install <pkg> [required|optional]  (default required)
  local pkg="$1" kind="${2:-required}"
  if sys_pkg_installed "$pkg"; then
    ow_ok "system package present: $pkg"
    return 0
  fi
  sys_update_once
  ow_info "installing system package: $pkg"
  if is_dry_run; then dry_msg "apt-get/pkg install -y $pkg"; return 0; fi
  if sys_cmd install "$pkg"; then
    if sys_pkg_installed "$pkg"; then ow_ok "installed system package: $pkg"; return 0; fi
    ow_warn "package '$pkg' reported success but is not installed"
  else
    if [[ "$kind" == "optional" ]]; then
      ow_warn "optional system package '$pkg' failed to install (continuing)"
      return 0
    fi
    ow_warn "system package '$pkg' failed to install"
    return 1
  fi
}

install_system_packages() {
  ow_step "Installing system packages (prebuilt via apt/pkg)"
  local pkg
  case "$HW_ENV_KIND" in
    termux)
      for pkg in "${TERMUX_BASE_PKGS[@]+"${TERMUX_BASE_PKGS[@]}"}"; do sys_install "$pkg" required || true; done
      ;;
    *)
      for pkg in "${APT_BASE_PKGS[@]+"${APT_BASE_PKGS[@]}"}"; do sys_install "$pkg" required || true; done
      for pkg in "${APT_RUNTIME_PKGS[@]+"${APT_RUNTIME_PKGS[@]}"}"; do sys_install "$pkg" required || true; done
      # Optional extras on capable profiles only
      case "$INSTALL_PROFILE" in
        full|standard)
          for pkg in "${APT_OPTIONAL_PKGS[@]+"${APT_OPTIONAL_PKGS[@]}"}"; do sys_install "$pkg" optional || true; done
          ;;
        *) ow_info "skipping optional system packages (profile $INSTALL_PROFILE)" ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------------------
# uv bootstrap (astral python manager)
# ---------------------------------------------------------------------------
# A usable uv for this installer must be able to download & run glibc
# CPython builds for the current environment. The Termux TUR uv is built for
# bionic/aarch64-linux-android and CANNOT fetch Linux CPython ("No download
# found for request: cpython-3.11-linux-aarch64-none"), so inside proot/linux
# we must reject it and use the official astral installer instead.
uv_platform_ok() {
  local uv="$1" plat
  plat="$("$uv" version --output-format json 2>/dev/null | sed -n 's/.*"version_info".*//p')"
  if [[ -z "$plat" ]]; then
    plat="$("$uv" --version 2>&1)"
  fi
  [[ "$plat" != *"aarch64-linux-android"* && "$plat" != *"linux-android"* && "$plat" != *"android"* ]]
}

ensure_uv() {
  # Discover an existing uv (PATH or the standard install dirs) first.
  local candidate
  candidate="$(command -v uv 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && ! uv_platform_ok "$candidate"; then
    ow_warn "found Termux/TUR uv ($("$candidate" --version 2>/dev/null || echo '?')); it cannot manage Linux Python inside proot - using the official uv instead"
    candidate=""
  fi
  if [[ -z "$candidate" && -x "$HOME/.local/bin/uv" ]] && uv_platform_ok "$HOME/.local/bin/uv"; then
    candidate="$HOME/.local/bin/uv"
  fi
  if [[ -z "$candidate" && -n "${XDG_BIN_HOME:-}" && -x "$XDG_BIN_HOME/uv" ]] && uv_platform_ok "$XDG_BIN_HOME/uv"; then
    candidate="$XDG_BIN_HOME/uv"
  fi
  if [[ -n "$candidate" ]]; then
    UV_BIN="$candidate"
    export PATH="$(dirname "$candidate"):$PATH"
    ow_ok "uv found: $("$(uv_bin)" --version 2>/dev/null || echo '?')"
    export UV_LINK_MODE="${UV_LINK_MODE:-copy}"
    return 0
  fi

  ow_step "Installing uv (astral python manager)"
  if is_dry_run; then
    dry_msg "curl -LsSf https://astral.sh/uv/install.sh | sh"
    UV_BIN="$HOME/.local/bin/uv"
  else
    require_cmd curl
    # TUR ships a prebuilt uv on Termux; prefer it there.
    if [[ "$HW_ENV_KIND" == "termux" ]]; then
      if pkg install -y uv >/dev/null 2>&1 && command -v uv >/dev/null 2>&1; then
        UV_BIN="$(command -v uv)" && ow_ok "uv installed from TUR"
        export UV_LINK_MODE="${UV_LINK_MODE:-copy}"
        return 0
      fi
    fi
    retry 3 5 bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' \
      || ow_die "failed to install uv. Check network access to astral.sh and retry."
    UV_BIN="$HOME/.local/bin/uv"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  export UV_LINK_MODE="${UV_LINK_MODE:-copy}"
  export UV_NO_UPDATE_CHECK="${UV_NO_UPDATE_CHECK:-1}"
  ow_ok "uv ready: $("$(uv_bin)" --version 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# Python detection & managed interpreter
# ---------------------------------------------------------------------------
ensure_python() {
  ow_step "Ensuring Python $OWI_PYTHON (uv-managed)"
  if is_dry_run; then
    dry_msg "uv python install $OWI_PYTHON"
    PY_BIN="$VENV_DIR/bin/python"
    return 0
  fi

  local want="${OWI_PYTHON}"
  # Already managed & matching?
  if "$(uv_bin)" python list --only-installed 2>/dev/null | grep -qE "^python-${want//./\\.}"; then
    ow_ok "uv already manages Python $want"
  else
    "$(uv_bin)" python install "$want" || ow_die "failed to install Python $want via uv"
  fi
}

# Decide whether an existing venv can be adopted.
venv_healthy() {
  # venv_healthy <venv-dir> -> 0 if it looks like a working open-webui venv
  local v="$1"
  [[ -x "$v/bin/python" ]] || return 1
  [[ -f "$v/pyvenv.cfg" ]] || return 1
  python_version_of "$v/bin/python" | grep -q "^${OWI_PYTHON}" || return 1
  [[ -n "$(open_webui_version_of "$v/bin/python")" ]] || return 1
  "$v/bin/python" -c 'import open_webui' >/dev/null 2>&1 || return 1
  return 0
}

ensure_venv() {
  ow_step "Preparing virtual environment"
  ensure_dir "$OWI_INSTALL_DIR"

  if [[ -d "$VENV_DIR" ]]; then
    if venv_healthy "$VENV_DIR"; then
      ow_ok "adopting existing healthy venv: $VENV_DIR"
      return 0
    fi
    ow_warn "existing venv is broken or mismatched; rebuilding it"
    if ! is_dry_run; then
      local bak="$VENV_DIR.broken.$(date -u +%s)"
      mv "$VENV_DIR" "$bak" || ow_warn "could not move old venv aside"
    fi
  fi

  if is_dry_run; then
    dry_msg "uv venv $VENV_DIR --python $OWI_PYTHON"
    return 0
  fi
  "$(uv_bin)" venv "$VENV_DIR" --python "$OWI_PYTHON" \
    || ow_die "failed to create virtual environment (uv venv)"
  ow_ok "created venv: $VENV_DIR ($(python_version_of "$VENV_DIR/bin/python"))"
}

# ---------------------------------------------------------------------------
# pip (uv) helpers - wheels first, never build by default
# ---------------------------------------------------------------------------
pip_install() {
  # pip_install [--no-deps] <spec...>  -- wheels-only unless OWI_ALLOW_BUILD
  local extra=()
  if [[ "${OWI_ALLOW_BUILD:-0}" != "1" ]]; then extra+=(--no-build); fi
  "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" \
    "${extra[@]}" "$@" || return $?
}

pip_install_retry() {
  # First attempt wheels-only. On failure, retry allowing a source build ONLY
  # for the exact package that lacks a wheel (last resort, explicit).
  local spec="$1"; shift
  local extra=()
  if [[ "${OWI_ALLOW_BUILD:-0}" != "1" ]]; then extra+=(--no-build); fi

  if is_dry_run; then
    dry_msg "uv pip install --python $VENV_DIR/bin/python ${extra[*]} $spec $*"
    return 0
  fi

  if "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" "${extra[@]}" "$spec" "$@"; then
    return 0
  fi

  # --- retry ladder -----------------------------------------------------------
  local logfile="$LOG_DIR/pip-fail.log"
  ensure_dir "$LOG_DIR"
  "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" "${extra[@]}" "$spec" "$@" >"$logfile" 2>&1

  local bad
  bad=$(grep -m1 -oE '(Failed to build|no matching distribution|does not have a wheel|Building .* requires)|error: Failed to download.*' "$logfile" 2>/dev/null || true)

  if [[ "${OWI_ALLOW_BUILD:-0}" == "1" ]]; then
    ow_err "pip install failed even with source builds allowed. Log: $logfile"
    return 1
  fi

  # Identify the offending package (last token before "from sdist" / "for").
  local offender
  offender=$(grep -m1 -oE '^  error: Failed to download[^\n]*' "$logfile" | sed -E 's/.*build (edist|wheel) for //' || true)
  [[ -z "$offender" ]] && offender=$(grep -m1 -oE 'would have to build .*' "$logfile" | sed -E 's/.*build [^ ]+ ([^ ]+).*/\1/' || true)

  if [[ -n "$offender" ]]; then
    ow_warn "wheel missing for '$offender'; retrying once, building ONLY that package (last resort)"
    "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build --no-build-exclude "$offender" "$spec" "$@" || {
      ow_err "still failed after allowing a source build of '$offender'. Log: $logfile"
      return 1
    }
    return 0
  fi

  ow_err "pip install failed (wheels only). Log: $logfile"
  ow_warn "If a package has no prebuilt wheel for $(uname -m), either use the 'light' profile"
  ow_warn "(minimal dependencies) or pass --allow-build to permit compiling as a last resort."
  return 1
}

pip_check() {
  # pip_check -> 0 if dependency graph is consistent
  "$(uv_bin)" pip check --python "$VENV_DIR/bin/python" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Startup import test: can the full app module tree be imported?
# (This is what actually breaks when a runtime dependency is missing.)
# ---------------------------------------------------------------------------
import_startup_err() {
  # prints the output of `import open_webui.main` only when the import FAILS.
  # (open-webui prints its banner and warnings to stderr even on success, so
  #  the exit code - not stderr emptiness - is the success signal.)
  local out rc
  out="$(WEBUI_SECRET_KEY=health-check "$VENV_DIR/bin/python" -c 'import open_webui.main' 2>&1)"
  rc=$?
  [[ $rc -eq 0 ]] && return 0
  printf '%s\n' "$out"
  return 1
}

import_startup_ok() {
  local out
  out="$(import_startup_err)"
  [[ -z "$out" ]]
}

# Install the curated min-patch, then self-discover anything a future release
# adds by repeatedly importing until success or we run out of attempts.
install_min_patch() {
  if is_dry_run; then
    dry_msg "uv pip install --no-build ${MIN_PATCH_DISTS[*]}"
    dry_msg "self-discovering missing startup imports"
    return 0
  fi
  local d
  for d in "${MIN_PATCH_DISTS[@]+"${MIN_PATCH_DISTS[@]}"}"; do
    "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build "$d" >/dev/null 2>&1 \
      || ow_warn "could not install patched runtime dep: $d"
  done

  local i mod dist err tried=""
  for ((i = 1; i <= 20; i++)); do
    if import_startup_ok; then return 0; fi
    err="$(import_startup_err)"
    # The failing import statement is the line right before the error.
    mod="$(printf '%s\n' "$err" | grep -B1 -E 'ModuleNotFoundError|ImportError' | grep -E '^.*from |^.*import ' | tail -1 | grep -oP 'from \K[^ ]+')"
    [[ -z "$mod" ]] && mod="$(printf '%s\n' "$err" | grep -m1 -oP "No module named '\K[^']+")"
    [[ -z "$mod" ]] && { ow_err "cannot parse startup import failure:"; printf '%s\n' "$err" | tail -5 | sed 's/^/    /'; return 1; }
    dist="$(dist_for_module "$mod")"
    if [[ "$dist" == "open-webui" ]]; then
      ow_err "open-webui itself fails to import on the light profile"
      return 1
    fi
    if printf '%s\n' "$tried" | grep -qxF "$dist"; then
      ow_err "re-installing '$dist' did not fix the startup import; giving up"
      printf '%s\n' "$err" | tail -8 | sed 's/^/    /'
      return 1
    fi
    tried="${tried:+$tried
}$dist"
    ow_info "light profile: adding missing startup dependency: $dist (module '$mod')"
    # Force a reinstall: plain install is a no-op when the dist is already
    # present but corrupted (e.g. someone moved/removed its files).
    "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build \
      $(for d in $dist; do printf -- '--reinstall-package %s ' "$d"; done) \
      $dist >/dev/null 2>&1 \
      || { ow_err "failed to install '$dist' (startup dependency)"; return 1; }
  done
  ow_err "startup import still failing after $i attempts; consider the full profile"
  return 1
}

pip_freeze() { "$(uv_bin)" pip freeze --python "$VENV_DIR/bin/python" 2>/dev/null; }

write_lock() {
  if is_dry_run; then dry_msg "write dependency lock -> $LOCK_FILE"; return 0; fi
  ensure_dir "$OWI_INSTALL_DIR"
  pip_freeze | sort > "$LOCK_FILE" || return 1
  ow_ok "wrote dependency lock: $LOCK_FILE ($(wc -l < "$LOCK_FILE") packages)"
}

pip_sync_lock() {
  # Make the venv exactly match the lock (repair hammer).
  if [[ -f "$LOCK_FILE" ]]; then
    ow_info "syncing venv to lock file"
    if is_dry_run; then dry_msg "uv pip sync $LOCK_FILE"; return 0; fi
    "$(uv_bin)" pip sync --python "$VENV_DIR/bin/python" "$LOCK_FILE" || ow_warn "pip sync failed"
  else
    ow_warn "no lock file yet; cannot sync"
  fi
}

# ---------------------------------------------------------------------------
# Open WebUI install (the heavy lifting)
# ---------------------------------------------------------------------------
fetch_requirements_min() {
  # Fetch the official minimal requirements for a given open-webui version.
  local ver="$1" url
  if is_dry_run; then
    dry_msg "curl https://raw.githubusercontent.com/open-webui/open-webui/v${ver}/backend/requirements-min.txt"
    return 0
  fi
  for url in \
    "https://raw.githubusercontent.com/open-webui/open-webui/v${ver}/backend/requirements-min.txt" \
    "https://raw.githubusercontent.com/open-webui/open-webui/main/backend/requirements-min.txt"; do
    if curl -fsSL --max-time 30 "$url" -o "$MIN_REQ_FILE" 2>/dev/null; then
      ow_ok "fetched requirements-min.txt ($url)"
      return 0
    fi
  done
  ow_warn "could not fetch requirements-min.txt for v$ver (light profile needs it)"
  return 1
}

install_openwebui() {
  # install_openwebui <version-or-latest>
  local ver="$1"
  local spec="open-webui"
  [[ "$ver" != "latest" ]] && spec="open-webui==$ver"

  ow_step "Installing Open WebUI ($ver, profile=$INSTALL_PROFILE)"

  if [[ "$INSTALL_PROFILE" == "full" || "$INSTALL_PROFILE" == "standard" ]]; then
    # Full dependency tree, prebuilt wheels only.
    pip_install_retry "$spec" "${PIP_EXTRAS_FULL[@]+"${PIP_EXTRAS_FULL[@]}"}" \
      || ow_die "Open WebUI install failed (see logs)."
    [[ -n "${OWI_WITH_EXTRAS:-}" ]] && {
      ow_info "installing user extras: $OWI_WITH_EXTRAS"
      # shellcheck disable=SC2086
      pip_install_retry $OWI_WITH_EXTRAS || ow_warn "some user extras failed to install"
    }
  else
    # light / minimal: open-webui without its heavy dependency tree,
    # then the official minimal requirements (still wheels-only).
    ow_info "light profile: installing open-webui without heavy deps, then requirements-min.txt"
    pip_install_retry "$spec" --no-deps || ow_die "open-webui (no-deps) install failed."
    local minver="$ver"
    if [[ "$minver" == "latest" ]]; then
      if is_dry_run; then
        minver="current"
      else
        minver="$(open_webui_version_of "$VENV_DIR/bin/python")"
      fi
    fi
    fetch_requirements_min "$minver" || ow_die "cannot obtain minimal requirements for light profile"
    if ! is_dry_run; then
      "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build -r "$MIN_REQ_FILE" \
        || { ow_err "minimal requirements install failed (see $LOG_DIR/install.log)"; return 1; }
    else
      dry_msg "uv pip install --no-build -r $MIN_REQ_FILE"
    fi
    # The official min file alone is not enough to import the app; patch it
    # with the curated set and self-discover anything else a release needs.
    install_min_patch || return 1
  fi

  # Write the exact lock regardless of profile (soft failure - not fatal).
  write_lock || ow_warn "could not write lock file"
  return 0
}

verify_openwebui_installed() {
  if is_dry_run; then
    ow_ok "would verify open-webui importability in $VENV_DIR/bin/python"
    return 0
  fi
  local v
  v="$(open_webui_version_of "$VENV_DIR/bin/python")"
  [[ -z "$v" ]] && { ow_err "open-webui is not importable after install"; return 1; }
  ow_ok "open-webui $v installed (Python $(python_version_of "$VENV_DIR/bin/python"))"
  INSTALLED_OWUI_VERSION="$v"
  return 0
}
