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
OS="$(uname -s)"
echo "== reviewer setup on $(hostname) ($OS) =="

# --- toolchain --------------------------------------------------------------
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

# --- opencode ---------------------------------------------------------------
command -v opencode >/dev/null 2>&1 || curl -fsSL https://opencode.ai/install | bash
export PATH="$HOME/.opencode/bin:$PATH"

# --- repo-review (private): gh handles auth; fall back to git ----------------
mkdir -p "$HOME/github"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only || true
elif command -v gh >/dev/null 2>&1; then
  gh repo clone natemacfadden/repo-review "$REPO_DIR"
else
  git clone https://github.com/natemacfadden/repo-review "$REPO_DIR"
fi

# --- opencode ds4 provider --------------------------------------------------
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
      "options": { "baseURL": "$MODEL_BASEURL", "apiKey": "dsv4-local" },
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

# --- checks -----------------------------------------------------------------
echo "-- checks --"
node --version
command -v timeout >/dev/null 2>&1 && echo "timeout: ok" || echo "WARN: no timeout on PATH"
bash --version | head -1
curl -sf -m 8 "$MODEL_BASEURL/models" >/dev/null \
  && echo "model reachable at $MODEL_BASEURL: ok" \
  || echo "WARN: model not reachable at $MODEL_BASEURL"
echo "== done =="
