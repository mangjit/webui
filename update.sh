#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - smart updater / deployment manager
# Detects exactly what changed (new release, dependency drift, broken
# packages, config drift, repo changes, dead service) and applies only the
# required steps. Safe, idempotent, self-healing.
#
# Usage: ./update.sh [options]
#   --check-only   report what would change without applying
#   --repair       force a health check + repair pass
#   -y, --yes      assume yes
#   -n, --dry-run  simulate
#   --profile <p>  re-evaluate with a different profile
#   --version <v>  pin a specific open-webui version for the upgrade
#   --no-service   do not (re)start the service afterwards
# ============================================================================

set -uo pipefail

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

OWI_CHECK_ONLY=0
OWI_REPAIR_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) OWI_CHECK_ONLY=1 ;;
    --repair)     OWI_REPAIR_ONLY=1 ;;
    -y|--yes)     OWI_YES=1 ;;
    -n|--dry-run) OWI_DRY_RUN=1 ;;
    --profile)    OWI_PROFILE="${2:?--profile needs a value}"; shift ;;
    --version)    OWI_OPENWEBUI_VERSION="${2:?--version needs a value}"; shift ;;
    --no-service) OWI_START_SERVICE=0 ;;
    -h|--help)
      echo "usage: ./update.sh [--check-only|--repair|--yes|--dry-run|--profile P|--version V|--no-service]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ow_banner
ensure_dir "$LOG_DIR"
[[ "${OWI_DRY_RUN:-0}" == "1" ]] && ow_warn "DRY-RUN mode: no changes will be made"

apply_locked_profile
detect_all
effective_source_mode
ensure_uv

if [[ ! -f "$STATE_FILE" ]]; then
  ow_warn "no install state found. Run ./install.sh first."
  exit 1
fi

if [[ "${OWI_REPAIR_ONLY:-0}" == "1" ]]; then
  ow_step "Repair-only mode"
  health_check || { print_health | sed 's/^/  /'; repair_env; }
  if [[ "${OWI_START_SERVICE:-1}" == "1" ]]; then svc_start; fi
  exit 0
fi

run_update

if [[ "${OWI_CHECK_ONLY:-0}" == "1" ]]; then
  exit 0
fi
