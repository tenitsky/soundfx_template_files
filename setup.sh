#!/usr/bin/env bash
# =============================================================================
# RunPod bootstrap: ComfyUI + Stable Audio 3 (Comfy-Org repackaged checkpoints)
#
# Safe to re-run: existing models, nodes and the ComfyUI install are left alone.
# Everything is configurable by env vars set in the RunPod template.
# =============================================================================
set -Eeuo pipefail

# ------------------------------ configuration --------------------------------
# Leave COMFYUI_PATH empty to auto-detect the image's existing ComfyUI.
# Set it explicitly to override.
COMFYUI_PATH="${COMFYUI_PATH:-}"
COMFYUI_SOURCE="${COMFYUI_SOURCE:-/opt/comfyui-baked}"
WORKFLOW_DIR="${WORKFLOW_DIR:-/workspace/workflows}"
# Models always live on the persistent volume, wherever ComfyUI itself lives.
MODELS_DIR="${MODELS_DIR:-/workspace/models}"

# Optional git repo holding your custom_nodes/ workflows/ lora/ folders.
# Leave ASSETS_REPO empty to skip. REPO_DIR is also honoured if you pre-mount it.
ASSETS_REPO="${ASSETS_REPO:-}"
ASSETS_BRANCH="${ASSETS_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/tmp/temp_repo}"

# Custom node git repos, space-separated. Cloned into custom_nodes/ and updated
# on every boot. Their requirements.txt files are installed automatically.
CUSTOM_NODE_REPOS="${CUSTOM_NODE_REPOS:-\
https://github.com/tenitsky/tenitsky-prompt-cycler-simple}"

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

mkdir -p "$WORKFLOW_DIR"

# ------------------------------- ComfyUI --------------------------------------
# Find an existing install before falling back to the baked copy. RunPod's own
# comfyui images ship ComfyUI already - copying a second one wastes the volume.
if [ -n "$COMFYUI_PATH" ] && [ -f "$COMFYUI_PATH/main.py" ]; then
  log "using ComfyUI at $COMFYUI_PATH (explicit)"
elif [ -z "$COMFYUI_PATH" ]; then
  for c in /workspace/ComfyUI /workspace/comfyui /workspace/runpod-slim/ComfyUI \
           /ComfyUI /comfyui /opt/ComfyUI /opt/comfyui /root/ComfyUI; do
    if [ -f "$c/main.py" ]; then COMFYUI_PATH="$c"; break; fi
  done
  if [ -z "$COMFYUI_PATH" ]; then
    found="$(find / -maxdepth 4 -name main.py -path '*omfy*' \
             -not -path '*/custom_nodes/*' 2>/dev/null | head -n1 || true)"
    [ -n "$found" ] && COMFYUI_PATH="$(dirname "$found")"
  fi
  [ -n "$COMFYUI_PATH" ] && log "found existing ComfyUI at $COMFYUI_PATH"
fi

if [ -z "$COMFYUI_PATH" ]; then
  COMFYUI_PATH="/workspace/ComfyUI"
  [ -f "$COMFYUI_SOURCE/main.py" ] \
    || die "no ComfyUI found on this image and none baked at $COMFYUI_SOURCE"
  log "no ComfyUI on image - copying from $COMFYUI_SOURCE"
  mkdir -p "$COMFYUI_PATH"
  cp -a "$COMFYUI_SOURCE/." "$COMFYUI_PATH/"   # /. copies contents, not the dir
fi
mkdir -p "$COMFYUI_PATH/custom_nodes" "$COMFYUI_PATH/models"

# Keep weights on /workspace even when ComfyUI lives in the container fs,
# otherwise every pod restart re-downloads ~10 GB.
for sub in checkpoints text_encoders loras vae audio_encoders; do
  mkdir -p "$MODELS_DIR/$sub"
  link="$COMFYUI_PATH/models/$sub"
  if [ -L "$link" ]; then
    continue
  elif [ -d "$link" ]; then
    rmdir "$link" 2>/dev/null || { warn "$link has files - leaving it alone"; continue; }
  fi
  ln -s "$MODELS_DIR/$sub" "$link"
done
log "models -> $MODELS_DIR (symlinked into $COMFYUI_PATH/models)"

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

# Git-hosted custom nodes. Clone once, fast-forward on later boots. A single
# unreachable repo must not take the pod down.
if [ -n "${CUSTOM_NODE_REPOS// /}" ]; then
  log "syncing git custom nodes"
  for repo in $CUSTOM_NODE_REPOS; do
    name="$(basename "${repo%.git}")"
    target="$COMFYUI_PATH/custom_nodes/$name"
    if [ -d "$target/.git" ]; then
      echo "  -> updating $name"
      git -C "$target" pull --ff-only || warn "pull failed: $name (keeping existing copy)"
    else
      echo "  -> cloning $name"
      git clone --depth 1 "$repo" "$target" || warn "clone failed: $repo"
    fi
  done
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
