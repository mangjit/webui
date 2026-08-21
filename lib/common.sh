#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - common library
# Logging, error handling, retries, state file, checksums, dry-run plumbing.
# Sourced by every entry script and library. Safe to source multiple times.
# ============================================================================

if [[ "${OWI_COMMON_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
OWI_COMMON_LOADED=1

# --- Locate project root (dir containing conf/, lib/, install.sh) ------------
OWI_COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
if [[ "$(basename -- "$OWI_COMMON_DIR")" == "lib" ]]; then
  OWI_ROOT_DIR="${OWI_ROOT_DIR:-$(cd -- "$OWI_COMMON_DIR/.." &>/dev/null && pwd)}"
else
  OWI_ROOT_DIR="${OWI_ROOT_DIR:-$OWI_COMMON_DIR}"
fi
OWI_LIB_DIR="$OWI_ROOT_DIR/lib"
OWI_CONF_DIR="$OWI_ROOT_DIR/conf"

# --- Load configuration -------------------------------------------------------
# shellcheck source=conf/installer.conf
source "$OWI_CONF_DIR/installer.conf"

# --- Strict-ish shell (errors are handled explicitly, not by set -e) ---------
# set -u: undefined variables are bugs. pipefail: catch pipeline failures.
set -uo pipefail

# --- Derived paths ------------------------------------------------------------
VENV_DIR="$OWI_INSTALL_DIR/venv"
ENV_FILE="$OWI_INSTALL_DIR/open_webui.env"
STATE_FILE="$OWI_INSTALL_DIR/state.conf"
LOCK_FILE="$OWI_INSTALL_DIR/requirements.lock"
REQUIREMENTS_FILE="$OWI_INSTALL_DIR/requirements.txt"
MIN_REQ_FILE="$OWI_INSTALL_DIR/requirements-min.txt"
LOG_DIR="$OWI_INSTALL_DIR/logs"
BACKUP_DIR="$OWI_INSTALL_DIR/backups"
SECRET_KEY_FILE="$OWI_INSTALL_DIR/webui.secret"
PID_FILE="$OWI_INSTALL_DIR/openwebui.pid"
RUNNER_SCRIPT="$OWI_INSTALL_DIR/run-server.sh"
WATCHDOG_STOP_FILE="$OWI_INSTALL_DIR/.stop-watchdog"

# --- Terminal colours (best effort) -------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

# --- Logging ------------------------------------------------------------------
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

ow_log()  { printf '%s\n' "[$(now_iso)] $*" | tee -a "${LOG_DIR:-/tmp}/install.log" >&2; }
ow_info() { ow_log "${C_CYAN}${C_BOLD}[i]${C_RESET} $*"; }
ow_ok()   { ow_log "${C_GREEN}${C_BOLD}[ok]${C_RESET} $*"; }
ow_warn() { ow_log "${C_YELLOW}${C_BOLD}[warn]${C_RESET} $*"; }
ow_err()  { ow_log "${C_RED}${C_BOLD}[error]${C_RESET} $*"; }
ow_step() { ow_log "${C_BOLD}==== $* ====${C_RESET}"; }

ow_die()  { ow_err "$*"; exit 1; }

# --- Dry-run plumbing -----------------------------------------------------------
is_dry_run() { [[ "${OWI_DRY_RUN:-0}" == "1" ]]; }
dry_msg()    { printf '%s\n' "${C_DIM}[dry-run] would run: $*${C_RESET}" | tee -a "${LOG_DIR:-/tmp}/install.log" >&2; }

# Run a command if real, else print what would run. Returns 0 either way.
run_if_real() {
  if is_dry_run; then dry_msg "$*"; return 0; fi
  "$@"
}

# --- Prompts -------------------------------------------------------------------
confirm() {
  # confirm "question" -> 0 if yes
  local q="$1"
  if [[ "${OWI_YES:-0}" == "1" ]]; then return 0; fi
  if is_dry_run; then return 0; fi
  printf '%s %s' "$q" "[y/N] "
  local ans
  read -r ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- Command helpers -------------------------------------------------------------
require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || ow_die "required command not found: $c (install it first)"
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d" || ow_die "cannot create directory: $d"
}

is_root() { [[ "$(id -u)" == "0" ]]; }

# retry N SLEEP_S CMD...  -> runs CMD up to N times, sleeping between attempts
retry() {
  local n="$1" sleep_s="$2"; shift 2
  local i rc=1
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    rc=$?
    if ((i < n)); then ow_warn "attempt $i/$n failed (rc=$rc); retrying in ${sleep_s}s"; sleep "$sleep_s"; fi
  done
  return "$rc"
}

# run_logged TAG CMD... -> runs CMD, tees output to $LOG_DIR/TAG.log, returns rc
run_logged() {
  local tag="$1"; shift
  ensure_dir "$LOG_DIR"
  local logf="$LOG_DIR/$tag.log"
  if is_dry_run; then dry_msg "$*"; return 0; fi
  "$@" 2>&1 | tee -a "$logf"
  return "${PIPESTATUS[0]}"
}

# --- State file (key=value, sourced as bash) --------------------------------------
state_get() { local k="$1"; sed -n "s/^${k}=//p" "$STATE_FILE" 2>/dev/null | tail -1; }
state_set() { ensure_dir "$OWI_INSTALL_DIR"; grep -q "^$1=" "$STATE_FILE" 2>/dev/null && sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE" || printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE"; }
state_del() { [[ -f "$STATE_FILE" ]] && sed -i "/^$1=/d" "$STATE_FILE"; }

# --- Checksums ---------------------------------------------------------------------
sha256_file() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
hash_text()   { printf '%s' "$*" | sha256sum | awk '{print $1}'; }

# --- Filesystem ---------------------------------------------------------------------
free_mb()   { local p="$1"; df -Pk "$p" 2>/dev/null | awk 'NR==2{print int($4/1024)}'; }
total_mb()  { local p="$1"; df -Pk "$p" 2>/dev/null | awk 'NR==2{print int($2/1024)}'; }

human_size() {
  local mb="$1"
  if ((mb >= 1048576)); then echo "$((mb / 1048576)) TB";
  elif ((mb >= 1024)); then echo "$((mb / 1024)) GB";
  else echo "${mb} MB"; fi
}

# --- Misc -----------------------------------------------------------------------------
uv_bin() {
  # Resolve the uv executable: explicit UV_BIN, PATH, common install dirs.
  # Never errors; falls back to "uv" (so callers get a clean "not found").
  if [[ -n "${UV_BIN:-}" && -x "${UV_BIN}" ]]; then printf '%s' "$UV_BIN"; return 0; fi
  local c
  c="$(command -v uv 2>/dev/null || true)"
  if [[ -n "$c" ]]; then printf '%s' "$c"; return 0; fi
  if [[ -x "$HOME/.local/bin/uv" ]]; then printf '%s' "$HOME/.local/bin/uv"; return 0; fi
  if [[ -n "${XDG_BIN_HOME:-}" && -x "$XDG_BIN_HOME/uv" ]]; then printf '%s' "$XDG_BIN_HOME/uv"; return 0; fi
  printf 'uv'
}

python_version_of() {
  # python_version_of /path/to/python -> e.g. "3.11.9" or ""
  "$1" -c 'import sys;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || echo ""
}

# Map an imported module name to the distribution(s) that provide it.
dist_for_module() {
  local m="$1"
  case "$m" in
    mimeparse)              echo "python-mimeparse" ;;
    markdown)               echo "Markdown" ;;
    PIL)                    echo "pillow" ;;
    fpdf)                   echo "fpdf2" ;;
    cv2)                    echo "opencv-python-headless" ;;
    bs4)                    echo "beautifulsoup4" ;;
    yaml)                   echo "PyYAML" ;;
    jwt)                    echo "PyJWT" ;;
    nacl)                   echo "PyNaCl" ;;
    sentence_transformers)  echo "sentence-transformers" ;;
    faster_whisper)         echo "faster-whisper" ;;
    open_webui)             echo "open-webui" ;;
    google.cloud.*)         echo "google-cloud-storage" ;;
    googleapiclient*)       echo "google-api-python-client" ;;
    google.oauth2*|google.auth*) echo "google-auth" ;;
    azure.*)                echo "azure-identity azure-storage-blob" ;;
    *)                      echo "$m" ;;
  esac
}

