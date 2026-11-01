#!/usr/bin/env python3
"""A stand-in for the caddy binary, named by the suite's config.

Every call is recorded in $FAKE_CADDY_STATE/calls.jsonl as {"argv", "env"},
so the suite can tell what reached the argument vector and what reached the
environment. What validate and reload do is queued by the suite, one line per
call, in the files "validate" and "reload" of the same directory:

    validate: "fail <message>" fails with "Error: <message>"; "hang" starts a
              child (its pid and the fake's in "hung.pids") and both sleep a
              minute; anything else passes.
    reload:   "fail <message>" fails the same way; a JSON object is an effect
              applied to the world after the reload: {"down": [hosts]} stops
              answering for those hosts, {"status": {host: code}} changes their
              status, {"alive": false} stops the whole server, {"sleep": s}
              waits s seconds first.

A reload with no effect queued makes the world serve every https site of the
Caddyfile it was given: the hosts of the blocks whose address line starts at
the first column. world.py reads world.json, which a reload rewrites.
"""

import json
import os
import re
import subprocess
import sys
import time

STATE = os.environ["FAKE_CADDY_STATE"]
_SITE = re.compile(r"^(?!\(|\{|:|\*|#|http://)(\S[^{]*?)\s*\{\s*$")


def pop(name):
    path = os.path.join(STATE, name)
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return ""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(line + "\n" for line in lines[1:]))
    return lines[0] if lines else ""


def hosts(path):
    found = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            match = _SITE.match(line)
            if not match:
                continue
            for address in match.group(1).split(","):
                address = address.strip()
                if address.startswith("https://"):
                    address = address[len("https://"):]
                if address and "*" not in address:
                    found.append(address)
    return found


def fail(step):
    print('{"level":"info","msg":"using config from file"}', file=sys.stderr)
    print("Error: " + step[len("fail "):], file=sys.stderr)
    sys.exit(1)


def main(argv):
    with open(os.path.join(STATE, "calls.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"argv": argv, "env": dict(os.environ)}) + "\n")
    command = argv[0] if argv else ""
    if command == "version":
        print("v2.8.4 h1:fake")
        return 0
    config = argv[argv.index("--config") + 1]
    if command == "validate":
        step = pop("validate")
        if step.startswith("fail "):
            fail(step)
        if step == "hang":
            child = subprocess.Popen(["sleep", "60"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with open(os.path.join(STATE, "hung.pids"), "w", encoding="utf-8") as fh:
                fh.write("%d %d\n" % (os.getpid(), child.pid))
            time.sleep(60)
        print("Valid configuration")
        return 0
    if command == "reload":
        step = pop("reload")
        if step.startswith("fail "):
            fail(step)
        effect = json.loads(step) if step else {}
        time.sleep(effect.get("sleep", 0))
        world_path = os.path.join(STATE, "world.json")
        with open(world_path, encoding="utf-8") as fh:
            before = json.load(fh)
        world = {"alive": True, "sites": {h: before["sites"].get(h, 200) for h in hosts(config)}}
        if step:
            world["alive"] = effect.get("alive", True)
            for host in effect.get("down", []):
                world["sites"].pop(host, None)
            world["sites"].update(effect.get("status", {}))
        with open(world_path, "w", encoding="utf-8") as fh:
            json.dump(world, fh)
        return 0
    print("Error: unknown command " + command, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
