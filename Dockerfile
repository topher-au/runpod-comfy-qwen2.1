FROM runpod/worker-comfyui:5.10.0-base AS comfy

WORKDIR /

COPY ./update-comfyui.py /

RUN /update-comfyui.py && \
	rm /update-comfyui.py

WORKDIR /comfyui

ENV COMFYUI_PATH=/comfyui

RUN .venv/bin/pip install -r requirements.txt

RUN ./.venv/bin/cm-cli install \
	comfyui-easy-use \
	comfyui-kjnodes \
	rgthree-comfy

COPY blank.png /comfyui/input

RUN sed -ire 's/python -u \/comfyui\/main.py/python -u \/comfyui\/main.py --use-ck-attention/' /start.sh
