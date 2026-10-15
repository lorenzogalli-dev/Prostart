#!/usr/bin/env python3
"""
ble_monitor.py - the app's side of the BLE link (Ble.h), from a Mac.

Connects to "ProStart", prints every event the board sends, and runs the
clock sync the photofinish will use: it pings while the board answers
(READY, countdown, "on your marks"), keeps the minimum of each one-way
difference over the last SYNC_WINDOW_S, and prints the offset. At "go" it
prints the go instant on this computer's clock - the number the phone will
start its timing from.

It exists so the firmware can be checked before the app is: if this works,
the app only has to do the same thing in Dart. The protocol is documented in
Ble.h; keep the two in sync.

Usage:
    python3 Arduino/AlgorithmRealTimeESP32/Python_Tools/ble_monitor.py
Needs: pip install bleak
"""

import asyncio
import struct
import time
from collections import deque

from bleak import BleakClient, BleakScanner

SERVICE = "f7280000-22eb-44d8-be12-ecd2b6bdd709"
EVENT = "f7280001-22eb-44d8-be12-ecd2b6bdd709"
PING = "f7280002-22eb-44d8-be12-ecd2b6bdd709"
PONG = "f7280003-22eb-44d8-be12-ecd2b6bdd709"

PING_EVERY_S = 0.1
PING_TIMEOUT_S = 0.5
SYNC_WINDOW_S = 10.0

EVENT_NAMES = ["READY", "COUNTDOWN", "MARKS", "SET", "GO", "RESULT", "ABORT", "OFF"]
VERDICTS = ["valid start", "FALSE START", "no movement", "UNUSABLE"]


def host_us():
    return time.monotonic_ns() // 1000


class Unwrap32:
    """Board micros() as a 64-bit count. Every stamp it sees is within
    seconds of the previous one, so the shortest signed step is the true one."""

    def __init__(self):
        self.last = None
        self.acc = 0

    def __call__(self, v):
        if self.last is None:
            self.last, self.acc = v, v
            return v
        step = (v - self.last) & 0xFFFFFFFF
        if step >= 1 << 31:
            return self.acc + step - (1 << 32)   # an older stamp: no advance
        self.last = v
        self.acc += step
        return self.acc


class Sync:
    def __init__(self):
        self.unwrap = Unwrap32()
        self.fwd = deque()   # (host_t1, board_rx - host_t1)
        self.back = deque()  # (host_t4, host_t4 - board_tx)
        self.sent = {}       # seq -> host_t1
        self.seq = 0

    def ping_payload(self):
        self.seq = (self.seq + 1) & 0xFFFF
        self.sent[self.seq] = host_us()
        return struct.pack("<H", self.seq)

    def on_reply(self, data):
        t4 = host_us()
        seq, t_rx, t_tx = struct.unpack("<HII", data[:10])
        t1 = self.sent.pop(seq, None)
        if t1 is None:
            return
        rx, tx = self.unwrap(t_rx), self.unwrap(t_tx)
        self.fwd.append((t1, rx - t1))
        self.back.append((t4, t4 - tx))
        cut = t4 - SYNC_WINDOW_S * 1e6
        for q in (self.fwd, self.back):
            while q and q[0][0] < cut:
                q.popleft()

    def estimate(self):
        """(offset host - board in us, round-trip floor in us, pings)."""
        if not self.fwd:
            return None
        a = min(d for _, d in self.fwd)
        b = min(d for _, d in self.back)
        return (b - a) / 2, a + b, len(self.fwd)


async def main():
    print("Scanning for ProStart...")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: d.name == "ProStart" or SERVICE in ad.service_uuids, timeout=15)
    if dev is None:
        print("Not found. Is the board on, and not connected to another device?")
        return
    sync = Sync()
    last = {"offset": None}

    def on_event(_, data: bytearray):
        if len(data) < 2:
            return
        kind = EVENT_NAMES[data[0]] if data[0] < len(EVENT_NAMES) else f"type{data[0]}"
        line = f"[{data[1]:3d}] {kind}"
        if kind == "COUNTDOWN":
            line += f" {data[2]}"
        elif kind in ("MARKS", "SET", "GO"):
            t = sync.unwrap(struct.unpack_from("<I", data, 2)[0])
            line += f" t={t} us"
            if kind == "GO" and last["offset"] is not None:
                line += f"  -> host clock {t + last['offset']:.0f} us"
                line += f" (received {host_us() - (t + last['offset']):.0f} us after)"
        elif kind == "RESULT":
            v, rt, onset, go = struct.unpack_from("<BiII", data, 2)
            line += f" {VERDICTS[v] if v < len(VERDICTS) else v}  {rt / 1000:.1f} ms"
        print(line)

    async with BleakClient(dev) as client:
        print(f"Connected to {dev.address}")
        await client.start_notify(EVENT, on_event)
        await client.start_notify(PONG, lambda _, d: sync.on_reply(d))
        on_event(None, await client.read_gatt_char(EVENT))   # where the board is now
        n = 0
        while client.is_connected:
            await client.write_gatt_char(PING, sync.ping_payload(), response=False)
            await asyncio.sleep(PING_EVERY_S)
            stale = host_us() - PING_TIMEOUT_S * 1e6
            sync.sent = {s: t for s, t in sync.sent.items() if t > stale}
            n += 1
            if n % 20 == 0:
                est = sync.estimate()
                if est:
                    last["offset"] = est[0]
                    print(f"      sync: offset {est[0]:.0f} us, round-trip floor "
                          f"{est[1] / 1000:.1f} ms, {est[2]} pings in {SYNC_WINDOW_S:.0f} s")
                else:
                    print("      sync: no replies (board is judging a start)")
        print("Disconnected")


if __name__ == "__main__":
    asyncio.run(main())
