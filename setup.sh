#!/bin/bash
set -uo pipefail

log()  { echo "[setup] $*"; }
die()  { echo "[setup][FATAL] $*" >&2; exit 1; }

echo "=== Ensuring System Dependencies are Installed ==="
apt-get update && apt-get install -y wget ca-certificates git ffmpeg libsndfile1

echo "=== Starting Stable Audio 3 Medium Base Template Setup ==="

# Define the correct ComfyUI path for runpod/comfyui:cuda12.8
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"

# Self-heal: if ComfyUI isn't in the workspace yet, copy the baked build in
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  log "First time setup: Copying baked ComfyUI to workspace..."
  rm -rf "$COMFYUI_PATH"
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
  log "ComfyUI copied to $COMFYUI_PATH"
else
  log "ComfyUI already exists at $COMFYUI_PATH"
fi

# CRITICAL: Find the correct Python environment with PyTorch
log "Locating Python environment with PyTorch..."

PYTHON_PATHS=(
  "$COMFYUI_PATH/.venv-cu128/bin/python"
  "$COMFYUI_PATH/venv/bin/python"
  "$COMFYUI_PATH/.venv/bin/python"
  "$COMFYUI_PATH/python_embeded/python"
)

PY=""
for p in "${PYTHON_PATHS[@]}"; do
  if [ -x "$p" ]; then
    log "Testing $p..."
    if $p -c "import torch; print(f'PyTorch {torch.__version__} found')" 2>/dev/null; then
      PY="$p"
      log "✓ Found Python with PyTorch at: $PY"
      break
    else
      log "✗ No PyTorch in $p"
    fi
  fi
done

# Fallback to system python
if [ -z "$PY" ]; then
  log "No venv with PyTorch found, checking system Python..."
  PY="$(command -v python3)"
  if [ -x "$PY" ] && $PY -c "import torch" 2>/dev/null; then
    log "System Python has PyTorch: $PY"
  else
    die "No Python environment with PyTorch found!"
  fi
fi

PIP="$PY -m pip"
log "Using Python: $PY"

# Verify PyTorch and CUDA
$PY -c "import torch; print(f'PyTorch: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')" || die "PyTorch verification failed"

# Set up environment
export PIP_CACHE_DIR=/root/.pip-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
if [ -n "${HF_TOKEN:-}" ]; then 
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  log "HF token detected"
fi

# Create models directory structure
log "Preparing model directories..."
mkdir -p "$COMFYUI_PATH/models/checkpoints" \
         "$COMFYUI_PATH/models/text_encoders" \
         "$COMFYUI_PATH/models/vae" \
         "$COMFYUI_PATH/models/clip"

# Install custom nodes
log "Installing custom nodes..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
cd "$COMFYUI_PATH/custom_nodes"

# Stable Audio Sampler (main node for SA3)
if [ ! -d "ComfyUI-StableAudioSampler" ]; then
  log "Installing ComfyUI-StableAudioSampler..."
  git clone --depth 1 https://github.com/lks-ai/ComfyUI-StableAudioSampler.git || log "Warning: Failed to clone ComfyUI-StableAudioSampler"
else
  log "ComfyUI-StableAudioSampler already installed"
fi

# Tenitsky Prompt Cycler Simple
if [ ! -d "tenitsky-prompt-cycler-simple" ]; then
  log "Installing tenitsky-prompt-cycler-simple..."
  git clone --depth 1 https://github.com/tenitsky/tenitsky-prompt-cycler-simple.git tenitsky-prompt-cycler-simple || log "Warning: Failed to clone tenitsky-prompt-cycler-simple"
else
  log "tenitsky-prompt-cycler-simple already installed"
fi

# Install node requirements using the CORRECT Python
log "Installing node requirements..."
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" | while read req; do
  log "Installing requirements from: $req"
  $PIP install -r "$req" 2>&1 | grep -v "already satisfied" || log "Warning: Some requirements may have failed to install from $req"
done

# Install huggingface-hub for model downloads
log "Installing huggingface-hub..."
$PIP install -q -U "huggingface-hub" "hf_xet" || die "Failed to install huggingface-hub"

# Disk space check (Medium Base ~10GB + T5Gemma ~6GB + Qwen3.5 ~4GB = ~20GB total)
NEED_GB=22
FREE_GB=$(df -BG --output=avail /workspace | tail -1 | tr -dc '0-9')
log "Free space on /workspace: ${FREE_GB}G, need ~${NEED_GB}G"
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || die "Not enough disk space: ${FREE_GB}G free, need ~${NEED_GB}G. Increase volume size."

