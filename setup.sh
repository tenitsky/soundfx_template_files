#!/usr/bin/env bash
# =============================================================================
# RunPod bootstrap: ComfyUI + Stable Audio 3 (Comfy-Org repackaged checkpoints)
#
# Safe to re-run: existing models, nodes and the ComfyUI install are left alone.
# Everything is configurable by env vars set in the RunPod template.
# =============================================================================
set -Eeuo pipefail

# ------------------------------ configuration --------------------------------
COMFYUI_PATH="${COMFYUI_PATH:-/workspace/runpod-slim/ComfyUI}"
COMFYUI_SOURCE="${COMFYUI_SOURCE:-/opt/comfyui-baked}"
WORKFLOW_DIR="${WORKFLOW_DIR:-/workspace/workflows}"
MODELS_DIR="$COMFYUI_PATH/models"

# Optional git repo holding your custom_nodes/ workflows/ lora/ folders.
# Leave ASSETS_REPO empty to skip. REPO_DIR is also honoured if you pre-mount it.
ASSETS_REPO="${ASSETS_REPO:-}"
ASSETS_BRANCH="${ASSETS_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/tmp/temp_repo}"

# Which checkpoints to pull (set to 0 to skip any of them).
DL_MEDIUM="${DL_MEDIUM:-1}"          # stable_audio_3_medium        (distilled)
DL_MEDIUM_BASE="${DL_MEDIUM_BASE:-0}" # stable_audio_3_medium_base
DL_SMALL_SFX="${DL_SMALL_SFX:-1}"     # stable_audio_3_small_sfx
DL_SMALL_MUSIC="${DL_SMALL_MUSIC:-0}" # stable_audio_3_small_music
DL_QWEN="${DL_QWEN:-0}"               # qwen3.5 encoder, only for reprompt graphs

# HF_TOKEN is only needed if a repo is gated. Harmless when unset.
HF_TOKEN="${HF_TOKEN:-}"

# JupyterLab. Empty token = no auth = anyone with the pod URL is root. Don't.
START_JUPYTER="${START_JUPYTER:-1}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-}"

SA3="https://huggingface.co/Comfy-Org/stable-audio-3/resolve/main"
QWEN="https://huggingface.co/Comfy-Org/Qwen3.5/resolve/main"

