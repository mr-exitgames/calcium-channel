#!/bin/bash
# Calcium Channel — MCP VM installer
# Run in dom0: qvm-run -p <source-vm> 'cat /home/user/calcium-channel/mcp-vm-install.sh' | qvm-run -p <mcp-vm> 'bash -s'
# Or copy and run directly in the MCP VM.
set -euo pipefail

echo "[*] Calcium Channel — MCP VM setup"

# Install dispatcher
echo "[*] Installing MCP dispatcher..."
sudo tee /etc/qubes-rpc/calciumchannel.Mcp > /dev/null << 'DISPATCHER'
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

COMMAND=$(python3 -c "
import json, sys
with open('$REGISTRY') as f:
    reg = json.load(f)
server = reg.get('$SERVER_NAME')
if not server:
    sys.exit(1)
print(server['command'])
" 2>/dev/null)

if [[ -z "$COMMAND" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32601,"message":"Unknown MCP server: '"$SERVER_NAME"'"},"id":null}' >&2
    exit 1
fi

ENV_FILE=$(python3 -c "
import json
with open('$REGISTRY') as f:
    reg = json.load(f)
print(reg.get('$SERVER_NAME', {}).get('env_file', ''))
" 2>/dev/null)

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

exec $COMMAND
DISPATCHER

sudo chmod 755 /etc/qubes-rpc/calciumchannel.Mcp
echo "  + /etc/qubes-rpc/calciumchannel.Mcp"

# Create registry directory
mkdir -p /rw/config/calcium-channel/env

# Create empty registry if none exists
if [[ ! -f /rw/config/calcium-channel/registry.json ]]; then
    echo '{}' > /rw/config/calcium-channel/registry.json
    echo "  + /rw/config/calcium-channel/registry.json (empty)"
else
    echo "  ~ /rw/config/calcium-channel/registry.json (already exists)"
fi

echo ""
echo "[+] MCP VM ready."
echo ""
echo "To add an MCP server to this VM's registry:"
echo '  python3 -c "'
echo '    import json'
echo '    reg = json.load(open(\"/rw/config/calcium-channel/registry.json\"))'
echo '    reg[\"github\"] = {\"command\": \"npx -y @modelcontextprotocol/server-github\", \"env_file\": \"/rw/config/calcium-channel/env/github.env\"}'
echo '    json.dump(reg, open(\"/rw/config/calcium-channel/registry.json\", \"w\"), indent=2)'
echo '  "'
echo ""
echo "Then create the env file with any required tokens:"
echo '  chmod 600 /rw/config/calcium-channel/env/github.env'
