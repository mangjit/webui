#!/usr/bin/env bash
# ============================================================================
# Open WebUI Auto-Installer - configuration management
# Generates open_webui.env from a template + hardware profile. Only the
# "installer-managed" block is ever rewritten; user edits are preserved
# between runs, and every rewrite is backed up.
# ============================================================================

if [[ "${OWI_COMMON_SOURCED:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/common.sh"
fi

MANAGED_BEGIN="# >>> open-webui-installer: managed block - do not edit <<<"
MANAGED_END="# <<< open-webui-installer: managed block - do not edit >>>"

# ---------------------------------------------------------------------------
# Secret key (generated once, kept forever)
# ---------------------------------------------------------------------------
ensure_secret_key() {
  ensure_dir "$OWI_INSTALL_DIR"
  if [[ ! -s "$SECRET_KEY_FILE" ]]; then
    if is_dry_run; then
      dry_msg "generate WEBUI_SECRET_KEY -> $SECRET_KEY_FILE"
      WEBUI_SECRET_KEY="dry-run-placeholder-key"
    else
      WEBUI_SECRET_KEY="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
      umask 077
      printf '%s\n' "$WEBUI_SECRET_KEY" > "$SECRET_KEY_FILE"
      umask 022
      ow_ok "generated WEBUI_SECRET_KEY"
    fi
  else
    WEBUI_SECRET_KEY="$(cat "$SECRET_KEY_FILE")"
  fi
}

# ---------------------------------------------------------------------------
# Profile-derived runtime tuning
# ---------------------------------------------------------------------------
profile_tuning() {
  # Sets: T_RAG_EMBEDDING_ENGINE/MODEL, T_AUTOCOMPLETE, T_TAGS, T_TITLE, T_FOLLOWUP,
  #       T_OMP_THREADS, T_MEMORY_CTX, T_IMAGE_GEN, T_VOICE, T_LOG_LEVEL
  local ram cores
  ram="$(num_or_zero "$HW_RAM_MB")"; cores="${HW_CORES:-1}"

  # Embedding engine: local sentence-transformers on capable devices,
  # Ollama/API embeddings on weak ones (avoids loading torch at runtime).
  case "$INSTALL_PROFILE" in
    full)   T_RAG_EMBEDDING_ENGINE="" ; T_RAG_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2" ;;
    standard) T_RAG_EMBEDDING_ENGINE="" ; T_RAG_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2" ;;
    *)      T_RAG_EMBEDDING_ENGINE="ollama" ; T_RAG_EMBEDDING_MODEL="nomic-embed-text" ;;
  esac

  # Background generation chores: disable on weak hardware (huge CPU savings).
  case "$INSTALL_PROFILE" in
    full)      T_AUTOCOMPLETE="true"  ; T_TAGS="true"  ; T_TITLE="true"  ; T_FOLLOWUP="true" ;;
    standard)  T_AUTOCOMPLETE="true"  ; T_TAGS="true"  ; T_TITLE="true"  ; T_FOLLOWUP="true" ;;
    light)     T_AUTOCOMPLETE="false" ; T_TAGS="true"  ; T_TITLE="true"  ; T_FOLLOWUP="false" ;;
    minimal)   T_AUTOCOMPLETE="false" ; T_TAGS="false" ; T_TITLE="true"  ; T_FOLLOWUP="false" ;;
  esac

  # OpenMP / thread tuning for numpy/torch/transformers inside proot.
  local omp
  if (( cores > 4 )); then omp=4; else omp=$cores; fi
  if (( ram > 0 && ram < 4096 )); then omp=2; fi
  T_OMP_THREADS="$omp"

  case "$INSTALL_PROFILE" in
    full|standard) T_MEMORY_CTX="true" ;;
    *)             T_MEMORY_CTX="false" ;;
  esac
  T_IMAGE_GEN="true"
  T_LOG_LEVEL="INFO"
}

