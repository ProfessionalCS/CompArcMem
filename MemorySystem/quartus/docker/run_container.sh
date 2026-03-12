#!/bin/bash

# Allow Docker containers to connect to X11
xhost +local:docker

# Quartus installation
HOST_QUARTUS="$HOME/altera_lite/25.1std"
CONTAINER_QUARTUS="/home/quartus/altera/25.1std"

# Lab / working files
HOST_DOCS="$HOME/Documents/CompArcMem/MemorySystem"
CONTAINER_DOCS="/home/quartus/memory_system"

# Entrypoint script
HOST_ENTRYPOINT="$HOME/Documents/CompArcMem/MemorySystem/quartus/docker/entrypoint.sh"
CONTAINER_ENTRYPOINT="/entrypoint.sh"

# Check paths
for path in "$HOST_QUARTUS" "$HOST_DOCS" "$HOST_ENTRYPOINT"; do
  if [ ! -e "$path" ]; then
    echo "Error: path does not exist: $path"
  fi
done

chmod +x entrypoint.sh

# Docker run command
docker run -it --rm \
  --ipc=host \
  --security-opt label=disable \
  --privileged \
  -u $(id -u):$(id -g) \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v ${HOST_QUARTUS}:${CONTAINER_QUARTUS} \
  -v ${HOST_DOCS}:${CONTAINER_DOCS}:Z \
  -v /dev/bus/usb:/dev/bus/usb \
  --device /dev/dri \
  -v ${HOST_ENTRYPOINT}:${CONTAINER_ENTRYPOINT}:ro \
  --entrypoint ${CONTAINER_ENTRYPOINT} \
  quartus-ubuntu
