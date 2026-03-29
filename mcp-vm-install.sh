#!/bin/bash
# Calcium Channel — MCP VM installer
# Run in dom0: qvm-run -p <source-vm> 'cat /home/user/calcium-channel/mcp-vm-install.sh' | qvm-run -p <mcp-vm> 'bash -s'
# Or copy and run directly in the MCP VM.
set -euo pipefail

echo "[*] Calcium Channel — MCP VM setup"

# Create persistent directories
mkdir -p /rw/config/calcium-channel/env

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

# Install management MCP server (same script as distributed by client-gen.sh)
echo "[*] Installing management MCP server..."
cat > /rw/config/calcium-channel/calcium-channel-mgmt.py << 'MGMT_EOF'
#!/usr/bin/env python3
"""
Calcium Channel — Management MCP server
Exposes list_servers, register_server, rename_server, and refresh_mcps as MCP tools.
Installed by client-gen.sh to /rw/config/calcium-channel/calcium-channel-mgmt.py

Works in any VM:
  - list_servers / refresh_mcps — available everywhere (filtered by dom0 policy)
  - register_server / rename_server — only work from the admin VM (dom0 enforces this)
"""
import json
import os
import subprocess
import sys

VERSION = "1.1"
MCP_JSON_DEFAULT = os.path.expanduser("~/.mcp.json")
SELF_PATH = "/rw/config/calcium-channel/calcium-channel-mgmt.py"

