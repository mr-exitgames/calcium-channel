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
  │  "github": {              │                           │
  │    "command":              │                           │
  │    "qrexec-client-vm",    │                           │
  │    "args": ["mcp-vm",     │                           │
  │     "calciumchannel.      │                           │
  │      Mcp+github"]         │                           │
  │  }                        │                           │
  │                           │                           │
  ├──stdio──► qrexec ──────► policy: work-vm→mcp-vm? ──► calciumchannel.Mcp
  │                           ALLOW                       │
  │                                                       ├─ lookup "github"
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

- **`calciumchannel.McpList`** — Discovery service. Returns which MCP servers the calling VM is allowed to access (parsed from policy).
- **`calciumchannel.McpRegister`** — Registration service. Accepts JSON to add policy rules for a new MCP server. Only callable by the admin VM.
- **Policy file** (`30-calcium-channel.policy`) — Per-server ACL rules.

### MCP server VM

- **`calciumchannel.Mcp`** — Dispatcher qrexec service. Reads `QREXEC_SERVICE_ARGUMENT` (e.g., `github`), looks it up in the registry, and execs the MCP server.
- **`/rw/config/calcium-channel/registry.json`** — Maps server names to commands and optional env files.

### Client VM

- **`client-gen.sh`** — Queries `McpList` and auto-generates `~/.mcp.json` with the correct `qrexec-client-vm` entries.

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
reg['github'] = {
    'command': 'npx -y @modelcontextprotocol/server-github',
    'env_file': '/rw/config/calcium-channel/env/github.env'
}
json.dump(reg, open('/rw/config/calcium-channel/registry.json', 'w'), indent=2)
"

chmod 600 /rw/config/calcium-channel/env/github.env
```

### 3. Register and set ACLs

From the admin VM:

```bash
echo '{"server":"github","mcp_vm":"mcp-vm","allow":["work-vm","dev-vm"]}' \
  | qrexec-client-vm dom0 calciumchannel.McpRegister
```

### 4. Configure client VMs

Run in each client VM:

```bash
./client-gen.sh
```

Or manually add to `~/.mcp.json`:

```json
{
  "mcpServers": {
    "github": {
      "command": "qrexec-client-vm",
      "args": ["mcp-vm", "calciumchannel.Mcp+github"]
    }
  }
}
```

Restart Claude Code to connect.

## File structure

```
calcium-channel/
├── dom0-install.sh                        # dom0 installer
├── dom0-setup/
│   ├── policy.d/
│   │   └── 30-calcium-channel.policy      # ACL policy template
│   └── qubes-rpc/
│       ├── calciumchannel.McpList         # Discovery service
│       └── calciumchannel.McpRegister     # Registration service
├── mcp-vm-install.sh                      # MCP VM installer
├── mcp-vm/
│   ├── qubes-rpc/
│   │   └── calciumchannel.Mcp            # MCP server dispatcher
│   └── registry.json                      # Example registry
└── client-gen.sh                          # Client .mcp.json generator
```

## Related projects

- **[Salt Bridge](https://github.com/mr-exitgames/salt-bridge)** — Privileged cross-VM admin MCP server. Use when you need full system control (debugging, template management, firewall rules). Different trust model — Salt Bridge bypasses isolation, Calcium Channel enforces it.
