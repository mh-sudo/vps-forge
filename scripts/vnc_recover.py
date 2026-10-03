#!/usr/bin/env python3
"""Careful VNC console login + sshd fix, stage by stage with captures."""
import sys
import time
from vncdotool import api

sys.path.insert(0, "/tmp/vnc-venv/lib/python3.14/site-packages")  # noqa: E402

HOST = sys.argv[1]
PORT = sys.argv[2]
PASSWORD = sys.argv[3]
ROOTPW = sys.argv[4]
OUT = sys.argv[5]

client = api.connect(f"{HOST}::{PORT}", password=PASSWORD)
client.timeout = 60


def shot(name):
    client.refreshScreen()
    time.sleep(0.4)
    client.captureScreen(f"{OUT}/{name}")
    print(f"captured {name}", flush=True)


def typew(text, delay=0.06):
    for ch in text:
        client.keyDown(ch)
        time.sleep(delay)
        client.keyUp(ch)
        time.sleep(0.03)


# stage 1: wake the console and see where we are
client.keyPress("return")
time.sleep(1.5)
shot("v1-state.png")

# stage 2: username
typew("root")
time.sleep(0.5)
client.keyPress("return")
time.sleep(3.0)
shot("v2-after-user.png")

# stage 3: password (per-char, slow)
typew(ROOTPW, delay=0.08)
time.sleep(0.5)
client.keyPress("return")
time.sleep(4.0)
shot("v3-after-pass.png")

# stage 4: run the fix
cmd = "rm -f /etc/ssh/sshd_config.d/00-vps-forge.conf && systemctl restart ssh && echo SSHD-FIXED-OK"
typew(cmd)
time.sleep(0.5)
client.keyPress("return")
time.sleep(5.0)
shot("v4-after-fix.png")

client.disconnect()
print("done", flush=True)
