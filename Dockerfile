FROM runpod/worker-comfyui:5.10.0-base AS comfy

ARG VENV_PATH=/opt/venv
ARG COMFYUI_PATH=/comfyui

WORKDIR /

COPY ./update-comfyui.py /

RUN /update-comfyui.py && \
	rm /update-comfyui.py

WORKDIR ${COMFYUI_PATH}

ENV COMFYUI_PATH=${COMFYUI_PATH}

RUN ${VENV_PATH}/bin/pip install -r requirements.txt \
	opencv-python-headless

RUN pip install opencv-python
RUN comfy node install \
	comfyui-easy-use \
	comfyui-kjnodes \
	rgthree-comfy

COPY blank.png ${COMFYUI_PATH}/input
COPY ./my-start.sh /

CMD ["/my-start.sh"]

