#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - hardware & environment detection
# Detects CPU architecture, SoC vendor, RAM, cores, storage, Android version,
# Termux version, Ubuntu/Proot info and GPU, then derives an install profile.
#
# Every probe is best-effort and falls back to "unknown"; every result can be
# overridden with OWI_* environment variables (set automatically by
# termux-bootstrap.sh from Android's getprop values).
#
# Run standalone for a report:   bash lib/detect.sh --report
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# Normalise CPU architecture
# ---------------------------------------------------------------------------
detect_arch() {
  local raw
  raw="${OWI_ARCH:-$(uname -m 2>/dev/null)}"
  case "$raw" in
    aarch64|arm64)                 HW_ARCH="aarch64"; HW_ARCH_FAMILY="arm64" ;;
    armv7l|armv6l|armhf|arm)       HW_ARCH="$raw";    HW_ARCH_FAMILY="armhf" ;;
    armv8l)                        HW_ARCH="armv8l";  HW_ARCH_FAMILY="armhf" ;; # 32-bit userland on 64-bit SoC
    x86_64|amd64)                  HW_ARCH="x86_64";  HW_ARCH_FAMILY="x86_64" ;;
    i686|i386|x86)                 HW_ARCH="$raw";    HW_ARCH_FAMILY="x86" ;;
    *)                             HW_ARCH="$raw";    HW_ARCH_FAMILY="unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# SoC vendor / model
# ---------------------------------------------------------------------------
detect_soc() {
  HW_SOC_VENDOR="unknown"; HW_SOC_MODEL="unknown"
  [[ -n "${OWI_SOC:-}" ]] && { HW_SOC_VENDOR="$OWI_SOC"; }

  local cpuinfo="/proc/cpuinfo"
  local hw_line proc_line impl_line model_line
  if [[ -r "$cpuinfo" ]]; then
    hw_line=$(grep -m1 -i '^Hardware' "$cpuinfo" | sed 's/.*:\s*//')
    proc_line=$(grep -m1 -i '^Processor' "$cpuinfo" | sed 's/.*:\s*//')
    impl_line=$(grep -m1 -i 'CPU implementer' "$cpuinfo" | awk '{print $NF}')
    model_line=$(grep -m1 -i 'model name' "$cpuinfo" | sed 's/.*:\s*//')
  fi

  # /proc/device-tree is often readable without root inside proot
  local dt_compat=""
  if [[ -r /proc/device-tree/gpu/compatible ]]; then
    dt_compat=$(tr '\0' ' ' < /proc/device-tree/gpu/compatible 2>/dev/null | tr '[:upper:]' '[:lower:]')
  fi

  local probe="$hw_line $proc_line $model_line $dt_compat"
  probe=$(printf '%s' "$probe" | tr '[:upper:]' '[:lower:]')

  # Vendor inference: cpuinfo "CPU implementer" is the authoritative hint.
  case "${impl_line:-}" in
    0x41|41)  HW_SOC_VENDOR="arm" ;;
    0x51|51)  HW_SOC_VENDOR="qualcomm" ;;
    0x4e|4e)  HW_SOC_VENDOR="nvidia" ;;
    0x53|53)  HW_SOC_VENDOR="samsung" ;;
    0x48|48)  HW_SOC_VENDOR="hisilicon" ;;
    0x42|42)  HW_SOC_VENDOR="broadcom" ;;
    0x56|56)  HW_SOC_VENDOR="marvell" ;;
    0x69|69)  HW_SOC_VENDOR="intel" ;;
    0x46|46)  HW_SOC_VENDOR="fujitsu" ;;
  esac

  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "qualcomm" "snapdragon" "sm[0-9]" "kryo" "adreno"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="qualcomm"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "mediatek" "mt[0-9]" "dimensity" "helio" "mali-"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="mediatek"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "exynos" "samsung"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="samsung"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "google" "tensor" "gs[0-9]"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="google"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "kirin" "hisilicon"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="hisilicon"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "unisoc" "spreadtrum" "t6[0-9]"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="unisoc"; break; }
    done
  fi
  if [[ "$HW_SOC_VENDOR" == "unknown" ]]; then
    for pat in "tegra" "nvidia"; do
      [[ "$probe" == *"$pat"* ]] && { HW_SOC_VENDOR="nvidia"; break; }
    done
  fi

  [[ -n "$hw_line" && "$hw_line" != "unknown" ]] && HW_SOC_MODEL="$hw_line"
  # "model name" is an x86 construct; on ARM use it only if nothing else matched.
  if [[ "$HW_SOC_MODEL" == "unknown" && "$HW_ARCH_FAMILY" == "x86_64" && -n "$model_line" ]]; then
    HW_SOC_MODEL="$model_line"
  fi
  if [[ "$HW_SOC_MODEL" == "unknown" && -n "$proc_line" && "$proc_line" == *[!0-9]* ]]; then
    HW_SOC_MODEL="$proc_line"
  fi
}

