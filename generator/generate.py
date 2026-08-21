"""Synthetic device telemetry generator.

Simulates a fleet of devices emitting readings, batches them, and POSTs to the
ingest API. Each device holds continuous state so the output looks like real
hardware drifting rather than independent random draws -- which matters, because
uncorrelated noise makes every downstream aggregate look identical.
"""

import argparse
import math
import os
import random
import sys
import time
from dataclasses import dataclass, field

import requests

INGEST_URL = os.environ.get("INGEST_URL", "http://localhost:3000")


@dataclass
class Device:
    """One simulated device with drifting internal state."""

    device_id: str
    model: str
    fleet: str
    temperature: float = 45.0
    voltage: float = 12.6
    rpm: int = 2000
    phase: float = field(default_factory=lambda: random.uniform(0, math.tau))
    faulty: bool = False

    def step(self, t: float) -> dict:
        # Diurnal temperature cycle plus a random walk, clamped to plausible range.
        cycle = 8.0 * math.sin(t / 3600.0 + self.phase)
        self.temperature += random.gauss(0, 0.3)
        self.temperature = max(10.0, min(120.0, self.temperature))

        self.voltage += random.gauss(0, 0.02)
        self.voltage = max(10.5, min(14.4, self.voltage))

        self.rpm += int(random.gauss(0, 60))
        self.rpm = max(0, min(6000, self.rpm))

        # Faulty devices run hot and occasionally throw a code. Roughly 5% of the
        # fleet is faulty, which gives dashboards something to actually show.
        error_code = None
        if self.faulty:
            self.temperature += 0.4
            if random.random() < 0.02:
                error_code = random.choice([101, 102, 203, 500])

        return {
            "device_id": self.device_id,
            "temperature": round(self.temperature + cycle, 2),
            "voltage": round(self.voltage, 3),
            "rpm": self.rpm,
            "error_code": error_code,
        }


def build_fleet(count: int) -> list[Device]:
    models = ["VX-100", "VX-200", "TR-50", "TR-90"]
    fleets = ["north", "south", "east", "west"]
    devices = []
    for i in range(count):
        devices.append(
            Device(
                device_id=f"dev-{i:04d}",
                model=models[i % len(models)],
                fleet=fleets[i % len(fleets)],
                faulty=random.random() < 0.05,
            )
        )
    return devices


def register(devices: list[Device], session: requests.Session) -> None:
    payload = [
        {"device_id": d.device_id, "model": d.model, "fleet": d.fleet} for d in devices
    ]
    for attempt in range(30):
        try:
            r = session.post(f"{INGEST_URL}/devices", json=payload, timeout=10)
            r.raise_for_status()
            print(f"registered {len(devices)} devices", flush=True)
            return
        except requests.RequestException as exc:
            print(f"waiting for ingest api ({exc.__class__.__name__})...", flush=True)
            time.sleep(2)
    sys.exit("ingest api never became reachable")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--devices", type=int, default=200)
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between batches")
    ap.add_argument("--batch-size", type=int, default=500,
                    help="max readings per POST")
    args = ap.parse_args()

    session = requests.Session()
    devices = build_fleet(args.devices)
    register(devices, session)

    sent = 0
    started = time.time()

    while True:
        loop_start = time.time()
        t = loop_start - started
        batch = [d.step(t) for d in devices]

        # Chunk to batch_size so one slow flush can't produce an unbounded request.
        for i in range(0, len(batch), args.batch_size):
            chunk = batch[i : i + args.batch_size]
            try:
                r = session.post(f"{INGEST_URL}/readings", json=chunk, timeout=10)
                if r.status_code == 429:
                    # Ingest is shedding load. Back off rather than pile on.
                    time.sleep(1.0)
                    continue
                r.raise_for_status()
                sent += len(chunk)
            except requests.RequestException as exc:
                print(f"post failed: {exc}", flush=True)
                time.sleep(1.0)

        elapsed = time.time() - started
        if int(elapsed) % 10 == 0:
            print(f"{sent} readings sent, {sent / max(elapsed, 1):.0f}/sec", flush=True)

        # Sleep the remainder of the interval, not the whole interval, so the
        # emit rate stays steady regardless of how long the POST took.
        time.sleep(max(0.0, args.interval - (time.time() - loop_start)))


if __name__ == "__main__":
    main()
