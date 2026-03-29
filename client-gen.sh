#!/bin/bash
# Calcium Channel — Client .mcp.json generator
# Run in a client VM to discover available MCP servers and generate config.
# Adds new servers, updates changed entries, and prunes stale ones.
# Usage: ./client-gen.sh [output-path]
set -euo pipefail

OUTPUT="${1:-$HOME/.mcp.json}"

echo "[*] Calcium Channel — discovering available MCP servers..."

# Query dom0 for allowed servers (may be empty)
SERVERS=$(qrexec-client-vm dom0 calciumchannel.McpList 2>/dev/null || echo "[]")

# Sync .mcp.json: add/update allowed servers, prune stale calcium-channel entries
python3 -c "
import json, os

servers = json.loads('''$SERVERS''')
allowed = {srv['name']: srv['target_vm'] for srv in servers}

output_path = '$OUTPUT'
existing = {}
if os.path.exists(output_path):
    with open(output_path) as f:
        existing = json.load(f)

mcp_servers = existing.get('mcpServers', {})

# Prune stale calcium-channel entries (not in current allowed list)
pruned = []
for name, cfg in list(mcp_servers.items()):
    args = cfg.get('args', [])
    is_cc = (cfg.get('command') == 'qrexec-client-vm'
             and len(args) == 2
             and args[1].startswith('calciumchannel.Mcp+'))
    if is_cc and name not in allowed:
        del mcp_servers[name]
        pruned.append(name)

# Add / update allowed entries
for name, target in allowed.items():
    mcp_servers[name] = {
        'command': 'qrexec-client-vm',
        'args': [target, f'calciumchannel.Mcp+{name}']
    }
    print(f'  + {name} -> {target}')

for name in pruned:
    print(f'  - {name} (removed)')

existing['mcpServers'] = mcp_servers

with open(output_path, 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')

total = len(allowed)
if total == 0 and not pruned:
    print('[!] No MCP servers available for this VM.')
else:
    print(f'\n[+] Written to {output_path}')
    if total:
        print(f'[+] {total} MCP server(s) configured. Restart Claude Code to connect.')
    if pruned:
        print(f'[+] {len(pruned)} stale entry/entries pruned.')
"
