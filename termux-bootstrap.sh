#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - Termux bootstrap (run OUTSIDE proot, in Termux)
# ----------------------------------------------------------------------------
#  1. Enables useful Termux repositories: tur-repo, x11-repo, root-repo
#  2. Installs proot-distro (and uv/git prebuilt from TUR when available)
#  3. Installs the Ubuntu proot-distro image (once)
#  4. Optionally installs a native, prebuilt Ollama from TUR (aarch64)
#  5. Gathers Android device info (getprop) and hands it to the installer
#     which then runs inside Ubuntu via proot-distro login
#
# Usage (in Termux):
#   bash termux-bootstrap.sh [--with-ollama] [--distro ubuntu] [--replace]
# ============================================================================

set -uo pipefail

# --- help may be shown from anywhere --------------------------------------------
if [[ "$#" -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  echo "usage: bash termux-bootstrap.sh [--with-ollama] [--openai-base-url URL] [--openai-api-key KEY] [--replace]" >&2
  echo "  --with-ollama         install native Ollama from TUR (only if you want Ollama)" >&2
  echo "  --openai-base-url URL use an OpenAI-compatible gateway, e.g. OmniRoute:" >&2
  echo "                        http://127.0.0.1:20128/v1  (no Ollama needed)" >&2
  echo "  --replace             reinstall the Ubuntu proot-distro (deletes its filesystem)" >&2
  exit 0
fi

# --- safety: we must be inside Termux ------------------------------------------
if [[ -z "${PREFIX:-}" || ! -d "${PREFIX:-}" ]]; then
  echo "[error] This script must run inside Termux (not in a proot shell)." >&2
  echo "        Usage: bash termux-bootstrap.sh [--with-ollama] [--openai-base-url URL]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DISTRO="${DISTRO:-ubuntu}"
WITH_OLLAMA=0
REPLACE=0

OPENAI_BASE_URL=""
OPENAI_API_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ollama)        WITH_OLLAMA=1; shift ;;
    --replace)            REPLACE=1; shift ;;
    --openai-base-url)    OPENAI_BASE_URL="${2:?--openai-base-url needs a value}"; shift 2 ;;
    --openai-api-key)     OPENAI_API_KEY="${2:?--openai-api-key needs a value}"; shift 2 ;;
    --distro)             echo "use: DISTRO=<name> bash termux-bootstrap.sh" >&2; exit 2 ;;
    -h|--help)
      echo "usage: bash termux-bootstrap.sh [--with-ollama] [--openai-base-url URL] [--openai-api-key KEY] [--replace]" >&2
      echo "  --with-ollama         install native Ollama from TUR (only if you want Ollama)" >&2
      echo "  --openai-base-url URL use an OpenAI-compatible gateway, e.g. OmniRoute:" >&2
      echo "                        http://127.0.0.1:20128/v1  (no Ollama needed)" >&2
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

say "Open WebUI Auto-Installer - Termux bootstrap"

# --- 1. Repositories -------------------------------------------------------------
say "Updating Termux package indexes"
pkg update -y || warn "pkg update failed (network?)"

say "Enabling Termux repositories (tur-repo, x11-repo, root-repo)"
for repo in tur-repo x11-repo root-repo; do
  if pkg install -y "$repo" 2>/dev/null; then
    ok "enabled $repo"
  else
    warn "$repo not available on this device/arch - skipping (it is optional)"
  fi
done
pkg update -y 2>/dev/null || true

# --- 2. Base tools -----------------------------------------------------------------
say "Installing base tools"
for p in proot-distro git curl; do
  pkg install -y "$p" 2>/dev/null && ok "installed $p" || warn "failed to install $p"
done

# uv from TUR (prebuilt) - optional but preferred
if pkg install -y uv 2>/dev/null; then
  ok "installed uv (TUR prebuilt): $(uv --version 2>/dev/null)"
else
  warn "uv not in Termux repos; the installer will fetch it inside Ubuntu instead"
fi

# --- 3. Ubuntu distro ---------------------------------------------------------------
say "Installing Ubuntu proot-distro ($DISTRO)"
if proot-distro list 2>/dev/null | grep -qE "^\s*$DISTRO\s"; then
  ok "distro '$DISTRO' already installed"
  if [[ "$REPLACE" == "1" ]]; then
    warn "--replace: removing and reinstalling $DISTRO (this deletes its filesystem)"
    proot-distro remove "$DISTRO" || warn "remove failed"
    proot-distro install "$DISTRO" || { echo "[error] install failed" >&2; exit 1; }
  fi
