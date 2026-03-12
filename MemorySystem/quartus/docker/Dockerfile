FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y locales && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Enable 32-bit support
RUN dpkg --add-architecture i386 && \
    apt update && \
    apt install -y \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        libxi6 \
        libfreetype6 \
        libfontconfig1 \
        libglib2.0-0 \
        libstdc++6 \
        lib32stdc++6 \
        libc6:i386 \
        libncurses5 \
        libncurses5:i386 \
        libnss3 \
        libxss1 \
        libasound2 \
        libudev1 \
        libusb-1.0-0 \
        libgtk2.0-dev \
        x11-apps \
        x11-xserver-utils \
        mesa-utils \
        libgl1-mesa-dri \
        libgl1-mesa-glx \
        device-tree-compiler \
        xvfb \
        wget \
        make \
        tar \
        sudo \
        xauth \
        bash && \
    apt clean

RUN rm -rf /var/lib/apt/lists/*

# Create a user matching host UID (avoids permission issues)
ARG USERNAME=quartus
ARG UID=1000
RUN useradd -m -u ${UID} -s /bin/bash ${USERNAME}

USER ${USERNAME}
WORKDIR /home/${USERNAME}
