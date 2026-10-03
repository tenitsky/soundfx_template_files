# Stable Audio 3 Sound FX - RunPod ComfyUI template

Generates sound effects and music loops with **Stable Audio 3 Medium Base** in ComfyUI,
one at a time or as a batch from a list of prompts, lengths and file names.

## RunPod template settings

| Setting | Value |
|---|---|
| Container image | `runpod/comfyui:1.4.0-comfyuiv0.35.0-cuda12.8` (or the `-cuda13.0` tag on CUDA 13 hosts) |
| Container start command | Paste [`runpod-start.json`](runpod-start.json) (readable source: [`bootstrap.sh`](bootstrap.sh)) |
| Volume mount path | `/workspace` (a Network Volume keeps models and outputs between pods) |
| Disk | 20 GB or more on `/workspace` (models are about 11 GB) |
| HTTP ports | `8188` (ComfyUI), `8888` (JupyterLab) |
| Environment variables | `JUPYTER_NO_AUTH=1`; optional `HF_TOKEN`, `DOWNLOAD_SA3_MEDIUM=1` |

The start command clones this repo on every boot and runs `setup.sh`, so a push to
GitHub reaches the next pod start. The model is about 9 GB, so a GPU with 16 GB or
more of VRAM should be enough (not benchmarked).

## What setup does

1. Copies the image's ComfyUI to `/workspace/runpod-slim/ComfyUI` on first boot.
2. Checks that ComfyUI has Stable Audio 3 support (built in since ComfyUI 0.30).
3. Installs the [Prompt Cycler](https://github.com/tenitsky/tenitsky-prompt-cycler-simple)
   node used by the batch workflow.
4. Downloads `stable_audio_3_medium_base.safetensors` and `t5gemma_b_b_ul2.safetensors`
   from [Comfy-Org/stable-audio-3](https://huggingface.co/Comfy-Org/stable-audio-3)
   (resumable; complete files are skipped on later boots).
5. Copies the workflows into ComfyUI's Workflows sidebar, then starts ComfyUI.

It never installs Python packages into ComfyUI's environment. PyTorch comes from the
image, and a package that pins its own torch breaks ComfyUI. An earlier version
installed `ComfyUI-StableAudioSampler` (for Stable Audio Open 1.0, unused here),
whose requirements pin torch 2.7.1; setup now moves it to `custom_nodes.disabled/`.

`DOWNLOAD_SA3_MEDIUM=1` also downloads the distilled **Stable Audio 3 Medium**, which
renders in 8 steps at CFG 1. To use it, pick it in the checkpoint loader and set the
KSampler to 8 steps, CFG 1.

## Workflows

- **sound_FX_single_sound** - type a prompt, set the length in seconds on
  `EmptyLatentAudio`, run. Output: `ComfyUI/output/audio/stable_audio_3_*.mp3`.
- **sound_FX_batch_sound** - three Prompt Cycler lists, one line per sound: the
  prompts, the lengths in seconds and the file names. Keep the three lists the same
  length and in the same order. Queue a batch count equal to the number of lines;
  each run takes the next line. The position is kept in memory: after a ComfyUI
  restart, or to start over, run once with **Cycle Reset** on, then turn it off.
  The lists wrap around after the last line, so queue only as many runs as lines.

## Jupyter

`JUPYTER_NO_AUTH=1` (the default) runs JupyterLab without a login: anyone with its
URL gets a shell. For a login, set `JUPYTER_NO_AUTH=0` and `JUPYTER_PASSWORD`.
