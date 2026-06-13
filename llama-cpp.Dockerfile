FROM nvidia/cuda:12.9.1-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG LLAMA_CPP_REF=main
ARG CUDA_ARCH=120a

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone https://github.com/ggml-org/llama.cpp
WORKDIR /opt/llama.cpp
RUN set -eux; \
        git fetch --all --tags --prune; \
        if git rev-parse --verify --quiet "origin/${LLAMA_CPP_REF}" >/dev/null; then \
            git checkout -B build-ref "origin/${LLAMA_CPP_REF}"; \
        elif git rev-parse --verify --quiet "${LLAMA_CPP_REF}" >/dev/null; then \
            git checkout "${LLAMA_CPP_REF}"; \
        elif git rev-parse --verify --quiet origin/main >/dev/null; then \
            git checkout -B build-ref origin/main; \
        elif git rev-parse --verify --quiet origin/master >/dev/null; then \
            git checkout -B build-ref origin/master; \
        else \
            echo "error: unable to resolve LLAMA_CPP_REF=${LLAMA_CPP_REF} or fallback branches" >&2; \
            exit 1; \
        fi

WORKDIR /opt/llama.cpp/build
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
RUN cmake .. \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -Wl,-rpath-link,/usr/local/cuda/lib64/stubs" \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
    -DCMAKE_BUILD_TYPE=Release
RUN LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH} \
    make -j"$(nproc)" llama-server

FROM nvidia/cuda:12.9.1-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libgomp1 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/llama.cpp
COPY --from=builder /opt/llama.cpp/build/bin /opt/llama.cpp/bin
ENV LD_LIBRARY_PATH=/opt/llama.cpp/bin:${LD_LIBRARY_PATH}

EXPOSE 8080

ENTRYPOINT ["/opt/llama.cpp/bin/llama-server"]