# ---------------------------------------------------------------------------
# GPU
# ---------------------------------------------------------------------------
detect_gpu() {
  HW_GPU="unknown"; HW_GPU_FAMILY="unknown"
  [[ -n "${OWI_GPU:-}" ]] && { HW_GPU="$OWI_GPU"; HW_GPU_FAMILY="$OWI_GPU"; }

  local gpu_model
  gpu_model=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null | head -1)          # Adreno
  [[ -z "$gpu_model" ]] && gpu_model=$(cat /proc/gpu_mali 2>/dev/null | head -1)     # Mali
  if [[ -z "$gpu_model" && -r /proc/device-tree/gpu/compatible ]]; then
    gpu_model=$(tr '\0' ' ' < /proc/device-tree/gpu/compatible 2>/dev/null | sed 's/.*,//')
  fi
  [[ -z "$gpu_model" ]] && gpu_model=$(ls /sys/class/misc/mali0/device 2>/dev/null | head -1)
  if [[ -n "$gpu_model" ]]; then
    HW_GPU="$gpu_model"
    local g="$gpu_model"
    g=$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')
    if [[ "$g" == *adreno* || "$g" == *kgsl* ]]; then HW_GPU_FAMILY="adreno";
    elif [[ "$g" == *mali* ]]; then HW_GPU_FAMILY="mali";
    elif [[ "$g" == *powervr* || "$g" == *sgx* ]]; then HW_GPU_FAMILY="powervr";
    elif [[ "$g" == *apple* || "$g" == *g13* || "$g" == *g14* ]]; then HW_GPU_FAMILY="apple";
    else HW_GPU_FAMILY="$HW_GPU"; fi
  fi

  # Fall back to a SoC-based guess when no GPU node is readable.
  if [[ "$HW_GPU" == "unknown" ]]; then
    case "$HW_SOC_VENDOR" in
      qualcomm) HW_GPU="adreno (inferred)"; HW_GPU_FAMILY="adreno" ;;
      mediatek|samsung|hisilicon|unisoc|google) HW_GPU="mali (inferred)"; HW_GPU_FAMILY="mali" ;;
      nvidia) HW_GPU="tegra (inferred)"; HW_GPU_FAMILY="tegra" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# RAM / cores / storage
# ---------------------------------------------------------------------------
detect_ram() {
  HW_RAM_MB="${OWI_RAM_MB:-}"
  if [[ -z "$HW_RAM_MB" ]]; then
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    HW_RAM_MB=$(( ${mem_kb:-0} / 1024 ))
  fi
  [[ -z "$HW_RAM_MB" || "$HW_RAM_MB" == "0" ]] && HW_RAM_MB="unknown"
}

