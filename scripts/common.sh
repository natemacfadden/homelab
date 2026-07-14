#!/usr/bin/env bash
#
# common.sh - shared helpers for the setup_*.sh scripts.
# Sourced, not run directly. Callers must `set -Eeuo pipefail` first so the
# ERR trap below is inherited by functions and fires on any failed command.

# Fail loudly: print where we died and what died, instead of exiting silently.
trap 'rc=$?; echo "ERROR (exit $rc) at ${BASH_SOURCE[0]}:$LINENO: $BASH_COMMAND" >&2' ERR

RAY_VERSION="2.48.0"     # identical on head and workers
LAB_DIR="$HOME/raylab"
# Ray checks the EXACT Python version, so pin to the patch and match on every node.
# uv fetches this Python, so it's independent of the OS. (3.13 breaks Ray 2.48.)
PYTHON_VERSION="${PYTHON_VERSION:-3.12.13}"

# Refuse root, confirm sudo, set $ARCH (amd64/arm64).
preflight() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "This script targets Linux (systemd/apt). On macOS use: bash scripts/setup_worker_mac.sh" >&2
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

# Install uv if missing (fetches standalone CPython, independent of the OS Python).
ensure_uv() {
  command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || { echo "uv install failed (not on PATH)" >&2; exit 1; }
}

# Build the Ray venv on the pinned Python; rebuild if missing or on a wrong version.
setup_venv() {
  ensure_uv
  mkdir -p "$LAB_DIR"
  uv python install "$PYTHON_VERSION"
  local have=""
  if [[ -x "$LAB_DIR/venv/bin/python" ]]; then
    have=$("$LAB_DIR/venv/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)
  fi
  # Rebuild unless it matches the pin (exact, or as a prefix for a minor-only pin).
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

# install_ssh - install OpenSSH and write an idempotent drop-in. Leaves password
# auth alone by default; only disables it when you explicitly ask (SSH_KEY_ONLY=1),
# so a setup/deploy run can never lock you out. SSH_TAILSCALE_ONLY=1 binds to the
# Tailscale IP.
install_ssh() {
  echo "== OpenSSH server (INSTALL_SSH=1; set INSTALL_SSH=0 to skip) =="
  sudo apt-get install -y openssh-server
  local conf=/etc/ssh/sshd_config.d/homelab.conf
  {
    echo "# Managed by homelab scripts/common.sh - edit here and re-run setup."
    echo "PubkeyAuthentication yes"
    if [[ "${SSH_KEY_ONLY:-0}" == "1" ]]; then   # opt-in only
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    if [[ "${SSH_TAILSCALE_ONLY:-0}" == "1" ]]; then
      local ts_ip; ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
      [[ -n "$ts_ip" ]] && echo "ListenAddress $ts_ip"
    fi
  } | sudo tee "$conf" >/dev/null

  # ssh.socket would override ListenAddress, so hand the port to sshd.service.
  if [[ "${SSH_TAILSCALE_ONLY:-0}" == "1" ]]; then
    sudo systemctl disable --now ssh.socket 2>/dev/null || true
  fi

  sudo mkdir -p /run/sshd   # sshd -t needs this; systemd recreates it at boot
  sudo sshd -t || { echo "sshd config test failed; not restarting." >&2; return 1; }
  sudo systemctl enable ssh
  sudo systemctl restart ssh
}

# write_service NAME  < unit-file-on-stdin
# Install a systemd unit and (re)start it; the restart is what applies re-run edits.
write_service() {
  local name=$1
  sudo tee "/etc/systemd/system/${name}.service" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "$name"
  # On failure, surface the service's own logs (where Ray prints the real error).
  if ! sudo systemctl restart "$name"; then
    echo "--- $name failed to start; recent logs: ---" >&2
    journalctl -u "$name" -n 20 --no-pager -o cat >&2 || true
    return 1
  fi
}

# Run the health check to confirm the install. Non-fatal: a warming-up service
# shouldn't fail the installer, so we swallow non-zero.
run_healthcheck() {
  echo "== Health check =="
  sleep 5   # let (re)started services answer their ports
  bash "$(dirname "${BASH_SOURCE[0]}")/healthcheck.sh" || \
    echo "(some checks failed; services may still be starting - re-run: bash scripts/healthcheck.sh)"
}
