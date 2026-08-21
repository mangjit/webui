#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - smart deployment manager (update core)
# Detects *why* an update is needed (new version, dependency change, config
# drift, broken packages, repo changes), then applies exactly the required
# steps. Not a plain git pull: it validates, repairs, migrates and re-verifies.
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# Version discovery
# ---------------------------------------------------------------------------
installed_version() {
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    open_webui_version_of "$VENV_DIR/bin/python"
  fi
}

pypi_latest_version() {
  local data py
  py="$(command -v python3 || command -v python || echo '')"
  if [[ -n "$py" ]]; then
    data="$(curl -fsSL --max-time 25 https://pypi.org/pypi/open-webui/json 2>/dev/null)"
    if [[ -n "$data" ]]; then
      printf '%s' "$data" | "$py" -c 'import sys,json;print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null && return 0
    fi
  fi
  # fallback: parse the first "version":"x.y.z" (info block) from the JSON
  curl -fsSL --max-time 25 https://pypi.org/pypi/open-webui/json 2>/dev/null \
    | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4
}

ver_gt() {
  # ver_gt a b -> 0 if a > b (semver-ish, numeric dot compare)
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  local ia ib
  ia=$(printf '%s\n' "$a" | awk -F. '{printf "%04d%04d%04d\n",$1,$2,$3}')
  ib=$(printf '%s\n' "$b" | awk -F. '{printf "%04d%04d%04d\n",$1,$2,$3}')
  [[ "$ia" > "$ib" ]]
}

