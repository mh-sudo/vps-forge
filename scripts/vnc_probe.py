#!/usr/bin/env python3
"""Probe console keyboard handling: type mixed-case text at the login prompt (echoed)."""
import sys
import time
from vncdotool import api

HOST, PORT, PASSWORD, OUT = sys.argv[1:5]
client = api.connect(f"{HOST}::{PORT}", password=PASSWORD)
client.timeout = 60


def shot(name):
    client.refreshScreen()
    time.sleep(0.4)
    client.captureScreen(f"{OUT}/{name}")
    print(f"captured {name}", flush=True)


def typew(text, delay=0.07):
    for ch in text:
        client.keyDown(ch)
        time.sleep(delay)
        client.keyUp(ch)
        time.sleep(0.03)


# wake, clear any partial line, then type a mixed-case probe at the echoed login prompt
client.keyPress("return")
time.sleep(1.5)
client.keyPress("ctrl-u")  # clear line
typew("ProbeX9Yz")
time.sleep(1.0)
shot("k1-echo.png")

# also try vncdotool's own 'type' path via API
client.keyPress("ctrl-u")
time.sleep(0.5)
# api has no type(); emulate via keyPress per char
for ch in "Probe2Q7":
    client.keyPress(ch if ch.islower() or ch.isdigit() else ch)
    time.sleep(0.08)
time.sleep(1.0)
shot("k2-echo.png")

client.disconnect()
print("done", flush=True)
