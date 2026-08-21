#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - self-healing
# Health checks (interpreter, dependency graph, imports, lock drift) and a
# graded repair ladder: fix one package -> resync from lock -> rebuild venv ->
# degrade features. Safe to run repeatedly; never destroys data.
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

# import name -> distribution name for reinstalls (see common.sh dist_for_module)
dist_of_import() { dist_for_module "$1"; }

# Imports that must always work
BASE_IMPORTS=(open_webui fastapi uvicorn sqlalchemy aiohttp pydantic chromadb jwt bcrypt)
# Optional imports tested only if the package is present in the venv
OPTIONAL_IMPORTS=(torch transformers sentence_transformers numpy pandas scipy onnxruntime av cv2 faster_whisper tiktoken)

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------
check_interpreter() {
  [[ -x "$VENV_DIR/bin/python" ]] || { HEALTH_INTERPRETER="missing"; return 1; }
  local v
  v="$(python_version_of "$VENV_DIR/bin/python")"
  if [[ -z "$v" ]]; then HEALTH_INTERPRETER="broken"; return 1; fi
  if ! printf '%s' "$v" | grep -q "^${OWI_PYTHON}"; then
    HEALTH_INTERPRETER="mismatch ($v != $OWI_PYTHON)"; return 1
  fi
  HEALTH_INTERPRETER="ok ($v)"
  return 0
}

check_dep_graph() {
  if ! command -v uv >/dev/null 2>&1 || [[ ! -x "$VENV_DIR/bin/python" ]]; then
    HEALTH_DEPGRAPH="cannot check"; return 1
  fi
  local out
  out="$("$(uv_bin)" pip check --python "$VENV_DIR/bin/python" 2>/dev/null)"
  if [[ -z "$out" ]]; then HEALTH_DEPGRAPH="ok"; return 0; fi
  HEALTH_DEPGRAPH="$out"
  return 1
}