detect_cores() {
  HW_CORES="${OWI_CORES:-}"
  if [[ -z "$HW_CORES" ]]; then
    HW_CORES=$(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  fi
  [[ -z "$HW_CORES" || "$HW_CORES" == "0" ]] && HW_CORES=1
}

detect_storage() {
  local base="${OWI_DATA_DIR:-$HOME}"
  # df needs an existing path; walk up until one exists
  while [[ -n "$base" && ! -d "$base" ]]; do base="$(dirname "$base")"; done
  [[ -z "$base" || ! -d "$base" ]] && base="/"
  HW_STORAGE_FREE_MB="${OWI_STORAGE_FREE_MB:-$(free_mb "$base")}"
  HW_STORAGE_TOTAL_MB="${OWI_STORAGE_TOTAL_MB:-$(total_mb "$base")}"
  [[ -z "$HW_STORAGE_FREE_MB" ]] && HW_STORAGE_FREE_MB="unknown"
  [[ -z "$HW_STORAGE_TOTAL_MB" ]] && HW_STORAGE_TOTAL_MB="unknown"
}

# ---------------------------------------------------------------------------
# OS layer: Android / Termux / Ubuntu / Proot
# ---------------------------------------------------------------------------
detect_os() {
  HW_ANDROID="${OWI_ANDROID:-unknown}"      # set by termux-bootstrap via getprop
  HW_ANDROID_SDK="${OWI_ANDROID_SDK:-unknown}"
  HW_TERMUX="${OWI_TERMUX:-unknown}"        # set by termux-bootstrap from $TERMUX_VERSION
  HW_TERMUX_ABI="${OWI_TERMUX_ABI:-unknown}"

  if [[ -r /etc/os-release ]]; then
    HW_UBUNTU=$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?/\1/p' /etc/os-release | head -1)
    HW_OS_ID=$(sed -n 's/^ID=\(.*\)/\1/p' /etc/os-release | head -1 | tr -d '"')
  fi
  [[ -z "${HW_UBUNTU:-}" ]] && HW_UBUNTU="unknown"

  # Which packaging environment are we in?
  HW_ENV_KIND="${OWI_ENV_KIND:-auto}"
  if [[ "$HW_ENV_KIND" == "auto" ]]; then
    if [[ -n "${PREFIX:-}" && -d "${PREFIX:-}" ]]; then
      HW_ENV_KIND="termux"                       # native Termux (bionic)
    elif [[ "${OWI_IN_PROOT:-0}" == "1" ]]; then
      HW_ENV_KIND="proot"                        # Ubuntu under proot-distro
    else
      HW_ENV_KIND="linux"                        # plain Linux (or proot without marker)
    fi
  fi

  # Termux bootstrap usually passes its own arch; otherwise trust uname.
  [[ "$HW_TERMUX_ABI" == "unknown" ]] && HW_TERMUX_ABI="$HW_ARCH"
}

# ---------------------------------------------------------------------------
# Existing Python installations, virtual environments, project files
# ---------------------------------------------------------------------------
detect_python_envs() {
  PY_SYSTEM_PYTHON=""; PY_SYSTEM_PYTHON_VER=""
  if command -v python3 >/dev/null 2>&1; then
    PY_SYSTEM_PYTHON="$(command -v python3)"
    PY_SYSTEM_PYTHON_VER="$(python_version_of "$PY_SYSTEM_PYTHON")"
  fi

  # uv-managed interpreters
  PY_UV_PYTHONS=""
  if command -v uv >/dev/null 2>&1; then
    PY_UV_PYTHONS="$(uv python list --only-installed 2>/dev/null || true)"
  fi

  # Virtual environments we might adopt (dedicated open-webui venvs)
  PY_EXISTING_VENVS=""
  if [[ -d "$HOME" ]]; then
    PY_EXISTING_VENVS=$(find "$HOME" -maxdepth 4 -type f -name pyvenv.cfg 2>/dev/null | sed 's|/pyvenv.cfg||' | head -20)
  fi
}

detect_existing_project() {
  PROJECT_EXISTS=0
  if [[ -d "$OWI_APP_DIR/.git" && -f "$OWI_APP_DIR/pyproject.toml" ]]; then
    PROJECT_EXISTS=1
    PROJECT_GIT_REV="$(git -C "$OWI_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  # A previous install by this tool?
  PREV_INSTALLED=0
  [[ -f "$STATE_FILE" ]] && PREV_INSTALLED=1
}

# ---------------------------------------------------------------------------
# Profile derivation
# ---------------------------------------------------------------------------
compute_profile() {
  local arch_family="$HW_ARCH_FAMILY"

  # 32-bit ARM: essentially no prebuilt wheels for the heavy stack -> minimal.
  if [[ "$arch_family" == "armhf" ]]; then
    if [[ "${OWI_PROFILE:-auto}" == "auto" ]]; then
      INSTALL_PROFILE="minimal"
      PROFILE_ARCH_LIMITED=1
    else
      INSTALL_PROFILE="$OWI_PROFILE"
      PROFILE_ARCH_LIMITED=1
    fi
  else
    INSTALL_PROFILE="${OWI_PROFILE:-auto}"
    if [[ "$INSTALL_PROFILE" == "auto" ]]; then
      local ram_free
      ram_free=$(num_or_zero "$HW_RAM_MB"); 
      local sto_free
      sto_free=$(num_or_zero "$HW_STORAGE_FREE_MB")
      if (( ram_free >= RAM_FULL_MIN_MB && sto_free >= STORAGE_FULL_MIN_MB )); then
        INSTALL_PROFILE="full"
      elif (( ram_free >= RAM_STANDARD_MIN_MB && sto_free >= STORAGE_STANDARD_MIN_MB )); then
        INSTALL_PROFILE="standard"
      elif (( ram_free >= RAM_LIGHT_MIN_MB && sto_free >= STORAGE_LIGHT_MIN_MB )); then
        INSTALL_PROFILE="light"
      else
        INSTALL_PROFILE="minimal"
      fi
    fi
  fi

  # A user-forced profile still sanity-checks against architecture.
  if [[ "$arch_family" == "armhf" && "$INSTALL_PROFILE" == "full" ]]; then
    ow_warn "full profile is not achievable on 32-bit ARM (no prebuilt wheels); forcing 'minimal'"
    INSTALL_PROFILE="minimal"
  fi

  # Free disk is intentionally NOT hashed: it changes with every install and
  # would otherwise trigger a bogus "profile-changed" on every update run.
  PROFILE_INPUTS_HASH="$(hash_text "$HW_ARCH|$HW_RAM_MB|$HW_CORES|$HW_GPU|$INSTALL_PROFILE|$OWI_PYTHON|$OWI_SOURCE_MODE|$OWI_OLLAMA_MODE")"
}

num_or_zero() { echo "${1:-0}" | tr -dc '0-9'; }

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
print_report() {
  local line
  while read -r line; do printf '%s\n' "$line"; done <<EOF
[environment]
env_kind        = ${HW_ENV_KIND:-unknown}
android         = ${HW_ANDROID:-unknown}
android_sdk     = ${HW_ANDROID_SDK:-unknown}
termux          = ${HW_TERMUX:-unknown}
ubuntu          = ${HW_UBUNTU:-unknown}
[hardware]
arch            = ${HW_ARCH:-unknown} (${HW_ARCH_FAMILY:-unknown})
soc_vendor      = ${HW_SOC_VENDOR:-unknown}
soc_model       = ${HW_SOC_MODEL:-unknown}
gpu             = ${HW_GPU:-unknown} (${HW_GPU_FAMILY:-unknown})
ram_mb          = ${HW_RAM_MB:-unknown}
cores           = ${HW_CORES:-unknown}
storage_free_mb = ${HW_STORAGE_FREE_MB:-unknown}
storage_total_mb= ${HW_STORAGE_TOTAL_MB:-unknown}
[profile]
install_profile = ${INSTALL_PROFILE:-unknown}
profile_hash    = ${PROFILE_INPUTS_HASH:-unknown}
[python]
system_python   = ${PY_SYSTEM_PYTHON:-none} (${PY_SYSTEM_PYTHON_VER:-?})
uv_pythons      = ${PY_UV_PYTHONS:-none}
[project]
existing_checkout = ${PROJECT_EXISTS:-0}
previous_install  = ${PREV_INSTALLED:-0}
EOF
}

# ---------------------------------------------------------------------------
# Main (standalone invocation)
# ---------------------------------------------------------------------------
detect_all() {
  detect_arch
  detect_soc
  detect_gpu
  detect_ram
  detect_cores
  detect_storage
  detect_os
  detect_python_envs
  detect_existing_project
  compute_profile
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_all
  if [[ "${1:-}" == "--json" ]]; then
    printf '{"arch":"%s","family":"%s","soc":"%s","gpu":"%s","ram_mb":"%s","cores":"%s","free_mb":"%s","android":"%s","termux":"%s","profile":"%s"}\n' \
      "$HW_ARCH" "$HW_ARCH_FAMILY" "$HW_SOC_VENDOR" "$HW_GPU" "$HW_RAM_MB" "$HW_CORES" "$HW_STORAGE_FREE_MB" "$HW_ANDROID" "$HW_TERMUX" "$INSTALL_PROFILE"
  else
    print_report
  fi
fi
