#!/usr/bin/env python3
"""One more careful console login attempt, with tight captures around each step."""
import sys
import time
from vncdotool import api

HOST, PORT, PASSWORD, ROOTPW, OUT = sys.argv[1:6]
client = api.connect(f"{HOST}::{PORT}", password=PASSWORD)
client.timeout = 60


def shot(name):
    client.refreshScreen()
    time.sleep(0.5)
    client.captureScreen(f"{OUT}/{name}")
    print(f"captured {name}", flush=True)


def typew(text, delay=0.12):
    for ch in text:
        client.keyDown(ch)
        time.sleep(delay)
        client.keyUp(ch)
        time.sleep(0.06)


# settle: whatever state the console is in, send a couple of returns and wait long
client.keyPress("return")
time.sleep(4)
client.keyPress("return")
time.sleep(4)
shot("m0.png")

# type username very deliberately
typew("root", delay=0.15)
time.sleep(1)
client.keyPress("return")
time.sleep(5)  # let Password: fully draw
shot("m1.png")

# type password very slowly, then capture BEFORE pressing return (prompt stays)
typew(ROOTPW, delay=0.15)
time.sleep(1)
shot("m2.png")  # password invisible; this confirms no stray echoes/lines appeared

client.keyPress("return")
time.sleep(6)
shot("m3.png")  # shell or Login incorrect

client.disconnect()
print("done", flush=True)