# ------------------------------- helpers -------------------------------------
log()  { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[fail ]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO: $BASH_COMMAND"' ERR

PIP=(pip install --no-input --prefer-binary)
if pip install --help 2>/dev/null | grep -q -- --break-system-packages; then
  PIP+=(--break-system-packages)   # PEP 668 distros (Ubuntu 24.04+)
fi

# fetch <url> <destination>
# Resumable, skips completed files, refuses to leave a broken file behind.
fetch() {
  local url="$1" dest="$2" name
  name="$(basename "$dest")"

  if [ -s "$dest" ] && [ ! -f "$dest.part" ]; then
    log "skip $name (already present)"
    return 0
  fi

  log "downloading $name"
  local args=(--progress=bar:force:noscroll --tries=3 --timeout=30 -c -O "$dest.part")
  [ -n "$HF_TOKEN" ] && args+=(--header="Authorization: Bearer $HF_TOKEN")

  if ! wget "${args[@]}" "$url"; then
    rm -f "$dest.part"
    die "download failed: $url (gated repo? set HF_TOKEN)"
  fi

  # A 404/HTML landing page is not a model file.
  if [ "$(head -c 1 "$dest.part")" = "<" ]; then
    rm -f "$dest.part"
    die "got HTML instead of a model file: $url"
  fi

  mv "$dest.part" "$dest"
}

# --------------------------- system dependencies ------------------------------
log "installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  wget curl ca-certificates git git-lfs ffmpeg libsndfile1 libasound2-dev
update-ca-certificates >/dev/null 2>&1 || true

mkdir -p "$WORKFLOW_DIR" \
         "$MODELS_DIR/checkpoints" \
         "$MODELS_DIR/text_encoders" \
         "$MODELS_DIR/loras" \
         "$MODELS_DIR/audio_encoders"

# ------------------------------- ComfyUI --------------------------------------
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  [ -f "$COMFYUI_SOURCE/main.py" ] || die "no baked ComfyUI at $COMFYUI_SOURCE"
  log "copying ComfyUI from $COMFYUI_SOURCE"
  mkdir -p "$COMFYUI_PATH"
  # Trailing /. copies the *contents*, not the folder itself.
  cp -a "$COMFYUI_SOURCE/." "$COMFYUI_PATH/"
else
  log "ComfyUI already installed at $COMFYUI_PATH"
fi
mkdir -p "$COMFYUI_PATH/custom_nodes"

# ---------------------------- repo-supplied assets ----------------------------
if [ -n "$ASSETS_REPO" ] && [ ! -d "$REPO_DIR/.git" ]; then
  log "cloning assets repo"
  rm -rf "$REPO_DIR"
  git clone --depth 1 --branch "$ASSETS_BRANCH" "$ASSETS_REPO" "$REPO_DIR" \
    || warn "clone failed - continuing without repo assets"
  [ -d "$REPO_DIR" ] && (cd "$REPO_DIR" && git lfs pull || true)
fi

if [ -d "$REPO_DIR/custom_nodes" ]; then
  log "installing custom nodes"
  cp -a "$REPO_DIR/custom_nodes/." "$COMFYUI_PATH/custom_nodes/"
fi

if [ -d "$REPO_DIR/workflows" ]; then
  log "syncing workflows"
  cp -a "$REPO_DIR/workflows/." "$WORKFLOW_DIR/"
fi

if [ -d "$REPO_DIR/lora" ]; then
  log "syncing loras"
  find "$REPO_DIR/lora" -maxdepth 1 -name '*.safetensors' \
    -exec cp -n {} "$MODELS_DIR/loras/" \;
fi

# Node requirements. A single broken node must not kill the pod, so this block
# opts out of set -e deliberately.
log "installing custom node requirements"
set +e
while IFS= read -r req; do
  echo "  -> $req"
  "${PIP[@]}" -q -r "$req" || warn "requirements failed: $req"
done < <(find "$COMFYUI_PATH/custom_nodes" -maxdepth 2 -name requirements.txt)
set -e

# ------------------------------- model files ----------------------------------
fetch "$SA3/text_encoders/t5gemma_b_b_ul2.safetensors" \
      "$MODELS_DIR/text_encoders/t5gemma_b_b_ul2.safetensors"

[ "$DL_MEDIUM" = "1" ] && fetch \
  "$SA3/checkpoints/stable_audio_3_medium.safetensors" \
  "$MODELS_DIR/checkpoints/stable_audio_3_medium.safetensors"

[ "$DL_MEDIUM_BASE" = "1" ] && fetch \
  "$SA3/checkpoints/stable_audio_3_medium_base.safetensors" \
  "$MODELS_DIR/checkpoints/stable_audio_3_medium_base.safetensors"

[ "$DL_SMALL_SFX" = "1" ] && fetch \
  "$SA3/checkpoints/stable_audio_3_small_sfx.safetensors" \
  "$MODELS_DIR/checkpoints/stable_audio_3_small_sfx.safetensors"

[ "$DL_SMALL_MUSIC" = "1" ] && fetch \
  "$SA3/checkpoints/stable_audio_3_small_music.safetensors" \
  "$MODELS_DIR/checkpoints/stable_audio_3_small_music.safetensors"

[ "$DL_QWEN" = "1" ] && fetch \
  "$QWEN/text_encoders/qwen3.5_2b_bf16.safetensors" \
  "$MODELS_DIR/text_encoders/qwen3.5_2b_bf16.safetensors"

log "model inventory"
du -h "$MODELS_DIR"/checkpoints/* "$MODELS_DIR"/text_encoders/* 2>/dev/null || true

# --------------------------------- cleanup ------------------------------------
[ -n "$ASSETS_REPO" ] && rm -rf "$REPO_DIR"

# -------------------------------- JupyterLab ----------------------------------
if [ "$START_JUPYTER" = "1" ]; then
  "${PIP[@]}" -q jupyterlab
  if [ -z "$JUPYTER_TOKEN" ]; then
    JUPYTER_TOKEN="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
    warn "no JUPYTER_TOKEN set - generated one: $JUPYTER_TOKEN"
  fi
  log "starting JupyterLab on :$JUPYTER_PORT"
  nohup jupyter lab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --ServerApp.token="$JUPYTER_TOKEN" \
    --ServerApp.root_dir=/workspace \
    >/workspace/jupyter.log 2>&1 &
fi

# --------------------------------- launch -------------------------------------
trap - ERR
log "handing off to ComfyUI"
if [ -x /start.sh ]; then
  exec /start.sh
else
  warn "/start.sh not found - launching main.py directly"
  cd "$COMFYUI_PATH"
  exec python main.py --listen 0.0.0.0 --port 8188
fi