open_webui_version_of() {
  # open_webui_version_of /path/to/python -> installed open-webui version or ""
  "$1" -c 'import importlib.metadata as m;print(m.version("open-webui"))' 2>/dev/null || echo ""
}

ow_banner() {
  cat >&2 <<EOF
${C_CYAN}${C_BOLD}
  ██████╗ ██████╗ ███████╗███╗   ██╗    ██╗    ██╗███████╗██████╗ ██╗   ██╗██╗
 ██╔═══██╗██╔══██╗██╔════╝████╗  ██║    ██║    ██║██╔════╝██╔══██╗██║   ██║██║
 ██║   ██║██████╔╝█████╗  ██╔██╗ ██║    ██║ █╗ ██║█████╗  ██████╔╝██║   ██║██║
 ██║   ██║██╔══██╗██╔══╝  ██║╚██╗██║    ██║███╗██║██╔══╝  ██╔══██╗██║   ██║██║
 ╚██████╔╝██║  ██║███████╗██║ ╚████║    ╚███╔███╔╝███████╗██║  ██║╚██████╔╝██║
  ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝     ╚══╝╚══╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝
${C_RESET}
${C_BOLD}${INSTALLER_NAME} v${INSTALLER_VERSION}${C_RESET}
  Self-healing auto-installer for Ubuntu Proot-Distro on Android.
  Docs: README.md   |   Run 'install.sh --help' for options.
EOF
}

# shellcheck disable=SC2034
OWI_COMMON_SOURCED=1
