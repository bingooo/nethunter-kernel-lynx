FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    pahole \
    dwarves \
    git \
    python3 \
    zip \
    unzip \
    curl \
    ca-certificates \
    rsync \
    kmod \
    cpio \
    wget \
    libxml2 \
    clang-17 \
    lld-17 \
    llvm-17 \
    && rm -rf /var/lib/apt/lists/*

# Set clang-17 as default LLVM tools
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-17 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-17 100 && \
    update-alternatives --install /usr/bin/lld lld /usr/bin/lld-17 100 && \
    update-alternatives --install /usr/bin/ld.lld ld.lld /usr/bin/ld.lld-17 100 && \
    update-alternatives --install /usr/bin/llvm-strip llvm-strip /usr/bin/llvm-strip-17 100 && \
    update-alternatives --install /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-17 100 && \
    update-alternatives --install /usr/bin/llvm-nm llvm-nm /usr/bin/llvm-nm-17 100 && \
    update-alternatives --install /usr/bin/llvm-objcopy llvm-objcopy /usr/bin/llvm-objcopy-17 100 && \
    update-alternatives --install /usr/bin/llvm-readelf llvm-readelf /usr/bin/llvm-readelf-17 100

WORKDIR /workspace

CMD ["/bin/bash", "-c", "./build.sh && ./build-magisk.sh 6.1.145"]
