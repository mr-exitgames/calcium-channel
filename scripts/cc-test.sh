#!/bin/bash
# cc-test.sh — exercise a Calcium Channel MCP server end-to-end.
# Sends initialize + initialized + tools/list (and optionally tools/call),
# then parses the JSON-RPC responses. Holds stdin open with sleep so the
# server has time to flush before EOF.
#
# Usage:
#   bash cc-test.sh <mcp-vm> <server> [tool [json-args]]
#
# Examples:
#   bash cc-test.sh metatron signal
#   bash cc-test.sh metatron signal list_contacts
#   bash cc-test.sh metatron signal send_message '{"recipient":"+15555550100","message":"hi"}'
#   bash cc-test.sh binary-re ghidra
set -uo pipefail

MCP_VM="${1:?Usage: $0 <mcp-vm> <server> [tool [json-args]]}"
SERVER="${2:?Usage: $0 <mcp-vm> <server> [tool [json-args]]}"
TOOL="${3:-}"
ARGS="${4:-{}}"

SERVICE="calciumchannel.Mcp+$SERVER"

build_input() {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cc-test","version":"1.0"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    if [[ -n "$TOOL" ]]; then
        printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$TOOL" "$ARGS"
    fi
    sleep 3
}

call_newline() {
    build_input | timeout 30 qrexec-client-vm "$MCP_VM" "$SERVICE" 2>&1
}

build_input_lsp() {
    local lsp_script
    lsp_script=$(mktemp)
    cat > "$lsp_script" <<'PYEOF'
import sys, time, os
msgs = [
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cc-test","version":"1.0"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
]
tool = os.environ.get("CC_TOOL", "")
args = os.environ.get("CC_ARGS", "{}")
if tool:
    msgs.append('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + tool + '","arguments":' + args + '}}')
for m in msgs:
    b = m.encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b)
sys.stdout.flush()
time.sleep(3)
PYEOF
    echo "$lsp_script"
}

call_lsp() {
    local script="$1"
    CC_TOOL="$TOOL" CC_ARGS="$ARGS" python3 "$script" 2>/dev/null \
        | timeout 30 qrexec-client-vm "$MCP_VM" "$SERVICE" 2>&1
}

write_parse_script() {
    local f="$1"
    cat > "$f" <<'PYEOF'
import json, re, sys
with open(sys.argv[1], "rb") as fh:
    raw = fh.read().decode("utf-8", errors="replace")

# strip LSP Content-Length headers if any
text = re.sub(r"Content-Length:\s*\d+\r?\n\r?\n", "", raw)

found = []
# JSON objects can span lines; greedy-balance braces, respecting strings.
i, depth, start, in_str, esc = 0, 0, None, False, False
while i < len(text):
    c = text[i]
    if in_str:
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = False
    else:
        if c == '"':
            in_str = True
        elif c == "{":
            if depth == 0: start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and start is not None:
                chunk = text[start:i+1]
                try:
                    found.append(json.loads(chunk))
                except json.JSONDecodeError:
                    pass
                start = None
    i += 1

if not found:
    print("  (no JSON-RPC messages parsed)")
    print("  --- raw first 600 chars ---")
    print(raw[:600])
    sys.exit(2)

for msg in found:
    rid = msg.get("id", "-")
    if "error" in msg:
        print(f"  id={rid}: ERROR {msg['error']}")
    elif "result" in msg:
        r = msg["result"]
        if isinstance(r, dict) and "serverInfo" in r:
            si = r["serverInfo"]
            print(f"  id={rid}: initialized — {si.get('name')} v{si.get('version')}")
        elif isinstance(r, dict) and "tools" in r:
            tools = r["tools"]
            names = ", ".join(t["name"] for t in tools[:8])
            more = f" (+{len(tools)-8} more)" if len(tools) > 8 else ""
            print(f"  id={rid}: {len(tools)} tools — {names}{more}")
        else:
            preview = json.dumps(r)[:200]
            print(f"  id={rid}: {preview}")
PYEOF
}

run_with_wire() {
    local label=$1 fn=$2 arg=${3:-}
    echo "[*] $MCP_VM/$SERVER ($label wire)"
    local out_file
    out_file=$(mktemp)
    if [[ -n "$arg" ]]; then
        $fn "$arg" > "$out_file"
    else
        $fn > "$out_file"
    fi
    if [[ ! -s "$out_file" ]]; then
        rm -f "$out_file"
        echo "  FAIL: no output (qrexec refused, server crashed, or wrong wire format)"
        return 1
    fi
    python3 "$PARSE_SCRIPT" "$out_file"
    local rc=$?
    rm -f "$out_file"
    return $rc
}

PARSE_SCRIPT=$(mktemp)
LSP_INPUT_SCRIPT=$(build_input_lsp)
trap 'rm -f "$PARSE_SCRIPT" "$LSP_INPUT_SCRIPT"' EXIT
write_parse_script "$PARSE_SCRIPT"

run_with_wire "newline-delimited" call_newline
nl_status=$?
if [[ $nl_status -ne 0 ]]; then
    echo
    echo "[*] retrying with LSP Content-Length framing (some servers require it)"
    run_with_wire "LSP-framed" call_lsp "$LSP_INPUT_SCRIPT"
fi

echo
echo "[*] error-path checks (should produce JSON-RPC errors)"
echo "  - unknown server name:"
echo '{}' | timeout 5 qrexec-client-vm "$MCP_VM" "calciumchannel.Mcp+nonesuch_$$" 2>&1 | head -c 300
echo
echo "  - invalid server name (rejected by dispatcher regex):"
echo '{}' | timeout 5 qrexec-client-vm "$MCP_VM" 'calciumchannel.Mcp+../etc' 2>&1 | head -c 300
echo
