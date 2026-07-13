#!/usr/bin/env bash
#
# common.sh - shared helpers for setup_head.sh and setup_worker.sh.
# Sourced, not run directly. Callers must `set -Eeuo pipefail` first so the
# ERR trap below is inherited by functions and fires on any failed command.

# Fail loudly: print where we died and what died, instead of exiting silently.
trap 'rc=$?; echo "ERROR (exit $rc) at ${BASH_SOURCE[0]}:$LINENO: $BASH_COMMAND" >&2' ERR

RAY_VERSION="2.48.0"     # single source of truth; identical on head and workers
LAB_DIR="$HOME/raylab"
# Ray requires the SAME Python minor version on every node. We pin it here and let
# uv fetch that exact Python (see below), so the cluster's Python is independent of
# each box's OS Python and its updates. Override with PYTHON_VERSION=3.x.
PYTHON_VERSION="${PYTHON_VERSION:-3.12.13}"   # full patch pin: Ray checks the EXACT
# Python version, so all nodes must match to the patch. (3.13 also breaks Ray 2.48's dashboard.)

# Refuse to run as root, confirm sudo works, and detect the CPU architecture
# (sets $ARCH to the Debian/Prometheus name: amd64 or arm64).
preflight() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "This script targets Linux (systemd/apt). On macOS, join the cluster by hand -" >&2
    echo "see the MacBook section in README.md." >&2
    exit 1
  fi
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

# Install uv (Astral's Python/package manager) if it's missing. uv downloads
# standalone CPython builds, so the cluster's Python doesn't depend on the OS one.
# Installs to ~/.local/bin, which we add to PATH for the rest of this run.
ensure_uv() {
  command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || { echo "uv install failed (not on PATH)" >&2; exit 1; }
}

# Create the Ray venv on the pinned Python and install the pinned Ray version. uv
# fetches the exact Python, so every node matches regardless of OS. Rebuilds the
# venv if it's missing or on a different Python minor (e.g. a stray conda one).
setup_venv() {
  ensure_uv
  mkdir -p "$LAB_DIR"
  uv python install "$PYTHON_VERSION"
  local have=""
  if [[ -x "$LAB_DIR/venv/bin/python" ]]; then
    have=$("$LAB_DIR/venv/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)
  fi
  # Rebuild unless the venv's full version equals the pin (or starts with it, for a
  # minor-only pin like "3.12"). Ray compares the exact version, hence the patch pin.
  if [[ "$have" != "$PYTHON_VERSION" && "$have" != "$PYTHON_VERSION".* ]]; then
    if [[ -n "$have" ]]; then echo "Rebuilding venv (Python $have -> $PYTHON_VERSION)"; fi
    rm -rf "$LAB_DIR/venv"
    uv venv --python "$PYTHON_VERSION" "$LAB_DIR/venv"
  fi
  uv pip install --python "$LAB_DIR/venv/bin/python" "ray[default]==$RAY_VERSION"
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
  # On failure, surface the service's own logs instead of the opaque systemd message
  # (this is where Ray prints version mismatches, bad JSON, connection errors, etc.).
  if ! sudo systemctl restart "$name"; then
    echo "--- $name failed to start; recent logs: ---" >&2
    journalctl -u "$name" -n 20 --no-pager -o cat >&2 || true
    return 1
  fi
}

# Run the health check to confirm the install. Non-fatal: a service still warming
# up shouldn't fail the installer (or trip the ERR trap), so we swallow non-zero.
run_healthcheck() {
  echo "== Health check =="
  sleep 5   # let freshly (re)started services answer their ports
  bash "$(dirname "${BASH_SOURCE[0]}")/healthcheck.sh" || \
    echo "(some checks failed; services may still be starting - re-run: bash scripts/healthcheck.sh)"
}
