#!/usr/bin/env bash
#
# common.sh - shared helpers for setup_head.sh and setup_worker.sh.
# Sourced, not run directly. Callers must `set -Eeuo pipefail` first so the
# ERR trap below is inherited by functions and fires on any failed command.

# Fail loudly: print where we died and what died, instead of exiting silently.
trap 'rc=$?; echo "ERROR (exit $rc) at ${BASH_SOURCE[0]}:$LINENO: $BASH_COMMAND" >&2' ERR

RAY_VERSION="2.48.0"     # single source of truth; identical on head and workers
LAB_DIR="$HOME/raylab"

# Build the venv from a specific interpreter so an active conda/pyenv env can't
# silently pick a different Python. Ray requires the SAME Python minor version on
# every node, so all boxes must agree. Override with PYTHON=/path/to/python3.
PYTHON=${PYTHON:-/usr/bin/python3}

# Refuse to run as root, confirm sudo works, and detect the CPU architecture
# (sets $ARCH to the Debian/Prometheus name: amd64 or arm64).
preflight() {
  if [[ ${EUID} -eq 0 ]]; then
    echo "Run as your normal user (with sudo rights), not root." >&2
    exit 1
  fi
  sudo -v || { echo "This script needs sudo." >&2; exit 1; }
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

# Create the Ray venv and install the pinned Ray version. Rebuilds the venv if it
# is missing or was built from a different Python minor version than $PYTHON, so a
# stray conda/pyenv-built venv gets corrected automatically on the next run.
setup_venv() {
  mkdir -p "$LAB_DIR"
  local want have=""
  want=$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  if [[ -x "$LAB_DIR/venv/bin/python" ]]; then
    have=$("$LAB_DIR/venv/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
  fi
  if [[ "$have" != "$want" ]]; then
    if [[ -n "$have" ]]; then echo "Rebuilding venv (Python $have -> $want)"; fi
    rm -rf "$LAB_DIR/venv"
    "$PYTHON" -m venv "$LAB_DIR/venv"
  fi
  # shellcheck disable=SC1091
  source "$LAB_DIR/venv/bin/activate"
  pip install --upgrade pip
  pip install "ray[default]==$RAY_VERSION"
  deactivate
}

install_tailscale() {
  command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
  echo ">> Run 'sudo tailscale up' once, manually, to authenticate."
}

# write_service NAME  < unit-file-on-stdin
# Install a systemd unit, then enable and (re)start it. The restart is what makes
# re-running a setup script actually apply edits to the unit or its config.
write_service() {
  local name=$1
  sudo tee "/etc/systemd/system/${name}.service" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "$name"
  sudo systemctl restart "$name"
}

# Run the health check to confirm the install. Non-fatal: a service still warming
# up shouldn't fail the installer (or trip the ERR trap), so we swallow non-zero.
run_healthcheck() {
  echo "== Health check =="
  sleep 5   # let freshly (re)started services answer their ports
  bash "$(dirname "${BASH_SOURCE[0]}")/healthcheck.sh" || \
    echo "(some checks failed; services may still be starting - re-run: bash scripts/healthcheck.sh)"
}