# ---------------------------------------------------------------------------
# Profile selection persistence
# If the user picked a profile explicitly at install time, keep honouring it
# on later runs unless they pass --profile again.
# ---------------------------------------------------------------------------
apply_locked_profile() {
  if [[ "${OWI_PROFILE:-auto}" == "auto" && -f "$STATE_FILE" ]]; then
    local sel
    sel="$(state_get PROFILE_SELECTION)"
    if [[ -n "$sel" && "$sel" != "auto" && "$sel" != "unknown" ]]; then
      OWI_PROFILE="$sel"
      ow_info "keeping previously selected profile: $sel"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Source mode (pypi vs git checkout)
# ---------------------------------------------------------------------------
effective_source_mode() {
  if [[ "$OWI_SOURCE_MODE" != "auto" ]]; then
    SOURCE_MODE="$OWI_SOURCE_MODE"
  elif [[ -d "$OWI_APP_DIR/.git" && -f "$OWI_APP_DIR/pyproject.toml" ]]; then
    SOURCE_MODE="git"
    ow_info "detected existing project checkout at $OWI_APP_DIR - using git mode"
  else
    SOURCE_MODE="pypi"
  fi
}

# ---------------------------------------------------------------------------
# Change detection
# ---------------------------------------------------------------------------
detect_changes() {
  # fills CHANGE_REASONS (newline-separated) and returns 0 if any exist
  CHANGE_REASONS=""
  local cur latest reason

  cur="$(installed_version)"
  if [[ -z "$cur" ]]; then
    CHANGE_REASONS="not-installed"
    return 0
  fi
  INSTALLED_OWUI_VERSION="$cur"

  effective_source_mode

  if [[ "$SOURCE_MODE" == "pypi" ]]; then
    latest="$(pypi_latest_version)"
    if [[ -n "$latest" ]]; then
      PYPI_LATEST="$latest"
      if ver_gt "$latest" "$cur"; then
        CHANGE_REASONS+="new-version: $cur -> $latest
"
      fi
    else
      ow_warn "could not reach PyPI to check for updates (offline?)"
    fi
  else
    # git mode: fetch and compare
    if command -v git >/dev/null 2>&1 && [[ -d "$OWI_APP_DIR/.git" ]]; then
      if ! is_dry_run; then
        (cd "$OWI_APP_DIR" && git fetch origin --quiet 2>/dev/null || true)
      fi
      local head_rev state_rev
      head_rev="$(git -C "$OWI_APP_DIR" rev-parse HEAD 2>/dev/null || echo '')"
      state_rev="$(state_get GIT_REV)"
      if [[ -n "$head_rev" && "$head_rev" != "$state_rev" ]]; then
        CHANGE_REASONS+="repo-updated ($state_rev -> $head_rev)
"
      fi
      local pyhash state_pyhash
      pyhash="$(sha256_file "$OWI_APP_DIR/pyproject.toml" 2>/dev/null)"
      state_pyhash="$(state_get DEP_PYPROJECT_HASH)"
      if [[ -n "$pyhash" && "$pyhash" != "$state_pyhash" ]]; then
        CHANGE_REASONS+="deps-changed (pyproject.toml)
"
      fi
      local pjhash state_pjhash
      pjhash="$(sha256_file "$OWI_APP_DIR/package.json" 2>/dev/null)"
      state_pjhash="$(state_get FRONTEND_PKG_HASH)"
      if [[ -n "$pjhash" && "$pjhash" != "$state_pjhash" ]]; then
        CHANGE_REASONS+="frontend-changed (package.json)
"
      fi
      local reqhash state_reqhash
      reqhash="$(sha256_file "$OWI_APP_DIR/backend/requirements.txt" 2>/dev/null)"
      state_reqhash="$(state_get DEP_REQ_HASH)"
      if [[ -n "$reqhash" && "$reqhash" != "$state_reqhash" ]]; then
        CHANGE_REASONS+="requirements-changed
"
      fi
    fi
  fi

  # profile / hardware changed?
  local phash
  phash="$(state_get PROFILE_HASH)"
  if [[ -n "$phash" && "$phash" != "$PROFILE_INPUTS_HASH" ]]; then
    CHANGE_REASONS+="profile-changed (hardware or profile selection)
"
  fi

  # dependency graph broken?
  if ! check_dep_graph; then
    CHANGE_REASONS+="deps-broken: ${HEALTH_DEPGRAPH}
"
  fi

  # imports broken?
  if ! check_imports; then
    CHANGE_REASONS+="imports-broken: ${HEALTH_IMPORTS}
"
  fi

  # lock drift?
  if ! check_lock_drift; then
    CHANGE_REASONS+="lock-drift
"
  fi

  # config drift (managed block different from what we would generate)?
  local cur_hash gen_hash
  cur_hash="$(managed_block_hash)"
  gen_hash="$(render_managed_block | sha256sum | awk '{print $1}')"
  if [[ "$cur_hash" != "$gen_hash" ]]; then
    CHANGE_REASONS+="config-drift (profile settings out of date)
"
  fi

  # service down?
  if ! svc_is_running; then
    CHANGE_REASONS+="service-down
"
  fi

  [[ -n "$CHANGE_REASONS" ]]
}

print_changes() {
  if [[ -z "$CHANGE_REASONS" ]]; then
    ow_ok "everything is up to date (open-webui ${INSTALLED_OWUI_VERSION:-?})"
    return 0
  fi
  ow_info "detected changes:"
  printf '%s' "$CHANGE_REASONS" | sed 's/^/  - /'
  [[ -z "$CHANGE_REASONS" ]]
}

# ---------------------------------------------------------------------------
# Apply phase
# ---------------------------------------------------------------------------
apply_update() {
  ow_step "Applying updates"

  local do_reinstall=0 do_venv_rebuild=0 do_frontend=0
  if printf '%s' "$CHANGE_REASONS" | grep -q "not-installed"; then
    ow_err "Open WebUI is not installed; run ./install.sh first"
    return 1
  fi
  printf '%s' "$CHANGE_REASONS" | grep -q "new-version:" && do_reinstall=1
  printf '%s' "$CHANGE_REASONS" | grep -q "deps-changed\|requirements-changed" && do_reinstall=1
  printf '%s' "$CHANGE_REASONS" | grep -q "repo-updated" && do_reinstall=1
  printf '%s' "$CHANGE_REASONS" | grep -q "imports-broken\|deps-broken\|lock-drift" && do_venv_rebuild=1
  printf '%s' "$CHANGE_REASONS" | grep -q "frontend-changed" && do_frontend=1

  # stop the service before touching the environment
  if svc_is_running; then
    ow_info "stopping service for maintenance"
    svc_stop
  fi

  # backup before any major change
  if [[ "$do_reinstall" == "1" || "$do_venv_rebuild" == "1" ]]; then
    backup_database
  fi

  local target
  target="${OWI_OPENWEBUI_VERSION:-latest}"
  [[ "$target" == "latest" && -n "${PYPI_LATEST:-}" ]] && target="$PYPI_LATEST"

  if [[ "$SOURCE_MODE" == "pypi" ]]; then
    if [[ "$do_reinstall" == "1" ]]; then
      ow_info "upgrading open-webui to ${target}"
      install_openwebui "$target"
    fi
  else
    # git source: pull and reinstall editable
    ow_info "updating git checkout $OWI_APP_DIR"
    if ! is_dry_run; then
      (cd "$OWI_APP_DIR" && git pull --ff-only --quiet) || {
        ow_warn "git pull failed; attempting fetch+reset to origin/main"
        (cd "$OWI_APP_DIR" && git fetch origin --quiet && git reset --hard origin/main --quiet) || ow_warn "git update failed"
      }
    fi
    if [[ "$do_reinstall" == "1" || "$do_frontend" == "1" ]]; then
      if [[ "$do_frontend" == "1" ]]; then
        ow_info "frontend dependencies changed; rebuilding frontend (this is slow on phones)"
        if ! is_dry_run; then
          (cd "$OWI_APP_DIR" && npm ci && npm run build) || ow_warn "frontend build failed"
          # replicate the wheel's frontend location for the editable install
          mkdir -p "$OWI_APP_DIR/backend/open_webui/frontend"
          cp -r "$OWI_APP_DIR/build/"* "$OWI_APP_DIR/backend/open_webui/frontend/" 2>/dev/null || true
        fi
      fi
      ow_info "reinstalling editable package"
      if ! is_dry_run; then
        "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build -e "$OWI_APP_DIR" || ow_warn "editable reinstall failed"
      fi
    fi
  fi

  # regenerate lock
  if ! is_dry_run; then
    write_lock || ow_warn "could not regenerate lock"
  fi

  # regenerate managed env config if profile/drift changed
  if printf '%s' "$CHANGE_REASONS" | grep -q "profile-changed\|config-drift"; then
    ow_info "reapplying profile configuration"
    apply_env_file
  fi

  # verify + repair
  if ! is_dry_run; then
    if health_check; then
      ow_ok "post-update health check passed"
    else
      ow_warn "post-update health issues found:"
      print_health | sed 's/^/  /'
      repair_env
    fi
  fi

  # restart
  if [[ "${OWI_START_SERVICE:-1}" == "1" ]]; then
    svc_start
  fi

  # record state
  write_state
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
write_state() {
  if is_dry_run; then dry_msg "record install state -> $STATE_FILE"; return 0; fi
  local ver pyver
  ver="$(installed_version)"
  pyver="$(python_version_of "$VENV_DIR/bin/python" 2>/dev/null || echo '')"
  state_set APP_VERSION "${ver:-unknown}"
  state_set PYTHON_VERSION "${pyver:-unknown}"
  state_set INSTALL_PROFILE "$INSTALL_PROFILE"
  state_set PROFILE_SELECTION "${OWI_PROFILE:-auto}"
  state_set PROFILE_HASH "$PROFILE_INPUTS_HASH"
  state_set SOURCE_MODE "$SOURCE_MODE"
  state_set UPDATED_AT "$(now_iso)"
  if [[ "$SOURCE_MODE" == "git" ]]; then
    state_set GIT_REV "$(git -C "$OWI_APP_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    state_set DEP_PYPROJECT_HASH "$(sha256_file "$OWI_APP_DIR/pyproject.toml" 2>/dev/null)"
    state_set DEP_REQ_HASH "$(sha256_file "$OWI_APP_DIR/backend/requirements.txt" 2>/dev/null)"
    state_set FRONTEND_PKG_HASH "$(sha256_file "$OWI_APP_DIR/package.json" 2>/dev/null)"
  fi
  state_set ENV_HASH "$ENV_FILE_HASH"
  state_set LOCK_HASH "$(sha256_file "$LOCK_FILE" 2>/dev/null)"
  state_set LAST_CHECK_AT "$(now_iso)"
  ow_ok "state recorded"
}

# ---------------------------------------------------------------------------
# Entry used by update.sh
# ---------------------------------------------------------------------------
run_update() {
  ow_step "Smart update scan"
  ensure_dir "$OWI_INSTALL_DIR"

  if [[ ! -f "$STATE_FILE" ]]; then
    ow_warn "no previous install state found - nothing to update yet"
    return 1
  fi

  detect_changes

  if [[ -z "$CHANGE_REASONS" ]]; then
    ow_ok "Open WebUI ${INSTALLED_OWUI_VERSION:-?} is up to date"
    if [[ "${OWI_CHECK_ONLY:-0}" != "1" && "${OWI_START_SERVICE:-1}" == "1" ]] && ! svc_is_running; then
      ow_info "service is not running; starting it"
      svc_start
    fi
    return 0
  fi

  print_changes

  if [[ "${OWI_CHECK_ONLY:-0}" == "1" ]]; then
    ow_info "(check-only mode: no changes applied)"
    return 0
  fi

  apply_update
}