TOOLS = [
    {
        "name": "list_servers",
        "description": "List MCP servers this VM is authorized to access via Calcium Channel.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "register_server",
        "description": (
            "Register a new MCP server and set ACLs. "
            "Requires admin VM — dom0 policy blocks this call from other VMs."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "server": {
                    "type": "string",
                    "description": "Server name (letters, digits, hyphens, underscores)",
                },
                "mcp_vm": {
                    "type": "string",
                    "description": "VM that hosts the MCP server",
                },
                "allow": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "VMs to grant access",
                },
                "alias": {
                    "type": "string",
                    "description": "Optional display alias used as the tool namespace prefix in Claude Code",
                },
            },
            "required": ["server", "mcp_vm", "allow"],
        },
    },
    {
        "name": "rename_server",
        "description": (
            "Set or update the display alias for a registered MCP server. "
            "The alias becomes the key in .mcp.json and the tool namespace prefix "
            "(e.g., alias 'metatron' -> mcp__metatron__*). "
            "Pass an empty string to clear the alias and revert to the server name. "
            "Requires admin VM -- dom0 policy blocks this call from other VMs. "
            "Agents should call refresh_mcps after renaming to apply the change."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "server": {
                    "type": "string",
                    "description": "Canonical server name (as registered)",
                },
                "alias": {
                    "type": "string",
                    "description": "New display alias, or empty string to clear",
                },
            },
            "required": ["server", "alias"],
        },
    },
    {
        "name": "refresh_mcps",
        "description": (
            "Re-query authorized servers and update ~/.mcp.json. "
            "Prunes revoked entries and adds newly granted ones. "
            "Changes take effect after restarting Claude Code."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "output": {
                    "type": "string",
                    "description": f"Output path (default: {MCP_JSON_DEFAULT})",
                }
            },
        },
    },
]


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def _qrexec(service, stdin_data=None, timeout=10):
    result = subprocess.run(
        ["qrexec-client-vm", "dom0", service],
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.returncode, result.stdout, result.stderr


def tool_list_servers():
    rc, out, err = _qrexec("calciumchannel.McpList")
    if rc != 0:
        return f"Error calling McpList: {err.strip() or 'unknown error'}"
    try:
        servers = json.loads(out)
    except json.JSONDecodeError:
        return f"Unexpected response: {out}"
    if not servers:
        return "No MCP servers authorized for this VM."
    return json.dumps(servers, indent=2)


def tool_register_server(server, mcp_vm, allow, alias=None):
    payload = {"server": server, "mcp_vm": mcp_vm, "allow": allow}
    if alias is not None:
        payload["alias"] = alias
    rc, out, err = _qrexec("calciumchannel.McpRegister", stdin_data=json.dumps(payload))
    return out.strip() or err.strip() or ("OK" if rc == 0 else f"Failed (exit {rc})")


def tool_rename_server(server, alias):
    payload = json.dumps({"server": server, "alias": alias})
    rc, out, err = _qrexec("calciumchannel.McpRename", stdin_data=payload)
    return out.strip() or err.strip() or ("OK" if rc == 0 else f"Failed (exit {rc})")


def tool_refresh_mcps(output=None):
    output = output or MCP_JSON_DEFAULT

    rc, out, err = _qrexec("calciumchannel.McpList")
    if rc != 0:
        return f"Error calling McpList: {err.strip() or 'unknown error'}"
    try:
        servers = json.loads(out)
    except json.JSONDecodeError:
        return f"Unexpected McpList response: {out}"

    # Build set of canonical names for pruning
    allowed = {srv["name"] for srv in servers}

    existing = {}
    if os.path.exists(output):
        with open(output) as f:
            try:
                existing = json.load(f)
            except json.JSONDecodeError:
                pass

    mcp_servers = existing.get("mcpServers", {})

    # Prune stale calcium-channel qrexec entries (not the management server itself).
    # Match on the service name in args[1], not the .mcp.json key, so aliases don't
    # prevent pruning of revoked servers.
    pruned = []
    for key, cfg in list(mcp_servers.items()):
        args = cfg.get("args", [])
        is_cc_qrexec = (
            cfg.get("command") == "qrexec-client-vm"
            and len(args) == 2
            and isinstance(args[1], str)
            and args[1].startswith("calciumchannel.Mcp+")
        )
        if is_cc_qrexec:
            service_name = args[1][len("calciumchannel.Mcp+"):]
            if service_name not in allowed:
                del mcp_servers[key]
                pruned.append(key)

    # Add / update authorized entries, using alias as key if set
    added = []
    for srv in servers:
        name = srv["name"]
        target = srv["target_vm"]
        key = srv.get("alias") or name
        mcp_servers[key] = {
            "command": "qrexec-client-vm",
            "args": [target, f"calciumchannel.Mcp+{name}"],
        }
        label = f"{key} ({name}) -> {target}" if key != name else f"{name} -> {target}"
        added.append(label)

    # Always keep the management server entry
    mcp_servers["calcium-channel"] = {
        "command": "python3",
        "args": [SELF_PATH],
    }

    existing["mcpServers"] = mcp_servers
    with open(output, "w") as f:
        json.dump(existing, f, indent=2)
        f.write("\n")

    lines = []
    if added:
        lines.append(f"Added/updated: {', '.join(added)}")
    if pruned:
        lines.append(f"Pruned: {', '.join(pruned)}")
    if not added and not pruned:
        lines.append("No changes to MCP server entries.")
    lines.append(f"Written to {output}. Restart Claude Code to apply changes.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# MCP JSON-RPC handler
# ---------------------------------------------------------------------------

def handle(req):
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params", {})

    def ok(result):
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    def err(code, msg):
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": msg}}

    def text(content):
        return ok({"content": [{"type": "text", "text": content}]})

    if method == "initialize":
        return ok({
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "calcium-channel", "version": VERSION},
        })

    if method == "tools/list":
        return ok({"tools": TOOLS})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments", {})
        try:
            if name == "list_servers":
                return text(tool_list_servers())
            elif name == "register_server":
                return text(tool_register_server(
                    args["server"], args["mcp_vm"], args.get("allow", []),
                    alias=args.get("alias"),
                ))
            elif name == "rename_server":
                return text(tool_rename_server(args["server"], args["alias"]))
            elif name == "refresh_mcps":
                return text(tool_refresh_mcps(args.get("output")))
            else:
                return err(-32601, f"Unknown tool: {name}")
        except KeyError as e:
            return err(-32602, f"Missing argument: {e}")
        except Exception as e:
            return err(-32603, str(e))

    if method == "ping":
        return ok({})

    # Notifications have no id — no response expected
    if req_id is None:
        return None

    return err(-32601, f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
MGMT_EOF
chmod 755 /rw/config/calcium-channel/calcium-channel-mgmt.py
echo "  + /rw/config/calcium-channel/calcium-channel-mgmt.py"

# Add management server entry to ~/.mcp.json
MCP_JSON="$HOME/.mcp.json"
python3 -c "
import json, os

path = '$MCP_JSON'
existing = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            existing = json.load(f)
        except json.JSONDecodeError:
            pass

mcp_servers = existing.get('mcpServers', {})
mcp_servers['calcium-channel'] = {
    'command': 'python3',
    'args': ['/rw/config/calcium-channel/calcium-channel-mgmt.py']
}
existing['mcpServers'] = mcp_servers

with open(path, 'w') as f:
    json.dump(existing, f, indent=2)
    f.write('\n')
print(f'  + calcium-channel entry in {path}')
"

echo ""
echo "[+] MCP VM ready. Dispatcher will persist across reboots."
echo ""
echo "To add an MCP server to this VM's registry:"
echo '  python3 -c "'
echo '    import json'
echo '    reg = json.load(open(\"/rw/config/calcium-channel/registry.json\"))'
echo '    reg[\"files\"] = {\"command\": \"npx -y @modelcontextprotocol/server-filesystem /home/user\"}'
echo '    json.dump(reg, open(\"/rw/config/calcium-channel/registry.json\", \"w\"), indent=2)'
echo '  "'
echo ""
echo "For servers that need credentials, add an env_file key and create the file:"
echo '  reg["myserver"] = {"command": "...", "env_file": "/rw/config/calcium-channel/env/myserver.env"}'
echo '  echo "API_KEY=..." > /rw/config/calcium-channel/env/myserver.env'
echo '  chmod 600 /rw/config/calcium-channel/env/myserver.env'
