#!/usr/bin/env bash
# Symlink the model snapshot
if [[ ! -e "/runpod-volume/models" ]]; then
	CACHE_BASE="/runpod-volume/huggingface-cache/hub/models--Comfy-Org--Qwen-Image-2.1/snapshots"
	SNAPSHOT_PATH="$(ls -d "${CACHE_BASE}/*" | head -n 1)"
	ln -s "${SNAPSHOT_PATH}" "/runpod-volume/models"
fi

# Add CK Attention parameter
sed -ire 's/python -u \/comfyui\/main.py/python -u \/comfyui\/main.py --use-ck-attention/' /start.sh