# ---------------------------------------------------------------------------
# Render the managed env block
# ---------------------------------------------------------------------------
render_managed_block() {
  ensure_secret_key
  profile_tuning
  local ollama_base="${OWI_OLLAMA_BASE_URL:-http://127.0.0.1:11434}"

  cat <<EOF
$MANAGED_BEGIN
# --- Open WebUI core ---
DATA_DIR=$OWI_DATA_DIR
WEBUI_URL=$OWI_URL
WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY
UVICORN_WORKERS=1
ENABLE_SIGNUP=true
DEFAULT_USER_ROLE=pending
ENABLE_OLLAMA_API=true
ENABLE_OPENAI_API=true
OLLAMA_BASE_URL=$ollama_base

# --- Privacy / telemetry ---
SCARF_NO_ANALYTICS=true
DO_NOT_TRACK=true
ANONYMIZED_TELEMETRY=false

# --- Platform ---
ENABLE_PLUGINS=true
ENABLE_MEMORY_SYSTEM_CONTEXT=$T_MEMORY_CTX

# --- RAG / embeddings (profile $INSTALL_PROFILE) ---
RAG_EMBEDDING_ENGINE=$T_RAG_EMBEDDING_ENGINE
RAG_EMBEDDING_MODEL=$T_RAG_EMBEDDING_MODEL
RAG_EMBEDDING_MODEL_AUTO_UPDATE=false
RAG_EMBEDDING_BATCH_SIZE=1

# --- Background generation chores (profile $INSTALL_PROFILE) ---
ENABLE_AUTOCOMPLETE_GENERATION=$T_AUTOCOMPLETE
ENABLE_TAGS_GENERATION=$T_TAGS
ENABLE_TITLE_GENERATION=$T_TITLE
ENABLE_FOLLOW_UP_GENERATION=$T_FOLLOWUP

# --- Runtime tuning for phones / proot ---
OMP_NUM_THREADS=$T_OMP_THREADS
MKL_NUM_THREADS=$T_OMP_THREADS
TOKENIZERS_PARALLELISM=false
PYTHONUNBUFFERED=1
UV_LINK_MODE=copy
$MANAGED_END
EOF
}

# ---------------------------------------------------------------------------
# Apply env file: preserve user section, replace managed block
# ---------------------------------------------------------------------------
apply_env_file() {
  ensure_dir "$OWI_INSTALL_DIR"
  local rendered
  rendered="$(render_managed_block)"

  if is_dry_run; then
    dry_msg "write $ENV_FILE"
    printf '%s\n' "$rendered" | sed 's/^/    /' | head -40
    return 0
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # Keep a backup of the previous file
    ensure_dir "$BACKUP_DIR"
    cp "$ENV_FILE" "$BACKUP_DIR/open_webui.env.$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true
    prune_backups "open_webui.env" 5

    # Strip the old managed block if present, keep everything else.
    if grep -qF "$MANAGED_BEGIN" "$ENV_FILE"; then
      sed -i "/^${MANAGED_BEGIN//\//\\/}$/,/^${MANAGED_END//\//\\/}$/d" "$ENV_FILE"
    fi
    local header
    header=$(grep -vE "^\s*#|^\s*$" "$ENV_FILE" | grep -vF "$MANAGED_END" || true)
    if [[ -n "$header" ]]; then
      ow_info "preserving user configuration: $(echo "$header" | sed 's/=.*/=.../' | tr '\n' ' ')"
    fi
    {
      printf '# Open WebUI environment - generated by the auto-installer\n'
      printf '# Lines between the markers below are owned by the installer and\n'
      printf '# are regenerated on every run. Edit anything else freely; your\n'
      printf '# edits are preserved across updates.\n'
      cat "$ENV_FILE"
      printf '\n'
      printf '%s\n' "$rendered"
    } > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    {
      printf '# Open WebUI environment - generated by the auto-installer\n'
      printf '# Lines between the markers below are owned by the installer.\n'
      printf '# Add your own settings above or below the block; they are preserved.\n\n'
      printf '%s\n' "$rendered"
    } > "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  ENV_FILE_HASH="$(sha256_file "$ENV_FILE")"
  ow_ok "wrote $ENV_FILE"
}

# Managed block hash (for change detection)
managed_block_hash() {
  if [[ -f "$ENV_FILE" ]]; then
    sed -n "/^${MANAGED_BEGIN//\//\\/}$/,/^${MANAGED_END//\//\\/}$/p" "$ENV_FILE" | sha256sum | awk '{print $1}'
  else
    echo "none"
  fi
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
prune_backups() {
  local prefix="$1" keep="$2"
  ls -1t "$BACKUP_DIR"/"$prefix".* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
}

backup_database() {
  # Back up the sqlite db before anything destructive. Best-effort.
  local db="$OWI_DATA_DIR/webui.db"
  [[ -f "$db" ]] || return 0
  ensure_dir "$BACKUP_DIR"
  local dst="$BACKUP_DIR/webui.db.$(date -u +%Y%m%d%H%M%S).bak"
  if is_dry_run; then dry_msg "cp $db $dst"; return 0; fi
  if cp "$db" "$dst" 2>/dev/null; then
    ow_ok "database backed up: $dst"
    prune_backups "webui.db" 5
  else
    ow_warn "could not back up database (continuing)"
  fi
}
