#!/bin/bash
# Calcium Channel — Client .mcp.json generator
# Run in a client VM to discover available MCP servers and generate config.
# Usage: ./client-gen.sh [output-path]
set -euo pipefail

OUTPUT="${1:-$HOME/.mcp.json}"

echo "[*] Calcium Channel — discovering available MCP servers..."

# Query dom0 for allowed servers
SERVERS=$(qrexec-client-vm dom0 calciumchannel.McpList 2>/dev/null)

if [[ -z "$SERVERS" || "$SERVERS" == "[]" ]]; then
    echo "[!] No MCP servers available for this VM."
    exit 0
fi

# Generate .mcp.json
python3 -c "
import json, sys, os

servers = json.loads('''$SERVERS''')

# Load existing config if present
output_path = '$OUTPUT'
existing = {}
if os.path.exists(output_path):
    with open(output_path) as f:
        existing = json.load(f)

mcp_servers = existing.get('mcpServers', {})

for srv in servers:
    name = srv['name']
    target = srv['target_vm']
    mcp_servers[name] = {
        'command': 'qrexec-client-vm',
        'args': [target, f'calciumchannel.Mcp+{name}']
    }
    print(f'  + {name} -> {target}')

existing['mcpServers'] = mcp_servers

with open(output_path, 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')

print(f'\n[+] Written to {output_path}')
print(f'[+] {len(servers)} MCP server(s) configured. Restart Claude Code to connect.')
"