else
  proot-distro install "$DISTRO" || { echo "[error] proot-distro install $DISTRO failed" >&2; exit 1; }
  ok "installed $DISTRO"
fi

# --- 4. Optional: native Ollama from TUR ----------------------------------------------
if [[ "$WITH_OLLAMA" == "1" ]]; then
  say "Installing native Ollama from TUR (prebuilt inference engine)"
  ABI="$(getprop ro.product.cpu.abi 2>/dev/null || uname -m)"
  case "$ABI" in
    arm64-v8a|aarch64|x86_64|*x86_64*)
      if pkg install -y ollama 2>/dev/null; then
        ok "ollama installed"
        # auto-start helper for Termux:Boot (if the app is installed)
        mkdir -p "$HOME/.termux/boot" 2>/dev/null
        cat > "$HOME/.termux/boot/start-ollama.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
nohup ollama serve > "$PREFIX/var/log/ollama.log" 2>&1 &
EOF
        chmod +x "$HOME/.termux/boot/start-ollama.sh" 2>/dev/null
        # start it now (best effort; needs Termux:Wake-Lock to stay alive)
        nohup ollama serve > "$PREFIX/var/log/ollama.log" 2>&1 &
        sleep 2
        curl -fsS -o /dev/null http://127.0.0.1:11434 && ok "ollama is up on 127.0.0.1:11434" \
          || warn "ollama did not answer yet (check 'ollama serve')"
        warn "keep Termux alive with: termux-wake-lock  (install Termux:API)"
      else
        warn "ollama is not available from TUR on this device"
      fi
      ;;
    *)
      warn "ollama TUR package not supported on ABI '$ABI'; skip with no --with-ollama"
      ;;
  esac
fi

# --- 5. Device info capture ---------------------------------------------------------------
say "Capturing device info for the installer"
ANDROID_VERSION="$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
ANDROID_SDK="$(getprop ro.build.version.sdk 2>/dev/null || echo unknown)"
ABI="$(getprop ro.product.cpu.abi 2>/dev/null || uname -m)"
BOARD="$(getprop ro.board.platform 2>/dev/null || echo unknown)"
SOC_MANUF="$(getprop ro.soc.manufacturer 2>/dev/null || echo unknown)"
SOC_MODEL="$(getprop ro.soc.model 2>/dev/null || echo unknown)"
TERMUX_VER="${TERMUX_VERSION:-unknown}"
GPU_HINT="$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || cat /proc/gpu_mali 2>/dev/null || echo unknown)"

SOC="${SOC_MANUF:-unknown}"
[[ "$SOC" == "unknown" ]] && SOC="$BOARD"
[[ "$SOC" == "unknown" ]] && SOC="unknown"

ok "android=$ANDROID_VERSION abi=$ABI soc=$SOC termux=$TERMUX_VER"

# --- 6. Run the installer inside Ubuntu ----------------------------------------------------
say "Launching installer inside $DISTRO (this can take a long time)"
GREEN='\033[1;32m'; RESET='\033[0m'
printf "${GREEN}  After install, access Open WebUI at http://127.0.0.1:8080${RESET}\n"
printf "${GREEN}  (from other devices on your LAN: http://<phone-ip>:8080)${RESET}\n"
printf "${GREEN}  Stop it later with: proot-distro login $DISTRO -- ./openwebui-ctl stop${RESET}\n\n"

# bind this folder into the distro and run the installer with device context
INSTALL_ARGS=(--yes)
if [[ -n "$OPENAI_BASE_URL" ]]; then
  INSTALL_ARGS+=(--openai-base-url "$OPENAI_BASE_URL")
  [[ -n "$OPENAI_API_KEY" ]] && INSTALL_ARGS+=(--openai-api-key "$OPENAI_API_KEY")
  WITH_OLLAMA=0   # a gateway is configured; no Ollama needed
fi
proot-distro login "$DISTRO" \
  --bind "$SCRIPT_DIR:/root/openwebui-autoinstaller" \
  --env OWI_IN_PROOT=1 \
  --env OWI_ANDROID="$ANDROID_VERSION" \
  --env OWI_ANDROID_SDK="$ANDROID_SDK" \
  --env OWI_TERMUX="$TERMUX_VER" \
  --env OWI_TERMUX_ABI="$ABI" \
  --env OWI_SOC="$SOC" \
  --env OWI_GPU="$GPU_HINT" \
  --env OWI_OLLAMA_MODE=auto \
  /root/openwebui-autoinstaller/install.sh "${INSTALL_ARGS[@]}"
