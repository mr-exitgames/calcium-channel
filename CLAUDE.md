# Calcium Channel — Claude Code context

This is Calcium Channel, an MCP-over-qrexec mesh for Qubes OS. It routes MCP server connections between isolated VMs using qrexec, with dom0 policy as the ACL layer.

## Architecture

- MCP's stdio transport maps directly onto qrexec's stdin/stdout. No proxy layer needed.
- The client side is zero-code: `.mcp.json` entries just invoke `qrexec-client-vm <mcp-vm> calciumchannel.Mcp+<name>`.
- The `calciumchannel.Mcp` dispatcher in the MCP VM reads `QREXEC_SERVICE_ARGUMENT`, looks up the server in `/rw/config/calcium-channel/registry.json`, and execs the MCP server process.
- dom0 services (`McpList`, `McpRegister`, `McpRename`) handle discovery and ACL management.
- The `+argument` suffix in qrexec service names (e.g., `calciumchannel.Mcp+github`) enables per-server policy rules.

## Installer separation

- `mcp-vm-install.sh` installs **only** the dispatcher and an empty registry. No Claude, no management server. This is what runs on MCP server VMs.
- `client-gen.sh` installs the management MCP server and generates `.mcp.json`. This is what runs on client VMs (where Claude Code lives).
- If a VM is both a server and a client, run both scripts.

## Key constraints

- Server names are validated with `^[a-zA-Z][a-zA-Z0-9_-]*$`.
- The registry lives in `/rw/config/calcium-channel/` (persistent across AppVM reboots).
- `McpRegister` appends a default deny rule for each server — explicit allow entries must come first in the policy.
- The dom0 installer has a stdin conflict — use the two-step install method (copy to /tmp first).

## Development

- The git remote is `git@git:repos/calcium-channel.git` via SSH over `qubes.ConnectTCP` qrexec.
- This project is intentionally separate from [Salt Bridge](https://github.com/mr-exitgames/salt-bridge). Calcium Channel strengthens Qubes isolation; Salt Bridge bypasses it. Do not merge them.
- When modifying the dispatcher (`mcp-vm/qubes-rpc/calciumchannel.Mcp`), test by calling it directly: `echo '{"jsonrpc":"2.0","method":"initialize",...}' | QREXEC_SERVICE_ARGUMENT=<name> bash calciumchannel.Mcp`.
