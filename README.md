# Calcium Channel

A least-privilege MCP-over-qrexec mesh for Qubes OS. Allows Claude Code instances in different VMs to access MCP servers running in isolated VMs, with dom0 qrexec policy as the ACL layer.

Unlike [Salt Bridge](https://github.com/mr-exitgames/salt-bridge) (which grants broad cross-VM control), Calcium Channel *strengthens* Qubes isolation by providing structured, policy-controlled access to specific tools without exposing shells, filesystems, or secrets.

## How it works

MCP's stdio transport (JSON-RPC over stdin/stdout) maps directly onto qrexec's stdin/stdout piping. No proxy daemon, no protocol translation, no new code on the client side.

```
work-vm                     dom0                        mcp-vm
───────                     ────                        ──────
Claude Code                 policy check                MCP server
  │                           │                           │
  │ .mcp.json:                │                           │
  │  "files": {               │                           │
  │    "command":              │                           │
  │    "qrexec-client-vm",    │                           │
  │    "args": ["mcp-vm",     │                           │
  │     "calciumchannel.      │                           │
  │      Mcp+files"]          │                           │
  │  }                        │                           │
  │                           │                           │
  ├──stdio──► qrexec ──────► policy: work-vm→mcp-vm? ──► calciumchannel.Mcp
  │                           ALLOW                       │
  │                                                       ├─ lookup "files"
  │                                                       │  in registry.json
  │                                                       │
  │◄──────────────── stdio piped ────────────────────────►│ exec mcp server
```

The client VM's `.mcp.json` points `qrexec-client-vm` at the MCP server VM. dom0 checks the qrexec policy. The dispatcher in the MCP VM looks up the server name in a registry and execs it. MCP JSON-RPC flows over the qrexec channel. Zero new daemons.

## Security model

- **MCP servers are jailed** in their own VM with their own secrets (API tokens, credentials). Client VMs never see them.
- **dom0 qrexec policy is the ACL.** Per-server, per-client rules. A VM can only access the MCP servers explicitly allowed by policy.
- **No network paths are opened.** All communication is qrexec (dom0-mediated IPC), not TCP/IP.
- **Each connection spawns a fresh MCP server instance.** No shared state between sessions.

## Components

### dom0

- **`calciumchannel.McpList`** — Discovery service. Returns which MCP servers the calling VM is allowed to access (parsed from policy). Each VM only sees its own authorized servers. Includes `alias` field if set.
- **`calciumchannel.McpRegister`** — Registration service. Accepts JSON to add policy rules for a new MCP server. Accepts optional `alias` field. Only callable by the admin VM.
- **`calciumchannel.McpRename`** — Alias update service. Sets or clears the display alias for a server without touching ACL rules. Only callable by the admin VM.
- **Policy file** (`30-calcium-channel.policy`) — Per-server ACL rules.
- **Metadata file** (`30-calcium-channel-meta.json`) — Per-server aliases and other metadata, stored alongside the policy.

### MCP server VM

- **`calciumchannel.Mcp`** — Dispatcher qrexec service. Reads `QREXEC_SERVICE_ARGUMENT` (e.g., `files`), looks it up in the registry, and execs the MCP server.
- **`/rw/config/calcium-channel/registry.json`** — Maps server names to commands and optional env files.

### Client VM

- **`client-gen.sh`** — Installs the management MCP server, queries `McpList`, and auto-generates `~/.mcp.json` with the correct `qrexec-client-vm` entries.
- **`calcium-channel-mgmt.py`** — Management MCP server. Exposes `list_servers`, `register_server`, and `refresh_mcps` as MCP tools so agentic workflows can discover and manage servers without dropping to a shell. Installed to `/rw/config/calcium-channel/calcium-channel-mgmt.py` by `client-gen.sh`.

## Installation

### 1. Install in dom0

```bash
qvm-run -p <source-vm> 'cat /home/user/calcium-channel/dom0-install.sh' > /tmp/cc-install.sh
bash /tmp/cc-install.sh <source-vm> [admin-vm]
```

### 2. Set up MCP server VM

Copy and run the installer in the VM that will host MCP servers:

```bash
# From dom0, or via qvm-copy:
qvm-run -p <source-vm> 'cat /home/user/calcium-channel/mcp-vm-install.sh' | qvm-run -p <mcp-vm> 'bash -s'
```

Add servers to the registry:

```bash
# In the MCP VM:
python3 -c "
import json
reg = json.load(open('/rw/config/calcium-channel/registry.json'))
reg['files'] = {
    'command': 'npx -y @modelcontextprotocol/server-filesystem /home/user'
}
json.dump(reg, open('/rw/config/calcium-channel/registry.json', 'w'), indent=2)
"
```

For servers that need credentials, add an env file:

```bash
reg['myserver'] = {
    'command': 'npx -y @example/mcp-server',
    'env_file': '/rw/config/calcium-channel/env/myserver.env'
}
# then:
echo "API_KEY=..." > /rw/config/calcium-channel/env/myserver.env
chmod 600 /rw/config/calcium-channel/env/myserver.env
```

### 3. Register and set ACLs

From the admin VM:

```bash
echo '{"server":"files","mcp_vm":"mcp-vm","allow":["work-vm","dev-vm"]}' \
  | qrexec-client-vm dom0 calciumchannel.McpRegister
```

Or via the management MCP server (if Claude Code is running in the admin VM):

Use the `register_server` tool with `server="files"`, `mcp_vm="mcp-vm"`, `allow=["work-vm","dev-vm"]`.

To set a display alias after registration (changes the tool namespace prefix in Claude Code):

```bash
echo '{"server":"signal","alias":"metatron"}' \
  | qrexec-client-vm dom0 calciumchannel.McpRename
```

Or via the management MCP server: use the `rename_server` tool with `server="signal"`, `alias="metatron"`. Then call `refresh_mcps` to apply.

### 4. Configure client VMs

Run in each client VM:

```bash
./client-gen.sh
```

Or manually add to `~/.mcp.json`:

```json
{
  "mcpServers": {
    "files": {
      "command": "qrexec-client-vm",
      "args": ["mcp-vm", "calciumchannel.Mcp+files"]
    },
    "calcium-channel": {
      "command": "python3",
      "args": ["/rw/config/calcium-channel/calcium-channel-mgmt.py"]
    }
  }
}
```

Restart Claude Code to connect.

## Management MCP server

`client-gen.sh` installs a local MCP server (`calcium-channel-mgmt.py`) that exposes Calcium Channel management as tools, enabling agentic workflows without dropping to a shell.

| Tool | Description | Authorization |
|------|-------------|---------------|
| `list_servers` | List MCP servers this VM can access | Any VM |
| `register_server` | Register a server and set ACLs. Accepts optional `alias`. | Admin VM only (dom0 enforces) |
| `rename_server` | Set or clear the display alias for a server | Admin VM only (dom0 enforces) |
| `refresh_mcps` | Re-sync `~/.mcp.json` and prune stale entries | Any VM |

Because dom0 policy enforces `McpRegister` access, `register_server` simply fails for non-admin VMs — no special logic needed in the script. The same server can be deployed identically on both client VMs (read-only use) and the admin VM (full management).

`refresh_mcps` is useful after an admin grants or revokes access: call the tool, then restart Claude Code to pick up the updated config.

## File structure

```
calcium-channel/
├── dom0-install.sh                        # dom0 installer
├── dom0-setup/
│   ├── policy.d/
│   │   └── 30-calcium-channel.policy      # ACL policy template
│   └── qubes-rpc/
│       ├── calciumchannel.McpList         # Discovery service (returns alias if set)
│       ├── calciumchannel.McpRegister     # Registration service (accepts optional alias)
│       └── calciumchannel.McpRename       # Alias update service (admin only)
├── mcp-vm-install.sh                      # MCP VM installer
├── mcp-vm/
│   ├── qubes-rpc/
│   │   └── calciumchannel.Mcp            # MCP server dispatcher
│   └── registry.json                      # Example registry
├── calcium-channel-mgmt.py               # Management MCP server (source)
└── client-gen.sh                          # Client setup: installs mgmt server + syncs .mcp.json
```

## Related projects

- **[Salt Bridge](https://github.com/mr-exitgames/salt-bridge)** — Privileged cross-VM admin MCP server. Use when you need full system control (debugging, template management, firewall rules). Different trust model — Salt Bridge bypasses isolation, Calcium Channel enforces it.
