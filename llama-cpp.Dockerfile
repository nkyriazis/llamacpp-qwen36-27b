ARG CUDA_VERSION=13.2.1

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG LLAMA_CPP_REF=master
ARG CUDA_ARCH=120a
# FlashAttention K/V type pairs to compile kernels for (f16-f16 is always built).
ARG FA_QUANTS="q8_0-q8_0;q8_0-q4_0;q4_0-q4_0;bf16-bf16"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone https://github.com/ggml-org/llama.cpp
WORKDIR /opt/llama.cpp
RUN set -eux; \
        git fetch --all --tags --prune; \
        if git rev-parse --verify --quiet "origin/${LLAMA_CPP_REF}" >/dev/null; then \
            git checkout -B build-ref "origin/${LLAMA_CPP_REF}"; \
        elif git rev-parse --verify --quiet "${LLAMA_CPP_REF}^{commit}" >/dev/null; then \
            git checkout "${LLAMA_CPP_REF}"; \
        else \
            echo "error: unable to resolve LLAMA_CPP_REF=${LLAMA_CPP_REF}" >&2; \
            exit 1; \
        fi; \
        git log -1 --format='llama.cpp %H %cd' | tee /opt/llama.cpp/BUILD_REF

RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
RUN cmake -B build \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA_QUANTS="${FA_QUANTS}" \
    -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -Wl,-rpath-link,/usr/local/cuda/lib64/stubs" \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DCMAKE_BUILD_TYPE=Release
RUN LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH} \
    cmake --build build --config Release -j"$(nproc)" --target llama-server llama-bench

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libgomp1 \
    libssl3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/llama.cpp
COPY --from=builder /opt/llama.cpp/build/bin /opt/llama.cpp/bin
COPY --from=builder /opt/llama.cpp/BUILD_REF /opt/llama.cpp/BUILD_REF
ENV LD_LIBRARY_PATH=/opt/llama.cpp/bin:${LD_LIBRARY_PATH}

EXPOSE 8080

ENTRYPOINT ["/opt/llama.cpp/bin/llama-server"]
