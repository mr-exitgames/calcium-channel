#!/bin/bash
# Calcium Channel — MCP VM installer
# Installs the dispatcher and an empty registry. Idempotent.
#
# Run from a checkout of the calcium-channel repo (in the MCP VM):
#   bash mcp-vm-install.sh
#
# Or pipe from dom0 (no checkout needed in the MCP VM):
#   qvm-run --pass-io --no-filter-escape-chars SOURCE_VM \
#       'tar -cC /path/to/calcium-channel mcp-vm-install.sh mcp-vm/qubes-rpc/calciumchannel.Mcp' \
#     | qvm-run -p MCP_VM \
#       'd=$(mktemp -d) && tar -xC "$d" && bash "$d/mcp-vm-install.sh" && rm -rf "$d"'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCHER_SRC="$SCRIPT_DIR/mcp-vm/qubes-rpc/calciumchannel.Mcp"

if [[ ! -f "$DISPATCHER_SRC" ]]; then
    echo "ERROR: dispatcher not found at $DISPATCHER_SRC" >&2
    echo "Run this from a checkout of the calcium-channel repo, or use the tar pipe form" >&2
    echo "documented at the top of this script." >&2
    exit 1
fi

# We need to write to /etc/qubes-rpc and /rw/config (both root-owned). Use sudo
# when running as user; skip it when already root (e.g. via qubes.VMRootShell on
# hardened VMs where the user has no sudo).
SUDO=""
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo > /dev/null || ! sudo -n true 2>/dev/null; then
        echo "ERROR: this installer needs root. Re-run with sudo, or invoke as root" >&2
        echo "(e.g. from dom0: qvm-run -u root -p MCP_VM ...)." >&2
        exit 1
    fi
    SUDO="sudo"
fi

echo "[*] Calcium Channel — MCP VM setup"

$SUDO mkdir -p /rw/config/calcium-channel

echo "[*] Installing dispatcher from $DISPATCHER_SRC"
$SUDO install -m 755 "$DISPATCHER_SRC" /rw/config/calcium-channel/calciumchannel.Mcp
echo "  + /rw/config/calcium-channel/calciumchannel.Mcp"

$SUDO install -m 755 "$DISPATCHER_SRC" /etc/qubes-rpc/calciumchannel.Mcp
echo "  + /etc/qubes-rpc/calciumchannel.Mcp"

# Persist across reboots: rc.local copies the dispatcher back into /etc/qubes-rpc.
RCLOCAL="/rw/config/rc.local"
if ! $SUDO grep -q "calcium-channel" "$RCLOCAL" 2>/dev/null; then
    $SUDO tee -a "$RCLOCAL" > /dev/null << 'RCLOCAL_ENTRY'

# Calcium Channel — install qrexec dispatcher on boot
cp /rw/config/calcium-channel/calciumchannel.Mcp /etc/qubes-rpc/calciumchannel.Mcp
chmod 755 /etc/qubes-rpc/calciumchannel.Mcp
RCLOCAL_ENTRY
    $SUDO chmod +x "$RCLOCAL"
    echo "  + $RCLOCAL (boot persistence)"
else
    echo "  ~ $RCLOCAL (already configured)"
fi

if ! $SUDO test -f /rw/config/calcium-channel/registry.json; then
    echo '{}' | $SUDO tee /rw/config/calcium-channel/registry.json > /dev/null
    echo "  + /rw/config/calcium-channel/registry.json (empty)"
else
    echo "  ~ /rw/config/calcium-channel/registry.json (already exists)"
fi

echo ""
echo "[+] MCP VM ready. Dispatcher will persist across reboots."
echo ""
echo "Next steps:"
echo "  1. Add MCP servers to /rw/config/calcium-channel/registry.json (in this VM)."
echo "     See mcp-vm/registry.json in the repo for the format."
echo ""
echo "  2. Register servers and set ACLs (from the admin VM):"
echo "     ./cc-admin register SERVER MCP_VM CLIENT_VM [CLIENT_VM ...]"
echo ""
echo "  3. Configure client VMs (in each client VM):"
echo "     ./client-install.sh"
