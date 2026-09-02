#!/usr/bin/env python3
"""Neural MMO 2 env served over 2-contract/bus (iceoryx2 DYNAMIC command bus).

Reuses `weft_harness.Bus(role="server")` + `serve()` verbatim: the wire is
the same command/reply envelope every plane in the fabric uses. The body
is JSON per this env's protocol (see `handle` below); a future FIXED_SIZE
struct pair could replace the JSON without touching Elixir's dispatch.

Protocol (JSON body, bytes on the wire):
    -> {"op": "reset", "seed": 42}
    <- {"obs": {..}, "info": {..}}
    -> {"op": "step", "actions": {"1": {"Move": {"Direction": 1}}, ...}}
    <- {"obs": {..}, "rew": {..}, "term": {..}, "trunc": {..}, "info": {..}}
    -> {"op": "close"}
    <- {"ok": true}  (server exits after the reply)

STDIO JSON was tried and is now blocklisted; this file is what the Elixir
`Env` NIF talks to. Do not add a stdio fallback.

Bootstrap:
    export WEFT_ICEORYX2_PATH=/path/to/libiceoryx2_ffi_c.dylib
    pip install iceoryx2==0.9.3 nmmo==2.1.2  # or via pixi
    python priv/env_bus_server.py
"""

import sys
from pathlib import Path

import cbor2
import numpy as np
import zstandard
import nmmo
from nmmo import config


class Big(config.Small):
    """128-agent nmm2 config. The raw JSON obs is ~7 MB and the CBOR
    obs is ~430 KB (still over the bus's 128 KiB ceiling), but
    CBOR+zstd is ~5 KB. Both sides speak CBOR wrapped in zstd; the
    envelope byte is `Z` for zstd (default), `C` for plain CBOR."""

    PLAYER_N = 128
    HORIZON = 128


_ZCTX = zstandard.ZstdCompressor(level=3)
_DCTX = zstandard.ZstdDecompressor()


def encode(obj: object) -> bytes:
    return b"Z" + _ZCTX.compress(cbor2.dumps(obj))


def decode(buf: bytes) -> object:
    tag, body = buf[:1], buf[1:]
    if tag == b"Z":
        return cbor2.loads(_DCTX.decompress(body))
    if tag == b"C":
        return cbor2.loads(body)
    raise ValueError(f"unknown envelope tag {tag!r}")

# 2-contract/bus/python is the canonical import path for the bus SDK.
BUS_PY = Path(__file__).resolve().parents[3] / "2-contract" / "bus" / "python"
if str(BUS_PY) not in sys.path:
    sys.path.insert(0, str(BUS_PY))

from weft_harness.bus import Bus, StopServing, serve  # noqa: E402


env = None

# Persona.ex only reads AgentId, Entity, Inventory, Market. Everything
# else is heavy (Tile alone is ~15x15 grid x channels), and the command
# bus is sized for command/reply (128 KiB per message), not bulk state.
# The full obs is 7+ MB with 128 agents; the project below is ~50 KB.
_KEEP_OBS_KEYS = ("AgentId", "CurrentTick", "Entity", "Inventory", "Market")


def project(obs):
    return {aid: {k: v for k, v in ob.items() if k in _KEEP_OBS_KEYS}
            for aid, ob in obs.items()}


def to_native(x):
    if isinstance(x, np.ndarray):
        return x.tolist()
    if isinstance(x, dict):
        return {k: to_native(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [to_native(v) for v in x]
    if isinstance(x, np.integer):
        return int(x)
    if isinstance(x, np.floating):
        return float(x)
    return x


def handle(command_bytes: bytes) -> bytes:
    global env
    req = decode(command_bytes)
    op = req["op"]

    if op == "reset":
        env = nmmo.Env(Big(), seed=int(req["seed"]))
        obs, info = env.reset(seed=int(req["seed"]))
        return encode({"obs": to_native(project(obs)), "info": to_native(info)})

    if op == "step":
        raw = req["actions"]
        actions = {
            int(k): {str(g): {str(a): int(v) for a, v in args.items()}
                     for g, args in a.items()}
            for k, a in raw.items()
        }
        obs, rew, term, trunc, info = env.step(actions)
        return encode({
            "obs": to_native(project(obs)),
            "rew": to_native(rew),
            "term": to_native(term),
            "trunc": to_native(trunc),
            "info": to_native(info),
        })

    if op == "close":
        raise StopServing()

    return encode({"error": f"unknown op {op!r}"})


def main():
    bus = Bus(role="server")
    serve(bus, handle)


if __name__ == "__main__":
    main()
