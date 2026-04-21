#!/usr/bin/env python3
"""
Calcium Channel — MCP stdio framing bridge.

Sits between the qrexec channel and the child MCP server. The MCP stdio spec
uses newline-delimited JSON (NDJSON), but some clients (notably claw-code) use
LSP-style Content-Length framing. This bridge auto-detects the client's framing
on its first message, speaks NDJSON to the child unconditionally, and echoes
responses back in whichever framing the client used.

Usage:  framing-bridge.py -- <command> [args...]

stdin/stdout are the qrexec channel. stderr is inherited.
"""
import os
import re
import subprocess
import sys
import threading


DETECT_BUDGET = 8192
CONTENT_LENGTH_RE = re.compile(rb"(?i)\s*content-length\s*:\s*(\d+)")


def main() -> int:
    if "--" not in sys.argv:
        sys.stderr.write("framing-bridge: missing '--' separator\n")
        return 2
    cmd = sys.argv[sys.argv.index("--") + 1:]
    if not cmd:
        sys.stderr.write("framing-bridge: no command after '--'\n")
        return 2

    child = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=None,
    )

    client_uses_lsp = False
    lsp_lock = threading.Lock()

    def set_lsp():
        nonlocal client_uses_lsp
        with lsp_lock:
            client_uses_lsp = True

    def is_lsp() -> bool:
        with lsp_lock:
            return client_uses_lsp

    def upstream_to_child() -> None:
        """Read from our stdin, forward NDJSON to child."""
        buf = b""
        mode: str | None = None
        try:
            while True:
                chunk = sys.stdin.buffer.read1(65536)
                if not chunk:
                    break
                buf += chunk
                while True:
                    if mode is None:
                        stripped = buf.lstrip()
                        if not stripped:
                            buf = b""
                            break
                        if stripped[:1] == b"{":
                            mode = "ndjson"
                        elif CONTENT_LENGTH_RE.match(stripped):
                            mode = "lsp"
                            set_lsp()
                        else:
                            if len(buf) > DETECT_BUDGET:
                                sys.stderr.write(
                                    "framing-bridge: cannot detect framing "
                                    f"after {DETECT_BUDGET}B\n"
                                )
                                return
                            break

                    if mode == "ndjson":
                        nl = buf.find(b"\n")
                        if nl < 0:
                            break
                        line = buf[:nl].strip()
                        buf = buf[nl + 1:]
                        if line:
                            child.stdin.write(line + b"\n")
                            child.stdin.flush()
                    else:
                        header_end = buf.find(b"\r\n\r\n")
                        sep_len = 4
                        if header_end < 0:
                            header_end = buf.find(b"\n\n")
                            sep_len = 2
                        if header_end < 0:
                            break
                        headers = buf[:header_end]
                        length: int | None = None
                        for h in headers.split(b"\n"):
                            m = CONTENT_LENGTH_RE.match(h)
                            if m:
                                length = int(m.group(1))
                                break
                        if length is None:
                            sys.stderr.write(
                                "framing-bridge: LSP frame missing Content-Length\n"
                            )
                            return
                        body_start = header_end + sep_len
                        if len(buf) - body_start < length:
                            break
                        body = buf[body_start: body_start + length]
                        buf = buf[body_start + length:]
                        child.stdin.write(body + b"\n")
                        child.stdin.flush()
        except Exception as e:
            sys.stderr.write(f"framing-bridge upstream->child: {e}\n")
        finally:
            try:
                child.stdin.close()
            except Exception:
                pass

    def child_to_upstream() -> None:
        """Read NDJSON from child, forward to our stdout in the client's framing."""
        try:
            for line in child.stdout:
                payload = line.rstrip(b"\r\n")
                if not payload:
                    continue
                if is_lsp():
                    hdr = f"Content-Length: {len(payload)}\r\n\r\n".encode()
                    sys.stdout.buffer.write(hdr + payload)
                else:
                    sys.stdout.buffer.write(payload + b"\n")
                sys.stdout.buffer.flush()
        except Exception as e:
            sys.stderr.write(f"framing-bridge child->upstream: {e}\n")

    t_up = threading.Thread(target=upstream_to_child, daemon=True)
    t_down = threading.Thread(target=child_to_upstream, daemon=True)
    t_up.start()
    t_down.start()

    rc = child.wait()
    t_down.join(timeout=1)
    return rc


if __name__ == "__main__":
    sys.exit(main())
