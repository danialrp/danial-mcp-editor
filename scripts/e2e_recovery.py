#!/usr/bin/env python3
"""End-to-end check of the phase 1 exit criteria, as a real MCP client.

Starts `dme serve` with a throwaway settings folder, then over HTTP:
creates a project, imports a media file, builds a 2,000-clip timeline in one
batch, makes more edits, kills the server with SIGKILL in the middle of the
work, starts it again, reopens the project and checks that nothing was lost.

usage: scripts/e2e_recovery.py <dme binary> <media file>
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

BIN, MEDIA = sys.argv[1], os.path.abspath(sys.argv[2])
PORT = 19799
home = tempfile.mkdtemp(prefix="dme-e2e-")
env = dict(os.environ, DME_HOME=home)
project = os.path.join(home, "e2e.dmeproj")
next_id = 0


def start():
    p = subprocess.Popen([BIN, "serve", "--port", str(PORT)], env=env, stderr=subprocess.PIPE, text=True)
    p.stderr.readline()  # "MCP over HTTP at ..."
    return p


def token():
    with open(os.path.join(home, "settings.json")) as f:
        return json.load(f)["mcp"]["token"]


def call(name, **args):
    global next_id
    next_id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": next_id, "method": "tools/call",
                       "params": {"name": name, "arguments": args}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp", data=body, headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req) as r:
        res = json.load(r)["result"]
    if res.get("isError"):
        raise SystemExit(f"{name} failed: {res['content'][0]['text']}")
    return res.get("structuredContent", {})


def check(label, ok):
    print(("PASS " if ok else "FAIL ") + label)
    if not ok:
        sys.exit(1)


server = start()
try:
    t0 = time.time()
    p = call("project_create", path=project, preset="reel")
    main = p["tracks"][0]["id"]
    asset = call("media_import", paths=[MEDIA])["added"][0]["id"]
    dur = 1.0
    cmds = [{"name": "clip_add", "args": {"track": main, "asset": asset, "start": i * 1.5,
                                          "sourceStart": (i * 0.02) % 50, "sourceDuration": dur}}
            for i in range(2000)]
    t = time.time()
    r = call("batch_apply", commands=cmds)
    print(f"2,000 clips in one batch over HTTP: {(time.time() - t) * 1000:.0f} ms, revision {r['revision']}")
    for i in range(30):
        call("timeline_split", time=i * 1.5 + 0.5)
    call("timeline_deleteToEdge", time=10.75, side="left")
    call("history_undo")
    before = call("project_get")
    clips_before = call("timeline_get", limit=5000)["clips"]
    print(f"before kill: revision {before['revision']}, {len(clips_before)} clips")
finally:
    server.send_signal(signal.SIGKILL)  # no chance to save
    server.wait()

server = start()
try:
    after = call("project_open", path=project)
    clips_after = call("timeline_get", limit=5000)["clips"]
    check("revision survives a hard kill", after["revision"] == before["revision"])
    check("every clip survives a hard kill", clips_after == clips_before)
    check("redo of the undone step still works", call("history_redo")["revision"] == before["revision"] + 1)
    check("2,000-clip timeline plus edits", len(clips_after) == 2030)
    call("project_close")
    print(f"total {time.time() - t0:.1f} s")
finally:
    server.send_signal(signal.SIGTERM)
    server.wait()
    subprocess.run(["trash", home])
