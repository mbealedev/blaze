FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y \
        build-essential \
        gdb \
        binutils \
        && \
    rm -rf /var/lib/apt/lists/*