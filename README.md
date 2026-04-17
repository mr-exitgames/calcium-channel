# Calcium Channel

> **⚠️ Experimental** — This project is under active development and has not been formally audited. Do not rely on it for security-sensitive systems. Use at your own risk.

**MCP servers on isolated Qubes VMs.**

Calcium Channel lets you host [MCP](https://modelcontextprotocol.io/) servers in dedicated Qubes OS VMs and access them from any client VM, using only qrexec and dom0 policy. The server VMs never run Claude, never see your prompts, and never touch each other. dom0 policy controls exactly which client can reach which server — per-server, per-VM.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        How it works                                 │
│                                                                     │
│   client-vm            dom0                 mcp-vm                  │
│  ┌───────────┐     ┌────────────┐      ┌──────────────┐             │
│  │Claude Code│     │ qrexec     │      │  dispatcher  │             │
│  │           │────>│ policy     │─────>│  (bash)      │             │
│  │.mcp.json  │     │ check      │      │      │       │             │
│  │points to  │     │            │      │      ▼       │             │
│  │qrexec-    │     │ allow/deny │      │  MCP server  │             │
│  │client-vm  │<────│            │<─────│  (stdio)     │             │
│  └───────────┘     └────────────┘      └──────────────┘             │
│       ▲                                      ▲                      │
│       │           JSON-RPC over              │                      │
│       └──────────  qrexec stdin/stdout ──────┘                      │
│                                                                     │
│   Runs Claude          No code             MCP servers              │
│   + management         Just policy.        + their privileges       │
│   MCP server.                              + their secrets          │
└─────────────────────────────────────────────────────────────────────┘
```

## Why

MCP servers often need secrets (API tokens, credentials) and broad tool access. Running them in the same VM as your AI agent means the agent can access those secrets and every other tool on the machine.

Calcium Channel enforces least-privilege by splitting the roles:

- **MCP server VMs** hold secrets and run servers. They have no AI agent, no Claude, no network access to the client.
- **Client VMs** run Claude Code (or any MCP client). They connect to servers through qrexec — dom0-mediated IPC, not TCP/IP.
- **dom0 policy** is the only ACL. Per-server, per-client rules. Nothing is allowed unless explicitly granted.

MCP's stdio transport (JSON-RPC over stdin/stdout) maps directly onto qrexec's stdin/stdout piping. No proxy daemon, no protocol translation — just `exec` the server and pipe.

## Security model

- **MCP servers are jailed** in their own VM with their own secrets. Client VMs never see them.
- **dom0 qrexec policy is the ACL.** Per-server, per-client rules. A VM can only access the MCP servers explicitly allowed by policy.
- **No network paths are opened.** All communication is qrexec (dom0-mediated IPC), not TCP/IP.
- **Each connection spawns a fresh MCP server instance.** No shared state between sessions.

## Quick start

### 1. Install dom0 services

In dom0 (two-step — piping directly causes stdin conflicts):

```bash
qvm-run -p SOURCE_VM 'cat /path/to/calcium-channel/dom0-install.sh' > /tmp/cc-install.sh
bash /tmp/cc-install.sh SOURCE_VM [ADMIN_VM]
```

|  Argument   | Description |
|-------------|-------------|
| `SOURCE_VM` | VM containing the calcium-channel repo (files are copied from here)
| `ADMIN_VM`  | VM that can register servers and manage ACLs (defaults to `SOURCE_VM`). Only omit this if `SOURCE_VM` is already a dedicated, isolated qube for Calcium Channel administration. **The admin VM should be an isolated qube** — avoid reusing a general-purpose development VM.

### 2. Set up an MCP server VM

Run in dom0:

```bash
qvm-run -p SOURCE_VM 'cat /path/to/calcium-channel/mcp-vm-install.sh' \
  | qvm-run -p MCP_VM 'bash -s'
```

This installs only the dispatcher and an empty registry.

Then add servers to the registry inside the MCP VM:

```bash
python3 -c "
import json
reg = json.load(open('/rw/config/calcium-channel/registry.json'))
reg['files'] = {'command': 'npx -y @modelcontextprotocol/server-filesystem /home/user'}
json.dump(reg, open('/rw/config/calcium-channel/registry.json', 'w'), indent=2)
"
```

### 3. Register servers and set ACLs

From the admin VM, tell dom0 which clients can access which servers:

```bash
echo '{"server":"files","mcp_vm":"mcp-vm","allow":["work-vm","dev-vm"]}' \
  | qrexec-client-vm dom0 calciumchannel.McpRegister
```

Or use the management MCP server (if Claude Code is running in the admin VM):

> Use the `register_server` tool with `server="files"`, `mcp_vm="mcp-vm"`, `allow=["work-vm","dev-vm"]`.

### 4. Configure client VMs

Run `client-install.sh` in each VM where Claude Code (or any MCP client) will connect:

```bash
./client-install.sh
```

This installs a lightweight management MCP server and writes the correct `qrexec-client-vm` entries into every detected client config:

- `~/.mcp.json` — always written (Claude Code's project convention).
- `~/.claw/settings.json` — if `~/.claw/` exists.
- `~/.gemini/settings.json` — if `~/.gemini/` exists (gemini-cli).
- `~/.qwen/settings.json` — if `~/.qwen/` exists (qwen-code).

Other keys in those settings files are preserved; only `mcpServers` is touched. Pass an explicit path (`./client-install.sh /path/to/config.json`) to write a single file instead. Restart the affected client to connect.

Or add entries manually:

```json
{
  "mcpServers": {
    "files": {
      "command": "qrexec-client-vm",
      "args": ["mcp-vm", "calciumchannel.Mcp+files"]
    }
  }
}
```

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ dom0 (policy + services)                                                 │
│                                                                          │
│  /etc/qubes/policy.d/30-calcium-channel.policy                           │
│  ┌────────────────────────────────────────────────────────────────┐      │
│  │ calciumchannel.Mcp +files   work-vm   mcp-vm   allow           │      │
│  │ calciumchannel.Mcp +files   @anyvm    @anyvm   deny            │      │
│  │ calciumchannel.Mcp +github  dev-vm    mcp-vm   allow           │      │
│  │ calciumchannel.Mcp +github  @anyvm    @anyvm   deny            │      │
│  └────────────────────────────────────────────────────────────────┘      │
│                                                                          │
│  Services:                                                               │
│    McpList       — returns which servers a VM can access                 │
│    McpListAll    — dumps the full ACL matrix (admin only)                │
│    McpRegister   — adds/updates per-server policy rules (admin only)     │
│    McpRename     — sets display aliases (admin only)                     │
│    McpUnregister — removes rules or whole channels (admin only)          │
└──────────────────────────────────────────────────────────────────────────┘
        │                                       │
        │ qrexec                                │ qrexec
        ▼                                       ▼
┌────────────────────┐               ┌──────────────────────┐
│ client-vm          │               │ mcp-vm               │
│                    │               │                      │
│ .mcp.json:         │   qrexec +    │ calciumchannel.Mcp   │
│  "files" ──────────│──  stdio  ───>│  ├─ registry.json    │
│    qrexec-client-vm│               │  │  "files" ->       │
│    mcp-vm          │<── stdio  ────│  │   npx server-fs   │
│    calciumchannel. │               │  └─ exec command     │
│     Mcp+files      │               │                      │
│                    │               │                      │
│ Claude Code        │               │  MCP Server +        │
│ + mgmt MCP server  │               │  secrets/privileges  │
│   (optional)       │               │                      │
└────────────────────┘               └──────────────────────┘
```

### Components

#### dom0

- **`calciumchannel.McpList`** — Discovery service. Returns which MCP servers the calling VM is allowed to access. Each VM only sees its own authorized servers.
- **`calciumchannel.McpListAll`** — Admin discovery service. Returns every registered server with its full ACL matrix (all source VMs + actions). Only callable by the admin VM.
- **`calciumchannel.McpRegister`** — Registration service. Adds per-server policy rules. Only callable by the admin VM.
- **`calciumchannel.McpRename`** — Alias service. Sets or clears display aliases without touching ACL rules. Only callable by the admin VM.
- **`calciumchannel.McpUnregister`** — Removal service. Drops a whole channel (all rules + alias) or revokes a single source VM's access. Only callable by the admin VM.
- **Policy file** (`30-calcium-channel.policy`) — Per-server ACL rules with `+argument` suffix for granular control.
- **Metadata file** (`30-calcium-channel-meta.json`) — Display aliases, stored alongside the policy.

#### MCP server VM

- **`calciumchannel.Mcp`** — Dispatcher. Reads `QREXEC_SERVICE_ARGUMENT`, looks up the server name in the registry, and execs it. A plain bash script — no dependencies beyond Python 3 (for JSON parsing).
- **`registry.json`** — Maps server names to commands. Lives in `/rw/config/calcium-channel/` (persistent across AppVM reboots).

#### Client VM

- **`client-install.sh`** — Installs the management MCP server, queries `McpList`, and syncs each detected client config (`~/.mcp.json` plus `~/.claw/settings.json`, `~/.gemini/settings.json`, `~/.qwen/settings.json` when those dirs exist).
- **`calcium-channel-mgmt.py`** — Management MCP server (optional). Exposes Calcium Channel management as MCP tools for agentic workflows.

## Management MCP server

`client-install.sh` installs a local management MCP server that exposes Calcium Channel operations as tools. This is optional — you can manage everything via the shell commands above.

| Tool              | Description                                                    | Authorization                   |
|-------------------|----------------------------------------------------------------|---------------------------------|
| `list_servers`      | List MCP servers this VM can access                          | Any VM                          |
| `list_all_servers`  | Dump every registered server with its full ACL matrix        | Admin VM only (dom0 enforces)   |
| `register_server`   | Register a server and set ACLs                               | Admin VM only (dom0 enforces)   |
| `rename_server`     | Set or clear a display alias                                 | Admin VM only (dom0 enforces)   |
| `unregister_server` | Remove a whole channel, or revoke one source VM's access     | Admin VM only (dom0 enforces)   |
| `refresh_mcps`      | Re-sync every detected client config (or one path if passed) | Any VM                          |

dom0 policy enforces `McpRegister`/`McpRename` access, so `register_server` and `rename_server` simply fail for non-admin VMs. The same management server works identically in both client VMs (read-only) and the admin VM (full management).

**Aliases**: You can set a display alias for any server (e.g., `rename_server("signal", "metatron")`). The alias becomes the key in `.mcp.json` and the tool namespace prefix in Claude Code. Call `refresh_mcps` after renaming, then restart Claude Code.

## Admin CLI (`cc-admin`)

`cc-admin` is a stdlib-only Python wrapper around the dom0 qrexec services, for manual administration without an AI agent. Run it from the admin VM — the same dom0 policy that gates the management MCP server gates this CLI.

| Subcommand                                           | Description                                             |
|------------------------------------------------------|---------------------------------------------------------|
| `list [--json]`                                      | Servers this VM can access.                             |
| `list-all [--json]`                                  | Full ACL matrix. Admin only.                            |
| `register SERVER MCP_VM VM [VM ...] [--alias ALIAS]` | Replace the ACL for `SERVER` with the given VMs.        |
| `grant SERVER SOURCE_VM`                             | Add one VM to `SERVER`'s existing allow list.           |
| `revoke SERVER SOURCE_VM`                            | Remove one allow rule.                                  |
| `unregister SERVER`                                  | Drop every rule (and alias) for `SERVER`.               |
| `rename SERVER [ALIAS]`                              | Set the display alias. Omit `ALIAS` to clear it.        |

### Worked example

Suppose `vault-vm` is an MCP server VM that exposes two MCP services (`notes` and `calendar`), and you want to grant `work-vm` access to both, then later add `research-vm` to just `notes`.

**1. On `vault-vm`** — write the registry at `/rw/config/calcium-channel/registry.json` (one-time):

```json
{
  "notes": {
    "command": "npx -y some-notes-mcp"
  },
  "calendar": {
    "command": "npx -y some-calendar-mcp"
  }
}
```

Each top-level key is the service name; `command` is the shell command the dispatcher will `exec` when a client connects.

**2. From the admin VM** — register ACLs. The positional args are `SERVER MCP_VM CLIENT_VM [CLIENT_VM ...]`: the service name (must match the registry key on the MCP VM), the VM hosting it, and one-or-more client VMs (where Claude Code or another MCP client runs) to grant access:

```bash
#                   server   mcp-vm   client-vm(s)
./cc-admin register notes    vault-vm work-vm
./cc-admin register calendar vault-vm work-vm
```

**3. Inspect:**

```bash
./cc-admin list-all
# notes -> vault-vm
#     allow work-vm -> vault-vm
#     deny  @anyvm  -> @anyvm
# calendar -> vault-vm
#     allow work-vm -> vault-vm
#     deny  @anyvm  -> @anyvm
```

**4. Add a second client to one service** — `grant` preserves the existing allow list (and alias):

```bash
./cc-admin grant notes research-vm
```

**5. Set a display alias, then revoke or remove:**

```bash
./cc-admin rename notes scratchpad        # alias becomes the key in .mcp.json
./cc-admin revoke notes research-vm       # remove just research-vm's access
./cc-admin unregister calendar            # drop the whole channel
```

**6. On each client VM** — sync `.mcp.json` and restart the MCP client:

```bash
./client-install.sh
```

## File structure

```
calcium-channel/
├── dom0-install.sh                        # dom0 installer (two-step)
├── dom0-setup/
│   ├── policy.d/
│   │   └── 30-calcium-channel.policy      # ACL policy template
│   └── qubes-rpc/
│       ├── calciumchannel.McpList         # Discovery service
│       ├── calciumchannel.McpListAll      # Admin discovery (full ACL matrix)
│       ├── calciumchannel.McpRegister     # Registration service (admin only)
│       ├── calciumchannel.McpRename       # Alias service (admin only)
│       └── calciumchannel.McpUnregister   # Removal service (admin only)
├── mcp-vm-install.sh                      # MCP VM installer (dispatcher only)
├── mcp-vm/
│   ├── qubes-rpc/
│   │   └── calciumchannel.Mcp             # MCP server dispatcher
│   └── registry.json                      # Example registry
├── calcium-channel-mgmt.py                # Management MCP server (source)
├── cc-admin                               # Admin CLI (run from admin VM)
└── client-install.sh                      # Client setup: mgmt server + .mcp.json sync
```

## Updating

After making changes to the repo:

- **dom0 services or policy** — re-run the two-step dom0 installer
- **MCP VM dispatcher** — re-run `mcp-vm-install.sh` in the target VM
- **Client config** — re-run `client-install.sh` in client VMs, then restart Claude Code

## Credits

Built by [Claude](https://claude.ai) with help from [@mr-exitgames](https://github.com/mr-exitgames).

## License

MIT
