#!/bin/bash
# Stable Audio 3 sound-effects template for RunPod (runpod/comfyui images).
#
# Installs only what the bundled workflows use: ComfyUI's built-in Stable Audio 3
# nodes, the Prompt Cycler node for the batch workflow, and two model files. It
# never pip-installs into ComfyUI's Python: on these images PyTorch comes from the
# image, and a package that pins torch (or upgrades huggingface-hub) breaks ComfyUI.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[setup] $*"; }
die()  { echo "[setup][FATAL] $*" >&2; exit 1; }

echo "=== Starting Stable Audio 3 Sound FX Template Setup ==="
log "Template revision: $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"

# The image's /start.sh starts ComfyUI from this fixed path.
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"
MODELS="$COMFYUI_PATH/models"
HF_BASE="https://huggingface.co"

# Jupyter: the image's /start.sh runs it without a token when
# JUPYTER_DISABLE_AUTH=true, with JUPYTER_PASSWORD as the token when set, and not
# at all otherwise. The exported value reaches /start.sh through the final exec.
if [ "${JUPYTER_NO_AUTH:-1}" = "1" ]; then
  export JUPYTER_DISABLE_AUTH=true
  log "Jupyter authentication disabled: anyone with its URL can run commands."
fi

# The image already supplies these; contact apt mirrors only if one is missing.
packages=()
command -v wget >/dev/null || packages+=(wget)
command -v git >/dev/null || packages+=(git)
command -v ffmpeg >/dev/null || packages+=(ffmpeg)
if [ "${#packages[@]}" -gt 0 ]; then
  log "Installing missing system packages: ${packages[*]}"
  apt-get update && apt-get install -y --no-install-recommends "${packages[@]}" ||
    log "WARNING: apt-get failed; continuing with what the image provides."
fi

# ComfyUI on the volume: copy the image's build the first time. Never delete an
# existing folder - it may hold the user's outputs and models.
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  [ -e "$COMFYUI_PATH" ] && die "$COMFYUI_PATH exists but has no main.py; refusing to delete it."
  [ -f /opt/comfyui-baked/main.py ] || die "No ComfyUI at /opt/comfyui-baked. Use a runpod/comfyui image."
  log "First time setup: copying the image's ComfyUI to $COMFYUI_PATH ..."
  mkdir -p "$(dirname "$COMFYUI_PATH")"
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
else
  log "ComfyUI already at $COMFYUI_PATH"
fi

# Stable Audio 3 support (the T5Gemma text encoder) is part of ComfyUI itself.
grep -q "SAT5GemmaModel" "$COMFYUI_PATH/comfy/sd.py" 2>/dev/null ||
  die "This ComfyUI has no Stable Audio 3 support. Use runpod/comfyui:1.4.0-comfyuiv0.35.0-cuda12.8 or newer."

# Custom node: Prompt Cycler, used by the batch workflow. It needs nothing beyond
# what ComfyUI already has, so its requirements are deliberately not installed.
mkdir -p "$COMFYUI_PATH/custom_nodes"
CYCLER="$COMFYUI_PATH/custom_nodes/tenitsky-prompt-cycler-simple"
if [ ! -d "$CYCLER" ]; then
  log "Installing tenitsky-prompt-cycler-simple ..."
  git clone --depth 1 https://github.com/tenitsky/tenitsky-prompt-cycler-simple.git "$CYCLER" ||
    die "Could not clone tenitsky-prompt-cycler-simple"
else
  log "tenitsky-prompt-cycler-simple already installed"
fi

# An earlier version of this template installed ComfyUI-StableAudioSampler, which
# the workflows never used (it is for Stable Audio Open 1.0). Its requirements pin
# torch 2.7.1 and break ComfyUI, so move it out of the way.
OLD_NODE="$COMFYUI_PATH/custom_nodes/ComfyUI-StableAudioSampler"
if [ -d "$OLD_NODE" ]; then
  log "Disabling the unused ComfyUI-StableAudioSampler node (moved to custom_nodes.disabled/)."
  mkdir -p "$COMFYUI_PATH/custom_nodes.disabled"
  mv "$OLD_NODE" "$COMFYUI_PATH/custom_nodes.disabled/" ||
    log "WARNING: could not move $OLD_NODE; remove it by hand if ComfyUI fails to start."
