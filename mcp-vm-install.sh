#!/bin/bash
# Calcium Channel — MCP VM installer
# Run in dom0: qvm-run -p <source-vm> 'cat /path/to/calcium-channel/mcp-vm-install.sh' | qvm-run -p <mcp-vm> 'bash -s'
# Or copy and run directly in the MCP VM.
set -euo pipefail

echo "[*] Calcium Channel — MCP VM setup"

# Create persistent directory
mkdir -p /rw/config/calcium-channel

# Install dispatcher to persistent storage
echo "[*] Installing MCP dispatcher..."
cat > /rw/config/calcium-channel/calciumchannel.Mcp << 'DISPATCHER'
#!/bin/bash
set -euo pipefail

SERVER_NAME="${QREXEC_SERVICE_ARGUMENT:-}"

if [[ -z "$SERVER_NAME" || ! "$SERVER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid or missing server name"},"id":null}' >&2
    exit 1
fi

REGISTRY="/rw/config/calcium-channel/registry.json"

if [[ ! -f "$REGISTRY" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32600,"message":"No registry found"},"id":null}' >&2
    exit 1
fi

# SECURITY: values passed via environment, never interpolated into Python code.
COMMAND=$(python3 -c "
import json, sys, os
with open(os.environ['CC_REGISTRY']) as f:
    reg = json.load(f)
server = reg.get(os.environ['CC_SERVER'])
if not server:
    print('NOT_FOUND', file=sys.stderr)
    sys.exit(1)
print(server['command'])
" CC_REGISTRY="$REGISTRY" CC_SERVER="$SERVER_NAME" 2>/dev/null)

if [[ -z "$COMMAND" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32601,"message":"Unknown MCP server: '"$SERVER_NAME"'"},"id":null}' >&2
    exit 1
fi

exec bash -c "$COMMAND"
DISPATCHER

chmod 755 /rw/config/calcium-channel/calciumchannel.Mcp
echo "  + /rw/config/calcium-channel/calciumchannel.Mcp"

# Copy to qrexec directory (non-persistent, needed for current session)
sudo cp /rw/config/calcium-channel/calciumchannel.Mcp /etc/qubes-rpc/calciumchannel.Mcp
sudo chmod 755 /etc/qubes-rpc/calciumchannel.Mcp
echo "  + /etc/qubes-rpc/calciumchannel.Mcp"

# Add to rc.local for persistence across reboots
RCLOCAL="/rw/config/rc.local"
if ! grep -q "calcium-channel" "$RCLOCAL" 2>/dev/null; then
    sudo tee -a "$RCLOCAL" > /dev/null << 'RCLOCAL_ENTRY'

# Calcium Channel — install qrexec dispatcher on boot
cp /rw/config/calcium-channel/calciumchannel.Mcp /etc/qubes-rpc/calciumchannel.Mcp
chmod 755 /etc/qubes-rpc/calciumchannel.Mcp
RCLOCAL_ENTRY
    sudo chmod +x "$RCLOCAL"
    echo "  + $RCLOCAL (boot persistence)"
else
    echo "  ~ $RCLOCAL (already configured)"
fi

# Create empty registry if none exists
if [[ ! -f /rw/config/calcium-channel/registry.json ]]; then
    echo '{}' > /rw/config/calcium-channel/registry.json
    echo "  + /rw/config/calcium-channel/registry.json (empty)"
else
    echo "  ~ /rw/config/calcium-channel/registry.json (already exists)"
fi

echo ""
echo "[+] MCP VM ready. Dispatcher will persist across reboots."
echo ""
echo "Next steps:"
echo "  1. Add MCP servers to the registry (in this VM):"
echo '     python3 -c "'
echo '       import json'
echo '       reg = json.load(open(\"/rw/config/calcium-channel/registry.json\"))'
echo '       reg[\"files\"] = {\"command\": \"npx -y @modelcontextprotocol/server-filesystem /home/user\"}'
echo '       json.dump(reg, open(\"/rw/config/calcium-channel/registry.json\", \"w\"), indent=2)'
echo '     "'
echo ""
echo "  2. Register servers and set ACLs (from admin VM):"
echo '     echo '\''{"server":"files","mcp_vm":"<this-vm>","allow":["work-vm"]}'\'' \'
echo '       | qrexec-client-vm dom0 calciumchannel.McpRegister'
echo ""
echo "  3. Configure client VMs (in each client VM):"
echo "     ./client-install.sh"
