#!/usr/bin/env bash
# Provision a Ray worker to RUN repo reviews (not just join the cluster):
#   - node + git + coreutils (for `timeout`) + modern bash (for `mapfile`)
#   - opencode, pointed at the ds4 model
#   - a clone of repo-review (the engine + opencode adapter)
# OS-agnostic (macOS via Homebrew, Debian/Ubuntu via apt). Idempotent.
#
#   REVIEW_MODEL_URL=http://compute01:8000/v1 bash scripts/setup_reviewer.sh
#
# Deploy from head like the other setup_*.sh (tar the repo over, run this).
# Note: repo-review is private, so this box needs GitHub auth - `gh auth login`
# (preferred) or git credentials/SSH for the https clone fallback.
set -Eeuo pipefail

MODEL_BASEURL="${REVIEW_MODEL_URL:-http://compute01:8000/v1}"
REPO_DIR="$HOME/github/repo-review"
# opencode talks to a local proxy that forwards to ds4 but forces
# tool_choice:none on compaction summaries (works around an opencode bug)
PROXY_PORT="${RR_PROXY_PORT:-8010}"
DS4_ROOT="${MODEL_BASEURL%/v1}"
PROXY_BASEURL="http://127.0.0.1:${PROXY_PORT}/v1"
OS="$(uname -s)"
echo "== reviewer setup on $(hostname) ($OS) =="

# toolchain
# ---------
if [[ "$OS" == "Darwin" ]]; then
  command -v brew >/dev/null 2>&1 || { echo "install Homebrew first" >&2; exit 1; }
  for p in node git coreutils bash; do
    brew list "$p" >/dev/null 2>&1 || brew install "$p"
  done
  # the review prompts call `timeout`; macOS coreutils ships it as `gtimeout`.
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(brew --prefix)/bin/gtimeout" "$HOME/.local/bin/timeout" 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"
else
  sudo apt-get update -y || true
  sudo apt-get install -y nodejs npm git coreutils bash curl || true
fi

# opencode
# --------
command -v opencode >/dev/null 2>&1 || curl -fsSL https://opencode.ai/install | bash
export PATH="$HOME/.opencode/bin:$PATH"

# repo-review (private)
# ---------------------
# gh handles auth; fall back to git
mkdir -p "$HOME/github"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only || true
elif command -v gh >/dev/null 2>&1; then
  gh repo clone natemacfadden/repo-review "$REPO_DIR"
else
  git clone https://github.com/natemacfadden/repo-review "$REPO_DIR"
fi

# opencode ds4 provider
# ---------------------
mkdir -p "$HOME/.config/opencode"
cfg="$HOME/.config/opencode/opencode.json"
[[ -f "$cfg" ]] && cp "$cfg" "$cfg.bak.$(date +%s)"
cat > "$cfg" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ds4": {
      "name": "ds4",
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "$PROXY_BASEURL", "apiKey": "dsv4-local" },
      "models": {
        "deepseek-v4-flash": {
          "name": "DeepSeek V4 Flash (ds4)",
          "limit": { "context": 131072, "output": 49152 }
        }
      }
    }
  }
}
JSON

# opencode -> ds4 proxy
# ---------------------
# forwards to ds4, but injects tool_choice:none on opencode's compaction
# summaries so ds4 returns text (opencode throws on a tool call there)
pkill -f 'adapters/opencode/proxy.mjs' 2>/dev/null || true
RR_DS4_URL="$DS4_ROOT" RR_PROXY_PORT="$PROXY_PORT" \
  nohup node "$REPO_DIR/adapters/opencode/proxy.mjs" \
  >"$HOME/.rr-proxy.log" 2>&1 &
sleep 1

# checks
# ------
echo "-- checks --"
node --version
command -v timeout >/dev/null 2>&1 && echo "timeout: ok" || echo "WARN: no timeout on PATH"
bash --version | head -1
curl -sf -m 8 "$DS4_ROOT/v1/models" >/dev/null \
  && echo "ds4 reachable at $DS4_ROOT: ok" \
  || echo "WARN: ds4 not reachable at $DS4_ROOT"
curl -sf -m 8 "$PROXY_BASEURL/models" >/dev/null \
  && echo "proxy reachable at $PROXY_BASEURL: ok" \
  || echo "WARN: proxy not reachable (is proxy.mjs running?)"
echo "== done =="
