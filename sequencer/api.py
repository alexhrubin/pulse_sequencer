"""
sequencer/api.py — Core data model for the NV center pulse sequencer lab PC API.

All time values are in FPGA clock cycles (integers).  At 50 MHz, 1 cycle = 20 ns.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Public constants
# ---------------------------------------------------------------------------
SYNC_DURATION   = 5   # clock cycles — fixed sync pulse width
MARKER_DURATION = 5   # clock cycles — fixed marker pulse width


# ---------------------------------------------------------------------------
# Cycle: one pulse-pattern template
# ---------------------------------------------------------------------------

@dataclass
class Cycle:
    """
    One reusable pulse-pattern template.

    rp, ro, mw, veto — lists of (start_cycle, duration_cycles) pairs.
                        duration=0 means disabled.
    marker           — which marker channel (0, 1, or 2) to raise at t=0,
                       or None for no marker.  The pulse is MARKER_DURATION cycles.
    """
    rp:     list[tuple[int, int]] = field(default_factory=list)
    ro:     list[tuple[int, int]] = field(default_factory=list)
    mw:     list[tuple[int, int]] = field(default_factory=list)
    veto:   list[tuple[int, int]] = field(default_factory=list)
    marker: int | None = None   # 0, 1, or 2; raised at t=0


# ---------------------------------------------------------------------------
# FPGAConfig: complete sequencer configuration
# ---------------------------------------------------------------------------

@dataclass
class FPGAConfig:
    """
    Complete configuration for the FPGA pulse sequencer.

    cycles             — dict mapping name → Cycle (all cycle templates)
    super_cycle        — ordered list of (cycle_name, count) pairs
    cycle_time         — shared period length for ALL cycles (hardware requirement)
    sync               — if True, raise sync at t=0 of every cycle (SYNC_DURATION cycles)
    super_cycle_repeats — 0 = infinite (default)
    """
    cycles:              dict[str, Cycle]
    super_cycle:         list[tuple[str, int]]
    cycle_time:          int
    sync:                bool = True
    super_cycle_repeats: int  = 0

    # ── Serialisation ───────────────────────────────────────────────────────

    def to_json(self) -> dict:
        """Return a dict in the canonical new JSON format."""
        d: dict = {}
        for name, cycle in self.cycles.items():
            entry: dict = {}
            for ch in ("rp", "ro", "mw", "veto"):
                entry[ch] = [list(p) for p in getattr(cycle, ch)]
            if cycle.marker is not None:
                entry["marker"] = int(cycle.marker)
            d[name] = entry
        d["cycle_time"]          = self.cycle_time
        d["sync"]                = self.sync
        d["super_cycle"]         = [{"cycle": name, "count": count}
                                    for name, count in self.super_cycle]
        d["super_cycle_repeats"] = self.super_cycle_repeats
        return d

    def to_hps_config(self) -> dict:
        """Return the dict to upload and run on the HPS (same as to_json)."""
        return self.to_json()

    def to_json_str(self, indent: int = 2) -> str:
        return json.dumps(self.to_json(), indent=indent)

    @classmethod
    def from_json(cls, d: dict) -> "FPGAConfig":
        """Parse the canonical new JSON format into an FPGAConfig."""
        _RESERVED = {"cycle_time", "sync", "super_cycle", "super_cycle_repeats"}

        cycle_time          = int(d["cycle_time"])
        sync                = bool(d.get("sync", True))
        super_cycle_repeats = int(d.get("super_cycle_repeats", 0))
        super_cycle         = [(step["cycle"], int(step.get("count", 1)))
                               for step in d.get("super_cycle", [])]

        cycles: dict[str, Cycle] = {}
        for key, val in d.items():
            if key in _RESERVED or not isinstance(val, dict):
                continue
            cycles[key] = Cycle(
                rp    = [tuple(p) for p in val.get("rp",   [])],
                ro    = [tuple(p) for p in val.get("ro",   [])],
                mw    = [tuple(p) for p in val.get("mw",   [])],
                veto  = [tuple(p) for p in val.get("veto", [])],
                marker = val.get("marker"),
            )

        return cls(
            cycles              = cycles,
            super_cycle         = super_cycle,
            cycle_time          = cycle_time,
            sync                = sync,
            super_cycle_repeats = super_cycle_repeats,
        )
