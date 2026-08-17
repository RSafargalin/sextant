"""Minimal LSP client over stdio: enough to ask sourcekit-lsp the questions an agent asks.

Answers server-initiated requests (progress creation, capability registration) so the server
does not block, and reports how long each answer took, counted from the request.
"""
import json
import os
import subprocess
import sys
import threading
import time


class LSP:
    def __init__(self, command, root, env=None):
        self.root = os.path.abspath(root)
        self.proc = subprocess.Popen(
            command, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env or os.environ.copy())
        self.next_id = 1
        self.replies = {}
        self.notes = []
        self.lock = threading.Lock()
        self.done = threading.Event()
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    # --- wire format -----------------------------------------------------
    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def _read_message(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.decode().strip()
            if line == "":
                break
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        length = int(headers.get("content-length", 0))
        return json.loads(self.proc.stdout.read(length))

    def _read_loop(self):
        while True:
            message = self._read_message()
            if message is None:
                self.done.set()
                return
            if "id" in message and "method" in message:      # server -> client request
                self._send({"jsonrpc": "2.0", "id": message["id"], "result": None})
            elif "id" in message:                            # reply
                with self.lock:
                    self.replies[message["id"]] = message
            else:
                self.notes.append(message)

    def _drain_stderr(self):
        self.stderr = []
        for line in self.proc.stderr:
            self.stderr.append(line.decode(errors="replace"))

    # --- requests --------------------------------------------------------
    def request(self, method, params, timeout=180):
        with self.lock:
            ident = self.next_id
            self.next_id += 1
        started = time.time()
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while time.time() - started < timeout:
            with self.lock:
                if ident in self.replies:
                    return self.replies.pop(ident), time.time() - started
            if self.done.is_set():
                break
            time.sleep(0.01)
        return None, time.time() - started

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    # --- convenience -----------------------------------------------------
    def uri(self, relative):
        return "file://" + os.path.join(self.root, relative)

    def initialize(self):
        reply, seconds = self.request("initialize", {
            "processId": os.getpid(),
            "rootUri": "file://" + self.root,
            "capabilities": {
                "textDocument": {
                    "definition": {"linkSupport": True},
                    "references": {},
                    "callHierarchy": {"dynamicRegistration": False},
                    "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
                },
                "workspace": {"symbol": {}, "workspaceFolders": True},
                "window": {"workDoneProgress": True},
            },
            "workspaceFolders": [{"uri": "file://" + self.root, "name": os.path.basename(self.root)}],
        })
        self.notify("initialized", {})
        return reply, seconds

    def open(self, relative, language):
        path = os.path.join(self.root, relative)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": self.uri(relative), "languageId": language, "version": 1, "text": text}})
        return text

    def change(self, relative, text, version=2):
        """The whole document, the way an editor sends it after a save."""
        self.notify("textDocument/didChange", {
            "textDocument": {"uri": self.uri(relative), "version": version},
            "contentChanges": [{"text": text}],
        })
        self.notify("textDocument/didSave", {"textDocument": {"uri": self.uri(relative)}, "text": text})

    def close(self):
        self.request("shutdown", {}, timeout=10)
        self.notify("exit", {})
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def position_of(text, needle, occurrence=0):
    """Line/character of the needle, zero-based, as LSP counts them."""
    index = -1
    for _ in range(occurrence + 1):
        index = text.index(needle, index + 1)
    line = text.count("\n", 0, index)
    character = index - (text.rfind("\n", 0, index) + 1)
    return {"line": line, "character": character}


def show(label, reply, seconds, limit=6):
    print("\n== %s  (%.2fs)" % (label, seconds))
    if reply is None:
        print("   TIMEOUT / no reply")
        return
    if "error" in reply:
        print("   error:", json.dumps(reply["error"])[:300])
        return
    result = reply.get("result")
    if result in (None, [], {}):
        print("   empty:", json.dumps(result))
        return
    items = result if isinstance(result, list) else [result]
    for item in items[:limit]:
        print("   " + json.dumps(item)[:400])
    if len(items) > limit:
        print("   … %d more" % (len(items) - limit))
