#!/bin/bash
set -uo pipefail

log()  { echo "[setup] $*"; }
die()  { echo "[setup][FATAL] $*" >&2; exit 1; }

echo "=== Ensuring System Dependencies are Installed ==="
apt-get update && apt-get install -y wget ca-certificates git ffmpeg libsndfile1

echo "=== Starting Stable Audio 3 Template Setup ==="
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"
MODELS_STORE="/workspace/models"

mkdir -p "$MODELS_STORE/checkpoints" "$MODELS_STORE/text_encoders"

# Self-heal: if ComfyUI isn't in the workspace yet, copy the baked build in
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  log "First time setup: copying baked ComfyUI to workspace..."
  rm -rf "$COMFYUI_PATH"
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
fi

# models/ becomes a symlink to /workspace/models so the rm -rf above can
# never delete weights, and a re-baked image doesn't orphan them.
if [ ! -L "$COMFYUI_PATH/models" ]; then
  if [ -d "$COMFYUI_PATH/models" ]; then
    cp -rn "$COMFYUI_PATH/models/." "$MODELS_STORE/" 2>/dev/null || true
    rm -rf "$COMFYUI_PATH/models"
  fi
  ln -s "$MODELS_STORE" "$COMFYUI_PATH/models"
fi
MODELS="$COMFYUI_PATH/models"

PY="$COMFYUI_PATH/.venv-cu128/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
[ -x "$PY" ] || die "no usable python interpreter found"
PIP="$PY -m pip"
log "Using python: $PY"

export PIP_CACHE_DIR=/root/.pip-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
export HF_HOME=/workspace/.cache/huggingface
mkdir -p "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
if [ -n "${HF_TOKEN:-}" ]; then export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"; fi

# 1. Custom nodes
log "Installing custom nodes..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
cd "$COMFYUI_PATH/custom_nodes"
[ -d tenitsky-prompt-cycler-simple ] || git clone --depth 1 \
  https://github.com/tenitsky/tenitsky-prompt-cycler-simple.git tenitsky-prompt-cycler-simple

# 2. Node requirements
log "Installing node requirements..."
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" -exec $PIP install -r {} \;

# 3. Disk sanity check before touching 13 GB of weights
NEED_GB=4
[ "${DL_MEDIUM:-1}" = "1" ]      && NEED_GB=$((NEED_GB + 10))
[ "${DL_SMALL_MUSIC:-0}" = "1" ] && NEED_GB=$((NEED_GB + 3))
[ "${DL_QWEN:-0}" = "1" ]        && NEED_GB=$((NEED_GB + 6))
FREE_GB=$(df -BG --output=avail /workspace | tail -1 | tr -dc '0-9')
log "Free space on /workspace: ${FREE_GB}G, need ~${NEED_GB}G"
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || die "not enough disk: ${FREE_GB}G free, need ~${NEED_GB}G. Increase the volume size."

# 4. Weights — via the library, not a guessed CLI path. Hard-fails on error.
$PIP install -q -U "huggingface-hub" "hf_xet" || die "could not install huggingface-hub"

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
        print(f"[setup] OK {p} ({os.path.getsize(p)/1e9:.2f} GB)", flush=True)
    except Exception as e:
        print(f"[setup][ERROR] {repo}/{fn}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        failed.append(fn)

if failed:
    print("[setup][FATAL] downloads failed: " + ", ".join(failed), file=sys.stderr)
    sys.exit(1)
PYEOF
[ $? -eq 0 ] || die "model download failed -- see errors above. Not starting ComfyUI."

# 5. Workflows
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

# 6. Verify before handing over
echo "=== Model inventory ==="
ls -lh "$MODELS/checkpoints" "$MODELS/text_encoders"
for f in "$MODELS/text_encoders/t5gemma_b_b_ul2.safetensors" \
         "$MODELS/checkpoints/stable_audio_3_small_sfx.safetensors"; do
  [ -s "$f" ] || die "missing required model: $f"
done

log "Setup complete! Handing over to start script..."
exec /start.sh
