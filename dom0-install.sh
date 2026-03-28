#!/bin/bash
# Calcium Channel — dom0 installer
# Run in dom0: qvm-run -p <source-vm> 'cat /home/user/calcium-channel/dom0-install.sh' | bash -s <source-vm> [admin-vm]
set -euo pipefail

SOURCE_VM="${1:?Usage: $0 <source-vm> [admin-vm]}"
ADMIN_VM="${2:-$SOURCE_VM}"

echo "[*] Calcium Channel — dom0 installer"
echo "[*] Source VM: $SOURCE_VM"
echo "[*] Admin VM: $ADMIN_VM"

# Install dom0 qrexec services
echo "[*] Installing qrexec services in dom0..."
for svc in McpList McpRegister; do
    qvm-run -p "$SOURCE_VM" "cat /home/user/calcium-channel/dom0-setup/qubes-rpc/calciumchannel.$svc" \
        > "/etc/qubes-rpc/calciumchannel.$svc"
    chmod +x "/etc/qubes-rpc/calciumchannel.$svc"
    echo "  + calciumchannel.$svc"
done

# Install policy
echo "[*] Installing qrexec policy..."
qvm-run -p "$SOURCE_VM" "cat /home/user/calcium-channel/dom0-setup/policy.d/30-calcium-channel.policy" \
    | sed "s/ADMIN_VM/$ADMIN_VM/g" \
    > "/etc/qubes/policy.d/30-calcium-channel.policy"
echo "  + /etc/qubes/policy.d/30-calcium-channel.policy"

echo ""
echo "[+] Calcium Channel dom0 components installed."
echo "[+] Next: run mcp-vm-install.sh in each VM that will host MCP servers."
echo ""
echo "To register an MCP server (from $ADMIN_VM):"
echo '  echo '\''{"server":"github","mcp_vm":"mcp-vm","allow":["work-vm"]}'\'' | qrexec-client-vm dom0 calciumchannel.McpRegister'
