FROM ubuntu:24.04

# Use the emulator's Qt package. PySide needs extra libraries, and the full
# emulator image includes GUI and Rust tools that rcc does not use.
RUN apt-get update \
    && apt-get install -y --no-install-recommends qt6-base-dev-tools \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/lib/qt6/libexec/rcc"]
