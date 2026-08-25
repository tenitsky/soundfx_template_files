#!/bin/bash

# --- Setup Configuration ---
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"
MODELS_DIR="$COMFYUI_PATH/models"
REPO_DIR="/tmp/temp_repo"

echo "=== Initializing Setup ==="
apt-get update && apt-get install -y wget ca-certificates

# --- Setup ComfyUI Environment ---
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  echo "Setting up ComfyUI..."
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
fi

# --- Install Nodes ---
echo "Installing custom nodes and requirements..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
[ -d "$REPO_DIR/custom_nodes" ] && cp -r "$REPO_DIR/custom_nodes"/* "$COMFYUI_PATH/custom_nodes/"
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" -exec pip install -r {} \;

# --- Download Models ---
echo "Downloading models..."
mkdir -p "$MODELS_DIR/text_encoders" "$MODELS_DIR/diffusion_models" "$MODELS_DIR/vae" "$MODELS_DIR/loras"

# Define URLs (Ref: https://huggingface.co)
BASE_URL="https://huggingface.co/resolve/main"
wget -q --show-progress -nc -P "$MODELS_DIR/text_encoders" "$BASE_URL/text_encoders/t5xxl_fp16.safetensors"
wget -q --show-progress -nc -P "$MODELS_DIR/text_encoders" "$BASE_URL/text_encoders/clip_l.safetensors"
wget -q --show-progress -nc -P "$MODELS_DIR/diffusion_models" "$BASE_URL/sd3_medium.safetensors"
wget -q --show-progress -nc -P "$MODELS_DIR/vae" "$BASE_URL/vae/sd3_vae.safetensors"

# --- Setup LoRAs and Cleanup ---
[ -d "$REPO_DIR/lora" ] && cp "$REPO_DIR/lora"/*.safetensors "$MODELS_DIR/loras/"
rm -rf "$REPO_DIR"

# --- Launch Services ---
echo "Starting Jupyter Lab..."
pip install -q jupyterlab
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password='' &

echo "Setup complete! Launching ComfyUI..."
exec /start.sh
