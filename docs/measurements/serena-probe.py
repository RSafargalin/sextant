"""The same questions through Serena's MCP tools, which is how an agent would have to ask them.

    python3 serena-probe.py <serena binary> <project> [name_path …]

Serena's Swift backend is sourcekit-lsp (`src/solidlsp/language_servers/sourcekit_lsp.py` in its
repository), so what this measures is the wrapper around it: what an agent has to say to get an
answer, how long the answer takes, and how many bytes come back.
"""
import json
import os
import subprocess
import sys
import threading
import time

BINARY = sys.argv[1]
PROJECT = os.path.abspath(sys.argv[2])
QUERIES = sys.argv[3:] or ["Session"]
HERE = os.path.dirname(os.path.abspath(__file__))


class MCP:
    """Just enough of the protocol to call a tool and time the reply."""

    def __init__(self, command):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.next_id = 1
        self.replies = {}
        self.errors = []
        self.lock = threading.Lock()
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._read_errors, daemon=True).start()

    def _read_loop(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if "id" in message:
                with self.lock:
                    self.replies[message["id"]] = message

    def _read_errors(self):
        for line in self.proc.stderr:
            self.errors.append(line.decode(errors="replace"))

    def call(self, method, params, timeout=300):
        with self.lock:
            ident = self.next_id
            self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                                           "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        started = time.time()
        while time.time() - started < timeout:
            with self.lock:
                if ident in self.replies:
                    return self.replies.pop(ident), time.time() - started
            time.sleep(0.02)
        return None, time.time() - started

    def notify(self, method, params):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method,
                                           "params": params}) + "\n").encode())
        self.proc.stdin.flush()


started = time.time()
mcp = MCP([BINARY, "start-mcp-server", "--project", PROJECT, "--context", "ide-assistant",
           "--transport", "stdio", "--enable-web-dashboard", "false"])
reply, seconds = mcp.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "spike", "version": "1"}})
print("initialize: %.1fs" % seconds)
if reply is None:
    print("no reply; stderr tail:", "".join(mcp.errors[-15:])[:1500])
    raise SystemExit(1)
mcp.notify("notifications/initialized", {})

listed, seconds = mcp.call("tools/list", {})
tools = [tool["name"] for tool in listed["result"]["tools"]] if listed else []
print("tools (%d): %s" % (len(tools), ", ".join(tools)))


def call_tool(name, arguments, timeout=300):
    reply, seconds = mcp.call("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
    if reply is None:
        print("\n%s %s -> NO REPLY after %.0fs" % (name, json.dumps(arguments), seconds))
        return None
    content = reply.get("result", {}).get("content", [])
    text = "\n".join(item.get("text", "") for item in content)
    print("\n%s %s  (%.1fs, %d bytes)" % (name, json.dumps(arguments), seconds, len(text)))
    print(text[:800])
    with open(os.path.join(HERE, "serena-last.json"), "w") as handle:
        handle.write(text)
    return text


for query in QUERIES:
    call_tool("find_symbol", {"name_path": query, "relative_path": ".", "include_body": False})
    call_tool("find_referencing_symbols", {"name_path": query, "relative_path": "."})

print("\ntotal %.1fs" % (time.time() - started))
