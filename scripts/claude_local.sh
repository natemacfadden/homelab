#!/usr/bin/env bash
#
# claude_local.sh - run Claude Code against the big box's local LLM server
# instead of Anthropic's API. Extra args pass through to claude.
#
# Default backend is ds4-server (DeepSeek V4 Flash via its native Anthropic
# /v1/messages endpoint). The old llama.cpp backend is still available:
#   SERVICE=llama-server LLM_PORT=8081 MODEL=qwen3.6-35b-q8-xl bash scripts/claude_local.sh
#
# Usage (from any box):
#   bash scripts/claude_local.sh
#   bash scripts/claude_local.sh -p "explain this repo"
#
set -Eeuo pipefail

LLM_HOST="${LLM_HOST:-compute01}"
SERVICE="${SERVICE:-ds4-server}"
LLM_PORT="${LLM_PORT:-8000}"
MODEL="${MODEL:-deepseek-v4-flash}"
# context window of the local model - MUST match the server's context
# (ds4-server --ctx in its systemd unit; ds4 serves one session at a time, so
# no per-slot division), or Claude Code assumes ~200k and never auto-compacts
# before the server overflows
CTX="${CTX:-131072}"
# trigger compaction at this % of CTX (default 95). the check only runs
# between turns, and a single agentic turn (thinking + several file reads) can
# add 10-15k tokens - plus local tokenizers count higher than Claude Code's
# estimate. 85% leaves ~20k headroom, which covers that.
COMPACT_PCT="${COMPACT_PCT:-85}"

command -v claude >/dev/null 2>&1 || {
  echo "claude not installed; see https://code.claude.com (npm install -g @anthropic-ai/claude-code)" >&2
  exit 1
}

# ds4-server does not check API keys, any non-empty token satisfies claude.
# llama-server wants the real key, which lives on the big box; copy it once.
if [[ "$SERVICE" == "llama-server" ]]; then
  KEY_FILE="$HOME/llm/api.key"
  if [[ ! -s "$KEY_FILE" ]]; then
    mkdir -p "$HOME/llm"
    ssh "$LLM_HOST" 'cat ~/llm/api.key' > "$KEY_FILE" || {
      echo "Could not fetch API key from $LLM_HOST (need ssh access, see README)." >&2
      exit 1
    }
    chmod 600 "$KEY_FILE"
  fi
  AUTH_TOKEN="$(cat "$KEY_FILE")"
else
  AUTH_TOKEN="dsv4-local"
fi

# run a command on the LLM host: directly if we are it, over ssh otherwise
run_llm() {
  if [[ "$(hostname -s)" == "$LLM_HOST" ]]; then "$@"; else ssh "$LLM_HOST" "$*"; fi
}

# start the model server for this session and stop it when claude exits.
# needs passwordless sudo for exactly these systemctl commands on the
# LLM host (see /etc/sudoers.d/llama-server).
run_llm sudo systemctl start "$SERVICE"
trap 'run_llm sudo systemctl stop "$SERVICE"' EXIT

# ds4 maps and pins an 81 GB model at startup; first load takes minutes.
# GPU (GTT) memory fill is a live proxy for load progress, so show it.
gpu_used_gb() {
  run_llm cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null \
    | awk 'NR==1 {printf "%.1f", $1 / 1073741824}'
}

echo ">> waiting for $SERVICE on $LLM_HOST:$LLM_PORT (model load can take minutes) ..."
wait_start=$SECONDS
for i in $(seq 1 300); do
  if curl -fsS -o /dev/null -H "Authorization: Bearer $AUTH_TOKEN" \
      "http://$LLM_HOST:$LLM_PORT/v1/models" 2>/dev/null; then
    printf '\r\033[K>> %s ready after %ds\n' "$SERVICE" $((SECONDS - wait_start))
    break
  fi
  if [[ $i -eq 300 ]]; then
    printf '\n' >&2
    echo "$SERVICE did not become ready on $LLM_HOST:$LLM_PORT" >&2
    exit 1
  fi
  used_gb=$(gpu_used_gb || true)
  printf '\r\033[K   loading: %s GB in GPU memory, %ds elapsed' \
    "${used_gb:-?}" $((SECONDS - wait_start))
  sleep 2
done

export ANTHROPIC_BASE_URL="http://$LLM_HOST:$LLM_PORT"
export ANTHROPIC_AUTH_TOKEN="$AUTH_TOKEN"
export ANTHROPIC_MODEL="$MODEL"
# background/helper calls (title generation etc.) use the same local model
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
# auto-compact against the model's REAL window, not the ~200k Claude default
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CTX"
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$COMPACT_PCT"
# ds4 README recommendations for Claude Code against ds4-server: no phone-home
# side traffic, no non-streaming fallback, long idle timeout for slow prefill
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000

echo ">> Claude Code -> http://$LLM_HOST:$LLM_PORT ($MODEL, ctx $CTX," \
  "compact at ${COMPACT_PCT}%)"
# no exec: the shell must survive claude so the EXIT trap can stop the server
claude "$@"
