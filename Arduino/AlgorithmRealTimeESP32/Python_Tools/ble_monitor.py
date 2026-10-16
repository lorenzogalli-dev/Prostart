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

v6 (2026-10-16): it also receives each run's recording the way the app
does (data/ctrl in Ble.h): RUN_INFO, the samples, RUN_END; GETs whatever is
missing, ACKs, and writes the run as capture.py's CSV into --outdir.

Usage:
    python3 Arduino/AlgorithmRealTimeESP32/Python_Tools/ble_monitor.py [--outdir DIR]
        [--start-serial PORT] [--runs N]
    --start-serial sends 'b' over that serial port and closes it at once, so a
    start runs with nothing reading the serial (the board's standalone case).
Needs: pip install bleak
"""

import argparse
import asyncio
import os
import struct
import time
from collections import deque
from pathlib import Path

from bleak import BleakClient, BleakScanner

SERVICE = "f7280000-22eb-44d8-be12-ecd2b6bdd709"
EVENT = "f7280001-22eb-44d8-be12-ecd2b6bdd709"
PING = "f7280002-22eb-44d8-be12-ecd2b6bdd709"
PONG = "f7280003-22eb-44d8-be12-ecd2b6bdd709"
DATA = "f7280004-22eb-44d8-be12-ecd2b6bdd709"
CTRL = "f7280005-22eb-44d8-be12-ecd2b6bdd709"
LSB_G = 16.0 / 32768.0

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


class RunReceiver:
    """One run's recording, put together from the data packets."""

    def __init__(self):
        self.info = None
        self.samples = {}
        self.ended = False
        self.t_info = None

    def on_packet(self, b):
        kind = b[0]
        if kind == 1 and len(b) >= 51:
            f = struct.unpack_from("<IHHHIIIIHBBiIHHIHH", b, 1)
            keys = ("boot", "id", "n", "preroll", "on", "set", "go", "arm", "arm_mg100",
                    "flags", "verdict", "rt_us", "onset", "dropped", "gaps", "maxgap",
                    "clockstep", "odr")
            info = dict(zip(keys, f))
            if self.info is None or (info["boot"], info["id"]) != (self.info["boot"], self.info["id"]):
                self.samples, self.ended = {}, False
                self.t_info = time.time()
            self.info = info
        elif kind == 2 and self.info is not None:
            rid, idx = struct.unpack_from("<HH", b, 1)
            if rid != self.info["id"]:
                return
            for k in range((len(b) - 5) // 10):
                self.samples[idx + k] = struct.unpack_from("<Ihhh", b, 5 + 10 * k)
        elif kind == 3:
            self.ended = True
        elif kind == 4:
            print("      data: NO_RUN (the board holds no such run)")

    def missing(self):
        n = self.info["n"]
        miss, i = [], 0
        while i < n:
            if i in self.samples:
                i += 1
                continue
            j = i
            while j < n and j not in self.samples:
                j += 1
            miss.append((i, j))
            i = j
        return miss

    def write(self, outdir):
        from capture import result_tag, write_csv
        i = self.info
        verdicts = ["valid start", "FALSE START", "no movement", "UNUSABLE"]
        header = {"on_t_us": i["on"], "set_t_us": i["set"], "go_t_us": i["go"],
                  "preroll_samples": i["preroll"], "truncated": int(bool(i["flags"] & 4)),
                  "dropped": i["dropped"], "clockstep_us": i["clockstep"],
                  "gaps": i["gaps"], "max_gap_us": i["maxgap"], "board_run_id": i["id"],
                  "sensor": "bmi270", "odr_hz": i["odr"],
                  "board_verdict": verdicts[i["verdict"]] if i["verdict"] < 4 else "UNUSABLE",
                  "board_reaction_ms": i["rt_us"] / 1000.0, "board_onset_t_us": i["onset"]}
        if i["flags"] & 1:
            header.update(arm_t_us=i["arm"], arm_peak_mg=i["arm_mg100"] / 100.0,
                          arm_capped=int(bool(i["flags"] & 2)))
        rows = [(t, round(x * LSB_G, 4), round(y * LSB_G, 4), round(z * LSB_G, 4))
                for t, x, y, z in (self.samples[k] for k in range(i["n"]))]
        name = f"ble_{time.strftime('%Y%m%d_%H%M%S')}_r{i['id']:05d}_{result_tag(header)}.csv"
        path = Path(outdir) / name
        warn = write_csv(path, header, rows)
        return path, warn


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--start-serial")
    ap.add_argument("--runs", type=int, default=0, help="stop after this many runs saved")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
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
        if kind in ("GO", "RESULT"):
            last.setdefault("t_" + kind, time.time())
            if kind == "RESULT" and "t_GO" in last:
                line += f"  ({(last['t_RESULT'] - last['t_GO']) * 1000:.0f} ms after GO arrived)"
        if kind == "COUNTDOWN" and data[2] == 3:
            last.pop("t_GO", None)
            last.pop("t_RESULT", None)
        print(line)

    rx = RunReceiver()
    saved = {"n": 0, "keys": set()}

    async with BleakClient(dev) as client:
        print(f"Connected to {dev.address}, MTU {client.mtu_size}")
        await client.start_notify(EVENT, on_event)
        await client.start_notify(PONG, lambda _, d: sync.on_reply(d))
        await client.start_notify(DATA, lambda _, d: rx.on_packet(bytes(d)))
        await client.write_gatt_char(CTRL, bytes([1, 0, 0, 0, 0, 0xFF, 0xFF]), response=True)
        if args.start_serial:
            import serial
            s = serial.Serial(args.start_serial, 921600)
            s.write(b"b"); s.flush(); s.close()
            print("      start sent over serial, port closed")
        on_event(None, await client.read_gatt_char(EVENT))   # where the board is now
        n = 0
        while client.is_connected:
            if rx.ended and rx.info is not None:
                key = (rx.info["boot"], rx.info["id"])
                miss = rx.missing()
                if miss:
                    a, b = miss[0]
                    print(f"      data: {len(miss)} hole(s), asking for [{a}, {b})")
                    rx.ended = False
                    await client.write_gatt_char(CTRL, struct.pack("<BHHH", 1, rx.info["id"], a, b), response=True)
                elif key not in saved["keys"]:
                    await client.write_gatt_char(CTRL, struct.pack("<BH", 2, rx.info["id"]), response=True)
                    path, warn = rx.write(args.outdir)
                    saved["keys"].add(key)
                    saved["n"] += 1
                    print(f"      data: run {rx.info['id']} complete, {rx.info['n']} samples in "
                          f"{time.time() - rx.t_info:.1f} s, ACKed -> {path.name}")
                    for w in warn:
                        print("      !!", w)
                    if args.runs and saved["n"] >= args.runs:
                        return
                else:
                    rx.ended = False
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
