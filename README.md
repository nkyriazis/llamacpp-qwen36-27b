# llamacpp-qwen36-27b

Standalone llama.cpp stack for qwen3.6-27b-local.

This folder is intended to run independently, without any reference to another repository folder.

## Contents

- docker-compose.yml
- llama-cpp.Dockerfile
- .env.example
- models/models.ini
- models/Qwen3.6-27B-Q4_K_M.gguf
- scripts/up
- scripts/down
- scripts/verify-self-contained
- scripts/verify-runtime

## Prerequisites

- Docker Engine
- NVIDIA driver and NVIDIA Container Toolkit

## Run

1. cd into this folder.
2. Run ./scripts/up.

## Verify

1. Run ./scripts/verify-self-contained.
2. Run ./scripts/verify-runtime.

## Stop

Run ./scripts/down.

## Notes

- This stack does not auto-download models.
- Full vision/multimodal support is enabled through `mmproj` in `models/models.ini`.
- Ensure `models/mmproj-F16.gguf` is present.
- No Hugging Face token is needed for runtime with the bundled local model file.
- If you replace the model with a gated Hugging Face model, token requirements depend on that download workflow.
