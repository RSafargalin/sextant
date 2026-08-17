"""Who is right after an edit that has not been built.

    python3 staleness-probe.py <project> <sextant binary> <index store>

The project must be a SwiftPM package with Source/Core/Session.swift — it is written against the
Alamofire checkout the other measurements use. The file is restored on the way out, including
after a failure.

The agent edits a file and asks immediately. sextant reads the index the last build wrote, so it
answers about the code as it was compiled and marks the answer stale. sourcekit-lsp keeps its own
index and re-prepares what it has open. This measures both: whether each finds a symbol that was
just added, what happens to the count of an existing one, and how long it takes.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader

_client = SourceFileLoader(
    "lsp_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lsp-client.py")).load_module()
LSP, position_of = _client.LSP, _client.position_of

PROJECT = os.path.abspath(sys.argv[1])
SEXTANT = sys.argv[2]
STORE = sys.argv[3]                              # pin sextant to the BUILD's store, not the editor's
FILE = "Source/Core/Session.swift"
NEW_SYMBOL = "spikeProbeUsingSession"
ADDITION = "\n\n/// Added by the staleness spike; never built.\npublic func %s(_ session: Session) -> Session { session }\n" % NEW_SYMBOL
sourcekit = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True,
                           text=True).stdout.strip()
path = os.path.join(PROJECT, FILE)
original = open(path, encoding="utf-8").read()


def sextant(*arguments):
    started = time.time()
    result = subprocess.run([SEXTANT] + list(arguments) + ["--project", PROJECT, "--index-store", STORE],
                            capture_output=True, text=True)
    return result.stdout + result.stderr, time.time() - started


def report(label, text, seconds):
    lines = [line for line in text.split("\n") if line.strip()]
    banner = [line for line in lines if "[index:" in line or "not found" in line.lower()]
    head = banner + [line for line in lines if line not in banner][:5]
    print("\n  %s  (%.2fs)" % (label, seconds))
    for line in head:
        print("     " + line[:150])


def lsp_references(lsp, at):
    reply, seconds = lsp.request("textDocument/references",
                                 {"textDocument": {"uri": lsp.uri(FILE)}, "position": at,
                                  "context": {"includeDeclaration": False}}, timeout=45)
    return (reply.get("result") or [] if reply else []), seconds


try:
    print("=" * 78)
    print("BEFORE THE EDIT")
    lsp = LSP([sourcekit], PROJECT)
    lsp.initialize()
    text = lsp.open(FILE, "swift")
    at_session = position_of(text, "Session: @unchecked")

    started = time.time()
    while time.time() - started < 900:
        found, _ = lsp_references(lsp, at_session)
        if found:
            break
        time.sleep(5)
    print("  sourcekit-lsp indexed after %.1fs" % (time.time() - started))

    found, seconds = lsp_references(lsp, at_session)
    print("  sourcekit-lsp: references of Session = %d  (%.2fs)" % (len(found), seconds))
    out, seconds = sextant("refs", "Session")
    report("sextant refs Session", out, seconds)

    # The edit: a new symbol, and two more usages of an existing one. Written to disk AND sent to
    # the server, which is what an editor does on save.
    print("\n" + "=" * 78)
    print("EDIT: a new function is appended to %s (no build)" % FILE)
    edited = original + ADDITION
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(edited)
    lsp.change(FILE, edited)
    time.sleep(2)

    print("\nAFTER THE EDIT, IMMEDIATELY")
    found, seconds = lsp_references(lsp, at_session)
    print("  sourcekit-lsp: references of Session = %d  (%.2fs)" % (len(found), seconds))
    at_new = position_of(edited, NEW_SYMBOL, 0)          # the declaration
    reply, seconds = lsp.request("textDocument/definition",
                                 {"textDocument": {"uri": lsp.uri(FILE)}, "position": at_new}, timeout=45)
    print("  sourcekit-lsp: definition of the new symbol -> %s  (%.2fs)"
          % ("found" if (reply and reply.get("result")) else "empty", seconds))
    reply, seconds = lsp.request("workspace/symbol", {"query": NEW_SYMBOL}, timeout=45)
    print("  sourcekit-lsp: workspace/symbol '%s' -> %d  (%.2fs)"
          % (NEW_SYMBOL, len(reply.get("result") or []) if reply else 0, seconds))

    out, seconds = sextant("refs", "Session")
    report("sextant refs Session", out, seconds)
    out, seconds = sextant("refs", NEW_SYMBOL)
    report("sextant refs %s" % NEW_SYMBOL, out, seconds)

    # How long the editor takes to see the new symbol without any build.
    print("\nWAITING for sourcekit-lsp to pick the new symbol up (no build is run)")
    started = time.time()
    seen = None
    while time.time() - started < 300:
        reply, _ = lsp.request("workspace/symbol", {"query": NEW_SYMBOL}, timeout=30)
        if reply and reply.get("result"):
            seen = time.time() - started
            break
        time.sleep(5)
    print("  workspace/symbol found it after %s" % ("%.1fs" % seen if seen else "NEVER (300s)"))

    found, _ = lsp_references(lsp, at_session)
    print("  sourcekit-lsp: references of Session, at the end = %d" % len(found))
    lsp.close()
finally:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(original)
    print("\n(file restored)")