fi

# ------------------------------------------------------------------ models
mkdir -p "$MODELS/checkpoints" "$MODELS/text_encoders"

# A complete safetensors file: header length, header JSON, and data size agree.
file_ok() {
  [ -f "$1" ] && [ "$(stat -c%s "$1")" -ge 1000000 ] || return 1
  python3 - "$1" <<'PY'
import json, os, struct, sys
try:
    with open(sys.argv[1], "rb") as f:
        size = struct.unpack("<Q", f.read(8))[0]
        if not 2 <= size <= min(os.path.getsize(sys.argv[1]) - 8, 100_000_000):
            raise ValueError
        header = json.loads(f.read(size))
        end = max(v["data_offsets"][1] for k, v in header.items() if k != "__metadata__")
        if end + size + 8 != os.path.getsize(sys.argv[1]):
            raise ValueError
except (OSError, ValueError, KeyError, TypeError, struct.error):
    sys.exit(1)
PY
}

download() {
  # $1 = Hugging Face repo, $2 = path in the repo, $3 = folder under models/
  local dest="$MODELS/$3/$(basename "$2")" part
  if file_ok "$dest"; then
    log "$(basename "$2") already present, skipping."
    return 0
  fi
  part="$dest.part"
  log "Downloading $(basename "$2") ..."
  local auth=()
  [ -n "${HF_TOKEN:-}" ] && auth=(--header="Authorization: Bearer $HF_TOKEN")
  # -c resumes an interrupted download on the next boot.
  wget -c -q --show-progress --tries=5 --read-timeout=120 "${auth[@]}" \
    -O "$part" "$HF_BASE/$1/resolve/main/$2" || { log "ERROR: download of $2 failed."; return 1; }
  file_ok "$part" || { log "ERROR: $2 is incomplete; restart the pod to resume."; return 1; }
  mv -f "$part" "$dest"
  log "$(basename "$2") done ($(du -h "$dest" | cut -f1))."
}

NEED_GB=15
FREE_GB=$(df -BG --output=avail /workspace | tail -1 | tr -dc '0-9')
log "Free space on /workspace: ${FREE_GB:-?}G (models need about 11G)"
[ "${FREE_GB:-0}" -ge "$NEED_GB" ] || die "Not enough disk space on /workspace: ${FREE_GB}G free, need ${NEED_GB}G."

FAILED=0
download Comfy-Org/stable-audio-3 text_encoders/t5gemma_b_b_ul2.safetensors text_encoders || FAILED=1
download Comfy-Org/stable-audio-3 checkpoints/stable_audio_3_medium_base.safetensors checkpoints || FAILED=1
# Optional: the distilled Medium model renders in 8 steps at CFG 1 (much faster).
if [ "${DOWNLOAD_SA3_MEDIUM:-0}" = "1" ]; then
  download Comfy-Org/stable-audio-3 checkpoints/stable_audio_3_medium.safetensors checkpoints || FAILED=1
fi
[ "$FAILED" = 0 ] || die "One or more model downloads failed. Restart the pod to resume them."

# ------------------------------------------------------------------ workflows
WF_DEST="$COMFYUI_PATH/user/default/workflows"
mkdir -p "$WF_DEST"
if compgen -G "$SCRIPT_DIR/workflows/*.json" >/dev/null; then
  cp -f "$SCRIPT_DIR"/workflows/*.json "$WF_DEST/"
  log "Workflows installed to $WF_DEST:"
  ls "$WF_DEST" | sed 's/^/[setup]   /'
else
  log "NOTE: no workflows found in $SCRIPT_DIR/workflows"
fi

log "=== Setup Complete! Handing over to the image's start script ==="
exec /start.sh
