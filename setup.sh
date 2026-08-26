#!/bin/bash
set -uo pipefail

log()  { echo "[setup] $*"; }
die()  { echo "[setup][FATAL] $*" >&2; exit 1; }

echo "=== Ensuring System Dependencies are Installed ==="
apt-get update && apt-get install -y wget ca-certificates git ffmpeg libsndfile1

echo "=== Starting Stable Audio 3 Template Setup ==="

# STEP 1: Install ComfyUI FIRST
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"
MODELS_STORE="/workspace/models"

# Self-heal: if ComfyUI isn't in the workspace yet, copy the baked build in
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  log "First time setup: copying baked ComfyUI to workspace..."
  rm -rf "$COMFYUI_PATH"
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
  log "ComfyUI copied to $COMFYUI_PATH"
else
  log "ComfyUI already exists at $COMFYUI_PATH"
fi

# STEP 2: Set up models directory and symlink
mkdir -p "$MODELS_STORE/checkpoints" "$MODELS_STORE/text_encoders" "$MODELS_STORE/vae" "$MODELS_STORE/clip"

# If ComfyUI/models is a real directory, move any existing content to our store
if [ -e "$COMFYUI_PATH/models" ] && [ ! -L "$COMFYUI_PATH/models" ]; then
  log "Moving existing models directory to $MODELS_STORE..."
  cp -rn "$COMFYUI_PATH/models/." "$MODELS_STORE/" 2>/dev/null || true
  rm -rf "$COMFYUI_PATH/models"
fi

# Create symlink if it doesn't exist
if [ ! -L "$COMFYUI_PATH/models" ]; then
  log "Creating symlink: $COMFYUI_PATH/models -> $MODELS_STORE"
  ln -s "$MODELS_STORE" "$COMFYUI_PATH/models"
fi

MODELS="$COMFYUI_PATH/models"
log "Models directory: $MODELS -> $(readlink -f $MODELS)"

# STEP 3: Set up Python
PY="$COMFYUI_PATH/.venv-cu128/bin/python"
if [ ! -x "$PY" ]; then
  log "cu128 venv not found, trying alternatives..."
  if [ -x "$COMFYUI_PATH/venv/bin/python" ]; then
    PY="$COMFYUI_PATH/venv/bin/python"
  elif [ -x "$COMFYUI_PATH/.venv/bin/python" ]; then
    PY="$COMFYUI_PATH/.venv/bin/python"
  else
    PY="$(command -v python3)"
  fi
fi
[ -x "$PY" ] || die "no usable python interpreter found"
PIP="$PY -m pip"
log "Using python: $PY"

# STEP 4: Set up caches and environment
export PIP_CACHE_DIR=/root/.pip-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
if [ -n "${HF_TOKEN:-}" ]; then 
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  log "HF token detected"
fi

# STEP 5: Install custom nodes
log "Installing custom nodes..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
cd "$COMFYUI_PATH/custom_nodes"
[ -d tenitsky-prompt-cycler-simple ] || git clone --depth 1 \
  https://github.com/tenitsky/tenitsky-prompt-cycler-simple.git tenitsky-prompt-cycler-simple

# STEP 6: Install node requirements
log "Installing node requirements..."
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" -exec $PIP install -r {} \;

# STEP 7: Disk sanity check
NEED_GB=4
[ "${DL_MEDIUM:-1}" = "1" ]      && NEED_GB=$((NEED_GB + 10))
[ "${DL_SMALL_MUSIC:-0}" = "1" ] && NEED_GB=$((NEED_GB + 3))
[ "${DL_QWEN:-0}" = "1" ]        && NEED_GB=$((NEED_GB + 6))
FREE_GB=$(df -BG --output=avail /workspace | tail -1 | tr -dc '0-9')
log "Free space on /workspace: ${FREE_GB}G, need ~${NEED_GB}G"
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || die "not enough disk: ${FREE_GB}G free, need ~${NEED_GB}G. Increase the volume size."

# STEP 8: Download models
log "Installing huggingface-hub..."
$PIP install -q -U "huggingface-hub" "hf_xet" || die "could not install huggingface-hub"

log "Starting model downloads..."
MODELS="$MODELS" DL_MEDIUM="${DL_MEDIUM:-1}" DL_SMALL_MUSIC="${DL_SMALL_MUSIC:-0}" DL_QWEN="${DL_QWEN:-0}" \
$PY - <<'PYEOF'
import os, sys
from huggingface_hub import hf_hub_download

dest = os.environ["MODELS"]
SA3 = "Comfy-Org/stable-audio-3"
jobs = [
    (SA3, "text_encoders/t5gemma_b_b_ul2.safetensors"),
    (SA3, "checkpoints/stable_audio_3_small_sfx.safetensors"),
]
if os.environ["DL_MEDIUM"] == "1":
    jobs.append((SA3, "checkpoints/stable_audio_3_medium.safetensors"))
if os.environ["DL_SMALL_MUSIC"] == "1":
    jobs.append((SA3, "checkpoints/stable_audio_3_small_music.safetensors"))
if os.environ["DL_QWEN"] == "1":
    jobs.append(("Comfy-Org/Qwen3.5", "text_encoders/qwen3.5_2b_bf16.safetensors"))

failed = []
for repo, fn in jobs:
    print(f"[setup] fetching {repo}/{fn}", flush=True)
    try:
        p = hf_hub_download(repo_id=repo, filename=fn, local_dir=dest)
        size_gb = os.path.getsize(p)/1e9
        print(f"[setup] OK {p} ({size_gb:.2f} GB)", flush=True)
    except Exception as e:
        print(f"[setup][ERROR] {repo}/{fn}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        failed.append(fn)

if failed:
    print("[setup][FATAL] downloads failed: " + ", ".join(failed), file=sys.stderr)
    sys.exit(1)
print("[setup] All model downloads completed successfully!", flush=True)
PYEOF
[ $? -eq 0 ] || die "model download failed -- see errors above. Not starting ComfyUI."

# STEP 9: Install workflows
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

# STEP 10: Verify everything is in place
echo "=== Model inventory ==="
echo "Checkpoints:"
ls -lh "$MODELS/checkpoints/" 2>/dev/null || echo "No checkpoints found!"
echo ""
echo "Text Encoders:"
ls -lh "$MODELS/text_encoders/" 2>/dev/null || echo "No text encoders found!"

log "Verifying symlink..."
if [ -L "$COMFYUI_PATH/models" ]; then
  log "✓ Models symlink is properly set"
  log "  $COMFYUI_PATH/models -> $(readlink -f $COMFYUI_PATH/models)"
else
  die "✗ Models symlink is not set correctly"
fi

log "Verifying model files..."
for f in "$MODELS/text_encoders/t5gemma_b_b_ul2.safetensors" \
         "$MODELS/checkpoints/stable_audio_3_small_sfx.safetensors"; do
  if [ -s "$f" ]; then
    log "✓ Found: $f"
  else
    die "✗ Missing required model: $f"
  fi
done

log "Setup complete! Handing over to start script..."
exec /start.sh
