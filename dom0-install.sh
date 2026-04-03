#!/bin/bash
# Calcium Channel — dom0 installer
# Run in dom0 (two steps — piping directly won't work due to stdin conflicts):
#   qvm-run -p <source-vm> 'cat /home/user/repos/calcium-channel/dom0-install.sh' > /tmp/cc-install.sh
#   bash /tmp/cc-install.sh <source-vm> [admin-vm]
#
# Arguments:
#   source-vm   VM containing the calcium-channel repo (files are copied from here)
#   admin-vm    VM that can register servers and manage ACLs (defaults to source-vm)
set -eu

SOURCE_VM="${1:?Usage: $0 <source-vm> [admin-vm]}"
ADMIN_VM="${2:-$SOURCE_VM}"
REPO_PATH="${CALCIUM_CHANNEL_PATH:-/home/user/repos/calcium-channel}"

echo "[*] Calcium Channel - dom0 installer"
echo "[*] Source VM: $SOURCE_VM"
echo "[*] Admin VM: $ADMIN_VM"
echo "[*] Repo path (in source VM): $REPO_PATH"

if ! qvm-check "$SOURCE_VM" &>/dev/null; then
    echo "ERROR: VM '$SOURCE_VM' does not exist" >&2
    exit 1
fi

mkdir -p /etc/qubes-rpc /etc/qubes/policy.d

# Copy qrexec services. --no-filter-escape-chars is required because the
# handler scripts contain embedded Python with special characters that
# qvm-run's default escape filter mangles.
echo "[*] Installing qrexec services in dom0..."
for svc in McpList McpRegister McpRename; do
    qvm-run --pass-io --no-filter-escape-chars "$SOURCE_VM" \
        "cat $REPO_PATH/dom0-setup/qubes-rpc/calciumchannel.$svc" \
        > "/etc/qubes-rpc/calciumchannel.$svc"
    chmod +x "/etc/qubes-rpc/calciumchannel.$svc"
    echo "  + calciumchannel.$svc"
done

echo "[*] Installing qrexec policy..."
qvm-run --pass-io --no-filter-escape-chars "$SOURCE_VM" \
    "cat $REPO_PATH/dom0-setup/policy.d/30-calcium-channel.policy" \
    | sed "s/ADMIN_VM/$ADMIN_VM/g" \
    > "/etc/qubes/policy.d/30-calcium-channel.policy"
echo "  + 30-calcium-channel.policy"

echo ""
echo "[+] Calcium Channel dom0 components installed."
echo "[+] Admin VM: $ADMIN_VM"