# Download models
log "Starting model downloads..."
MODELS="$COMFYUI_PATH/models" \
$PY - <<'PYEOF'
import os, sys
from huggingface_hub import hf_hub_download

dest = os.environ["MODELS"]
jobs = [
    # T5Gemma Text Encoder (for Medium Base)
    ("Comfy-Org/stable-audio-3", "text_encoders/t5gemma_b_b_ul2.safetensors"),
    # Qwen3.5 Text Encoder (also needed)
    ("Comfy-Org/Qwen3.5", "text_encoders/qwen3.5_2b_bf16.safetensors"),
    # Stable Audio 3 Medium Base
    ("Comfy-Org/stable-audio-3", "checkpoints/stable_audio_3_medium_base.safetensors"),
]

failed = []
for repo, fn in jobs:
    print(f"[setup] Fetching {repo}/{fn}", flush=True)
    try:
        p = hf_hub_download(repo_id=repo, filename=fn, local_dir=dest)
        size_gb = os.path.getsize(p)/1e9
        print(f"[setup] ✓ Downloaded {fn} ({size_gb:.2f} GB)", flush=True)
        
        # Verify the file is in the correct location
        expected_path = os.path.join(dest, fn)
        if os.path.exists(expected_path):
            print(f"[setup] ✓ File at expected location: {expected_path}", flush=True)
        else:
            print(f"[setup] ⚠ File downloaded to: {p}", flush=True)
            print(f"[setup] ⚠ Expected at: {expected_path}", flush=True)
    except Exception as e:
        print(f"[setup] ✗ Failed to download {repo}/{fn}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        failed.append(fn)

if failed:
    print(f"[setup] FATAL: Downloads failed: {', '.join(failed)}", file=sys.stderr)
    sys.exit(1)

print("[setup] ✓ All model downloads completed successfully!", flush=True)
PYEOF
[ $? -eq 0 ] || die "Model download failed -- see errors above. Not starting ComfyUI."

# Copy workflows
log "Installing workflows..."
WF_DEST="$COMFYUI_PATH/user/default/workflows"
mkdir -p "$WF_DEST"
if [ -d /tmp/temp_repo/workflows ]; then
  cp -rf /tmp/temp_repo/workflows/*.json "$WF_DEST/" 2>/dev/null \
    && log "Workflows copied to $WF_DEST" \
    || log "NOTE: no .json workflows found in /tmp/temp_repo/workflows"
else
  log "NOTE: /tmp/temp_repo/workflows not found -- skipping workflow install"
fi

# Verify everything is in place
echo "=== Model Inventory ==="
echo "Checkpoints directory:"
ls -lh "$COMFYUI_PATH/models/checkpoints/" 2>/dev/null || echo "No checkpoints found!"
echo ""
echo "Text Encoders directory:"
ls -lh "$COMFYUI_PATH/models/text_encoders/" 2>/dev/null || echo "No text encoders found!"

# Verify critical files
log "Verifying model files..."
for f in \
  "$COMFYUI_PATH/models/checkpoints/stable_audio_3_medium_base.safetensors" \
  "$COMFYUI_PATH/models/text_encoders/t5gemma_b_b_ul2.safetensors" \
  "$COMFYUI_PATH/models/text_encoders/qwen3.5_2b_bf16.safetensors"; do
  if [ -s "$f" ]; then
    log "✓ Found: $(basename $f) ($(du -h $f | cut -f1))"
  else
    die "✗ Missing required model: $f"
  fi
done

# Verify custom nodes installed
log "Verifying custom nodes..."
for node in "ComfyUI-StableAudioSampler" "tenitsky-prompt-cycler-simple"; do
  if [ -d "$COMFYUI_PATH/custom_nodes/$node" ]; then
    log "✓ Custom node installed: $node"
  else
    log "⚠ Custom node missing: $node"
  fi
done

# Verify PyTorch one more time
log "Final verification..."
$PY -c "import torch; print(f'✓ PyTorch {torch.__version__} ready')" || die "PyTorch not working"

# Clean up
log "Cleaning up temporary files..."
rm -rf /tmp/temp_repo

log "=== Setup Complete! ==="
log "Models are in: $COMFYUI_PATH/models/"
log "  - Checkpoint: stable_audio_3_medium_base.safetensors"
log "  - Text Encoder: t5gemma_b_b_ul2.safetensors"
log "  - Text Encoder: qwen3.5_2b_bf16.safetensors"
log "Custom nodes in: $COMFYUI_PATH/custom_nodes/"
log "  - ComfyUI-StableAudioSampler"
log "  - tenitsky-prompt-cycler-simple"
log "Handing over to start script..."
exec /start.sh
