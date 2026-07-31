# Local AppLoad PC emulator (Linux) — macOS cannot run SOCK_SEQPACKET backends.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    RESOLUTION=1696x954x24 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    libgl1 \
    libxkbcommon0 \
    libxcb-cursor0 \
    libxcb-xinerama0 \
    openbox \
    python3 \
    python3-numpy \
    qt6-base-dev \
    qt6-base-dev-tools \
    qt6-declarative-dev \
    qt6-tools-dev \
    libgl1-mesa-dev \
    libglib2.0-0 \
    libqt6svg6 \
    qt6-image-formats-plugins \
    qml6-module-qtquick \
    qml6-module-qtquick-controls \
    qml6-module-qtquick-layouts \
    qml6-module-qtquick-templates \
    qml6-module-qtquick-window \
    qml6-module-qtqml \
    qml6-module-qtqml-workerscript \
    qml6-module-qtqml-models \
    qmake6 \
    novnc \
    websockify \
    x11vnc \
    xvfb \
    scrot \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable \
    && rustc --version

WORKDIR /opt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
