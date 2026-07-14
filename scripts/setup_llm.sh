#!/usr/bin/env bash
#
# setup_llm.sh - llama.cpp server on the big box (Strix Halo, Vulkan).
# Downloads a pinned prebuilt Vulkan release, generates an API key once, and
# installs a systemd service serving an OpenAI-compatible API on the network.
#
# Usage (MODEL optional; defaults to the newest .gguf under ~/models):
#   bash scripts/setup_llm.sh
#   MODEL=~/models/foo.gguf LLM_PORT=8081 bash scripts/setup_llm.sh
# Idempotent: safe to re-run. Re-run with a different MODEL to swap models.
#
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./common.sh

LLAMA_VERSION="b9993"          # llama.cpp release tag, prebuilt ubuntu-vulkan-x64
LLM_DIR="$HOME/llm"
LLM_PORT="${LLM_PORT:-8081}"   # 8080 is taken by ray's metrics exporter
CTX_SIZE="${CTX_SIZE:-32768}"

preflight

# Pick a model: explicit MODEL env, else the newest gguf in ~/models.
# Multi-part models (-00001-of-...) load from part 1; skip the later parts.
MODEL="${MODEL:-}"
if [[ -z "$MODEL" ]]; then
  MODEL=$(find "$HOME/models" -name '*.gguf' ! -name '*-of-*' -o -name '*-00001-of-*' 2>/dev/null \
          | xargs -r ls -t | head -n1)
fi
if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
  echo "No model found. Put a .gguf under ~/models or pass MODEL=/path/to/model.gguf" >&2
  exit 1
fi
echo ">> Serving model: $MODEL"

echo "== [1/4] Vulkan runtime =="
sudo apt-get update
sudo apt-get install -y libvulkan1 mesa-vulkan-drivers curl

# The GPU can only map what TTM allows; on this box the kernel cmdline raises
# it to ~105 GB. Warn (don't edit grub) if that's missing, e.g. on a fresh OS.
if ! grep -q 'ttm.pages_limit' /proc/cmdline; then
  echo "WARNING: ttm.pages_limit not set; GPU-visible memory is capped near 64 GB." >&2
  echo "Add to GRUB_CMDLINE_LINUX_DEFAULT and update-grub + reboot:" >&2
  echo "  ttm.pages_limit=27648000 ttm.page_pool_size=27648000" >&2
fi

echo "== [2/4] llama.cpp $LLAMA_VERSION (prebuilt Vulkan) =="
mkdir -p "$LLM_DIR"
DEST="$LLM_DIR/llama.cpp-$LLAMA_VERSION"
if [[ ! -x "$DEST/llama-server" ]]; then
  tmp=$(mktemp -d)
  curl -fL -o "$tmp/llama.tar.gz" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/llama-$LLAMA_VERSION-bin-ubuntu-vulkan-x64.tar.gz"
  tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
  # tarball layout has shifted between releases; locate the binary and take its dir
  bin=$(find "$tmp" -name llama-server -type f | head -n1)
  [[ -n "$bin" ]] || { echo "llama-server not found in release tarball" >&2; exit 1; }
  rm -rf "$DEST"
  mv "$(dirname "$bin")" "$DEST"
  rm -rf "$tmp"
fi
ln -sfn "$DEST" "$LLM_DIR/current"

echo "== [3/4] API key + service =="
# Generate once, reuse on re-runs; clients read the same file or copy the value.
KEY_FILE="$LLM_DIR/api.key"
if [[ ! -s "$KEY_FILE" ]]; then
  (umask 077; openssl rand -hex 24 > "$KEY_FILE")
fi

write_service llama-server <<EOF
[Unit]
Description=llama.cpp server (OpenAI-compatible API on :$LLM_PORT)
After=network-online.target
Wants=network-online.target
[Service]
User=$USER
Environment=AMD_VULKAN_ICD=RADV
Environment=LD_LIBRARY_PATH=$LLM_DIR/current
ExecStart=$LLM_DIR/current/llama-server -m $MODEL --host 0.0.0.0 --port $LLM_PORT -ngl 999 -c $CTX_SIZE --jinja --api-key-file $KEY_FILE
Restart=on-failure
RestartSec=5
# kernel backstop, same as the ray worker; leaves headroom for the rest of the box
MemoryMax=95%
[Install]
WantedBy=multi-user.target
EOF

echo "== [4/4] Health check =="
# First start loads the whole model from disk; give it a while.
for i in $(seq 1 60); do
  curl -fsS "http://localhost:$LLM_PORT/health" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "http://localhost:$LLM_PORT/health" && echo || {
  echo "Server not healthy yet; watch: journalctl -u llama-server -f" >&2
  exit 1
}

echo "
Done. From any box on the tailnet/LAN:
  OPENAI_BASE_URL=http://$(hostname):$LLM_PORT/v1
  OPENAI_API_KEY=\$(cat $KEY_FILE)   # or copy it: $KEY_FILE
Swap models:  MODEL=/path/to/other.gguf bash scripts/setup_llm.sh"
