#!/bin/bash
echo "=== Ensuring System Dependencies are Installed ==="
apt-get update && apt-get install -y wget ca-certificates git ffmpeg libsndfile1

echo "=== Starting Stable Audio 3 Template Setup ==="

# Correct ComfyUI path for runpod/comfyui:cuda12.8
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"

# Self-heal: if ComfyUI isn't in the workspace yet, copy the baked build in
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  echo "First time setup: Copying baked ComfyUI to workspace..."
  rm -rf "$COMFYUI_PATH"
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
fi

# Use the image's cu128 venv, fall back to pip
PY="$COMFYUI_PATH/.venv-cu128/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
PIP="$PY -m pip"
echo "Using python: $PY"

# Caches on EPHEMERAL container disk so they don't bloat the network volume.
export PIP_CACHE_DIR=/root/.pip-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
# HF cache PERSISTS -- --local-dir downloads don't duplicate into it.
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# 1. Clone custom nodes into the official ComfyUI directory
echo "Installing custom nodes..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
cd "$COMFYUI_PATH/custom_nodes"
[ -d tenitsky-prompt-cycler-simple ] || git clone --depth 1 \
  https://github.com/tenitsky/tenitsky-prompt-cycler-simple.git tenitsky-prompt-cycler-simple

# 2. Install node requirements (auto-discovered)
echo "Installing node requirements..."
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" -exec $PIP install -r {} \;

# 3. Download Stable Audio 3 weights (resume-safe; no-ops in seconds if present)
echo "Preparing model directories..."
mkdir -p "$COMFYUI_PATH/models/checkpoints" "$COMFYUI_PATH/models/text_encoders"
$PIP install -q -U huggingface-hub
HF_BIN="$(dirname "$PY")/hf"
[ -x "$HF_BIN" ] || HF_BIN="$(dirname "$PY")/huggingface-cli"

# The Comfy-Org repo layout mirrors ComfyUI's models/ tree, so --local-dir
# on models/ puts each file straight into the right subfolder.
MODELS="$COMFYUI_PATH/models"
echo "Downloading/verifying T5Gemma text encoder..."
"$HF_BIN" download Comfy-Org/stable-audio-3 text_encoders/t5gemma_b_b_ul2.safetensors --local-dir "$MODELS"

echo "Downloading/verifying Stable Audio 3 Small SFX..."
"$HF_BIN" download Comfy-Org/stable-audio-3 checkpoints/stable_audio_3_small_sfx.safetensors --local-dir "$MODELS"

if [ "${DL_MEDIUM:-1}" = "1" ]; then
  echo "Downloading/verifying Stable Audio 3 Medium..."
  "$HF_BIN" download Comfy-Org/stable-audio-3 checkpoints/stable_audio_3_medium.safetensors --local-dir "$MODELS"
fi

if [ "${DL_SMALL_MUSIC:-0}" = "1" ]; then
  "$HF_BIN" download Comfy-Org/stable-audio-3 checkpoints/stable_audio_3_small_music.safetensors --local-dir "$MODELS"
fi

if [ "${DL_QWEN:-0}" = "1" ]; then
  "$HF_BIN" download Comfy-Org/Qwen3.5 text_encoders/qwen3.5_2b_bf16.safetensors --local-dir "$MODELS"
fi

# 4. Copy bundled workflows so they show in the Workflows sidebar.
#    The cmd override cloned this repo to /tmp/temp_repo already.
echo "Installing workflows..."
WF_DEST="$COMFYUI_PATH/user/default/workflows"
mkdir -p "$WF_DEST"
if [ -d /tmp/temp_repo/workflows ]; then
  cp -rf /tmp/temp_repo/workflows/*.json "$WF_DEST/" 2>/dev/null \
    && echo "Workflows copied to $WF_DEST" \
    || echo "NOTE: no .json workflows found in /tmp/temp_repo/workflows"
else
  echo "NOTE: /tmp/temp_repo/workflows not found -- skipping workflow install"
fi

echo "=== Model inventory ==="
ls -lh "$MODELS/checkpoints" "$MODELS/text_encoders"

# 5. Start ComfyUI using the official RunPod entrypoint
echo "Setup complete! Handing over to start script..."
exec /start.sh