check_imports() {
  local failed=() dist
  for imp in "${BASE_IMPORTS[@]}"; do
    if [[ "$imp" == "open_webui" ]]; then
      # Strong test: importing the full app module tree (catches missing
      # runtime deps that a bare `import open_webui` would miss).
      if ! import_startup_ok; then failed+=("open-webui"); fi
      continue
    fi
    if ! "$VENV_DIR/bin/python" -c "import $imp" >/dev/null 2>&1; then
      dist="$(dist_of_import "$imp")"; failed+=("$dist")
    fi
  done
  # optional imports: only fail if the package is actually installed
  local freeze
  freeze="$(pip_freeze)"
  for imp in "${OPTIONAL_IMPORTS[@]}"; do
    dist="$(dist_of_import "$imp")"
    if printf '%s\n' "$freeze" | grep -qi "^${dist}="; then
      if ! "$VENV_DIR/bin/python" -c "import $imp" >/dev/null 2>&1; then
        failed+=("$dist")
      fi
    fi
  done
  HEALTH_IMPORTS="${failed[*]:-ok}"
  [[ ${#failed[@]} -eq 0 ]]
}

check_lock_drift() {
  if [[ ! -f "$LOCK_FILE" ]]; then HEALTH_LOCK="no-lock"; return 0; fi
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then HEALTH_LOCK="cannot-check"; return 1; fi
  local live
  live="$(pip_freeze | sort)"
  if [[ "$live" == "$(sort < "$LOCK_FILE")" ]]; then HEALTH_LOCK="ok"; return 0; fi
  HEALTH_LOCK="drift"
  return 1
}

check_config() {
  if [[ ! -f "$ENV_FILE" ]]; then HEALTH_CONFIG="missing"; return 1; fi
  if ! grep -qF "# >>> open-webui-installer: managed block" "$ENV_FILE"; then
    HEALTH_CONFIG="no-managed-block"; return 1; fi
  if [[ -z "$(sed -n 's/^WEBUI_SECRET_KEY=//p' "$ENV_FILE" | head -1)" ]]; then
    HEALTH_CONFIG="missing-secret"; return 1; fi
  HEALTH_CONFIG="ok"
  return 0
}

# Full health snapshot -> sets HEALTH_* and returns 0 if everything is fine
health_check() {
  check_interpreter
  check_dep_graph
  check_imports
  check_lock_drift
  check_config
  local ok=0
  for h in HEALTH_INTERPRETER HEALTH_DEPGRAPH HEALTH_IMPORTS HEALTH_LOCK HEALTH_CONFIG; do
    [[ "${!h}" == "ok"* ]] || ok=1
  done
  [[ "$ok" == "0" ]]
}

print_health() {
  printf 'interpreter : %s\n' "${HEALTH_INTERPRETER:-unknown}"
  printf 'dependencies: %s\n' "${HEALTH_DEPGRAPH:-unknown}"
  printf 'imports     : %s\n' "${HEALTH_IMPORTS:-unknown}"
  printf 'lock        : %s\n' "${HEALTH_LOCK:-unknown}"
  printf 'config      : %s\n' "${HEALTH_CONFIG:-unknown}"
}

# ---------------------------------------------------------------------------
# Repair ladder
# ---------------------------------------------------------------------------
repair_reinstall_one() {
  # Reinstall a single broken distribution, wheels-only, profile-aware.
  local pkg="$1"
  if [[ "$pkg" == "open-webui" ]]; then
    # Never let a repair drag in the full heavy tree on a light profile.
    local ver
    ver="$(open_webui_version_of "$VENV_DIR/bin/python")"
    if [[ "$INSTALL_PROFILE" == "full" || "$INSTALL_PROFILE" == "standard" ]]; then
      "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build --reinstall-package "open-webui" "open-webui==${ver:-latest}" \
        && return 0
    else
      "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build --no-deps --reinstall-package "open-webui" "open-webui==${ver:-latest}" \
        || return 1
      [[ -f "$MIN_REQ_FILE" ]] || fetch_requirements_min "${ver:-latest}" || true
      [[ -f "$MIN_REQ_FILE" ]] && "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build -r "$MIN_REQ_FILE" || true
      install_min_patch || true
      return 0
    fi
  fi
  "$(uv_bin)" pip install --python "$VENV_DIR/bin/python" --no-build --reinstall-package "$pkg" "$pkg"
}

repair_step1_reinstall_broken() {
  # Reinstall each import that fails, from wheels.
  local failed="${HEALTH_IMPORTS:-}"
  [[ "$failed" == "ok" || -z "$failed" ]] && return 0
  local pkg
  for pkg in $failed; do
    ow_info "reinstalling broken package: $pkg"
    if is_dry_run; then dry_msg "repair_reinstall_one $pkg"; continue; fi
    if repair_reinstall_one "$pkg"; then
      ow_ok "reinstalled $pkg"
    else
      ow_warn "could not reinstall $pkg"
    fi
  done
}

repair_step2_sync_lock() {
  ow_info "resyncing venv to the dependency lock"
  pip_sync_lock
}

repair_step3_rebuild_venv() {
  ow_warn "rebuilding virtual environment from scratch (data is untouched)"
  if is_dry_run; then dry_msg "recreate venv + uv pip sync $LOCK_FILE"; return 0; fi
  local bak="$VENV_DIR.broken.$(date -u +%s)"
  mv "$VENV_DIR" "$bak" || ow_die "cannot move broken venv aside"
  ensure_venv || return 1
  pip_sync_lock
}

repair_step4_degrade() {
  # Last resort: make the app run without the broken capability.
  ow_warn "degrading configuration to avoid the broken component"
  if grep -q '^RAG_EMBEDDING_ENGINE=' "$ENV_FILE"; then
    sed -i 's/^RAG_EMBEDDING_ENGINE=.*/RAG_EMBEDDING_ENGINE=ollama/' "$ENV_FILE"
  fi
}

repair_env() {
  ow_step "Self-healing: repairing environment"
  ensure_dir "$OWI_INSTALL_DIR"

  # 0) re-check from a clean slate
  health_check

  if [[ "${HEALTH_INTERPRETER:-}" != ok* ]]; then
    ow_warn "Python interpreter is not healthy (${HEALTH_INTERPRETER:-?})"
    repair_step3_rebuild_venv
    # After a rebuild, reinstall whatever the profile needs if there is no lock
    if [[ ! -f "$LOCK_FILE" ]]; then
      install_openwebui "${OWI_OPENWEBUI_VERSION:-latest}"
    fi
  else
    if [[ "${HEALTH_DEPGRAPH:-}" != ok ]]; then
      ow_warn "dependency conflicts detected: ${HEALTH_DEPGRAPH}"
      repair_step2_sync_lock
    fi
    if [[ "${HEALTH_IMPORTS:-}" != ok ]]; then
      repair_step1_reinstall_broken
      # If the full app module tree still will not import, discover and
      # install whatever runtime dependency a release needs (light profile).
      if [[ "$INSTALL_PROFILE" != "full" && "$INSTALL_PROFILE" != "standard" ]] && ! import_startup_ok; then
        ow_info "startup import still failing; discovering missing runtime dependencies"
        install_min_patch || true
      fi
      health_check
      if [[ "${HEALTH_IMPORTS:-}" != ok ]]; then
        repair_step3_rebuild_venv
      fi
    fi
    if [[ "${HEALTH_LOCK:-}" != ok ]]; then
      ow_warn "venv drifted from the lock file (${HEALTH_LOCK})"
      repair_step2_sync_lock
    fi
  fi

  if [[ "${HEALTH_CONFIG:-}" != ok ]]; then
    ow_warn "configuration is unhealthy (${HEALTH_CONFIG}); regenerating"
    apply_env_file
  fi

  health_check
  if [[ "$?" == "0" ]]; then
    ow_ok "environment healthy"
  else
    ow_warn "environment still unhealthy after repair; attempting feature degradation"
    repair_step4_degrade
    health_check
    [[ "$?" == "0" ]] && ow_ok "environment healthy (degraded config)" || ow_warn "repair incomplete - review $LOG_DIR"
  fi
}

# Recover from a stale pidfile / dead process
repair_service() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || echo '')"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0  # running
    fi
    ow_warn "stale pidfile (pid $pid not running); clearing"
    rm -f "$PID_FILE"
  fi
  if [[ "${OWI_START_SERVICE:-1}" == "1" ]] && ! svc_is_running; then
    svc_start || ow_warn "service failed to start after repair"
  fi
}
