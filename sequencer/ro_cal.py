"""
sequencer/ro_cal.py — Readout calibration experiment.

Single-cycle supercycle: RP → RO.  No MW.
Used to verify AOM / PicoHarp alignment and optimise the readout window.
"""
from __future__ import annotations

from .api import Cycle, FPGAConfig


class ROCal(FPGAConfig):
    """
    RP → RO, single cycle.  Runs indefinitely (super_cycle_repeats=0).

    Timeline (default params, 50 MHz clock):
        0      SYNC(5)
        10     RP(rp_duration)
        170    RO(ro_duration)    ← 10 cycles after RP end

    rp_duration property: moves the RP pulse end, keeps start fixed.
    ro_start tracks rp_end + 10 automatically when rp_duration is set.
    """

    RP_START = 10
    MARGIN   = 35   # trailing idle cycles

    def __init__(
        self,
        rp_duration: int = 150,
        ro_start:    int | None = None,
        ro_duration: int = 15,
        cycle_time:  int | None = None,
    ):
        self._rp_duration = rp_duration
        self._ro_duration = ro_duration

        if ro_start is None:
            ro_start = self.RP_START + rp_duration + 10
        self._ro_start = ro_start

        if cycle_time is None:
            cycle_time = ro_start + ro_duration + self.MARGIN

        super().__init__(
            cycles={"cal": Cycle(
                rp   = [(self.RP_START, rp_duration)],
                ro   = [(ro_start,      ro_duration)],
                veto = [(self.RP_START, rp_duration)],
            )},
            super_cycle         = [("cal", 1)],
            cycle_time          = cycle_time,
            sync                = True,
            super_cycle_repeats = 0,
        )

    # ── rp_duration property ────────────────────────────────────────────────

    @property
    def rp_duration(self) -> int:
        """RP pulse duration in clock cycles.  Start time stays fixed."""
        return self._rp_duration

    @rp_duration.setter
    def rp_duration(self, val: int) -> None:
        self._rp_duration = val
        new_ro_start = self.RP_START + val + 10
        self._ro_start = new_ro_start
        cal = self.cycles["cal"]
        cal.rp   = [(self.RP_START, val)]
        cal.veto = [(self.RP_START, val)]
        cal.ro   = [(new_ro_start, self._ro_duration)]
        self.cycle_time = new_ro_start + self._ro_duration + self.MARGIN
