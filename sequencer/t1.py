"""
sequencer/t1.py — T1 spin-lattice relaxation experiment.

3-cycle supercycle:
  cal_0  (bright ref): RP → RO           no MW.  Marker 0.
  cal_1  (dark  ref):  RP → MW(π) → RO  immediate readout after π-pulse.  Marker 1.
  t1     (signal):     RP → MW(π) → τ → RO.  Marker 2.

Sweep t1.tau to map the T1 decay.
"""
from __future__ import annotations

from .api import Cycle, FPGAConfig


class T1(FPGAConfig):
    """
    3-cycle supercycle for NV centre T1 measurement.

    All cycles share the same cycle_time (hardware requirement).
    cal_0 and cal_1 have fixed-position RO pulses; the t1 RO position
    moves with tau.  cycle_time is updated automatically when tau changes.

    Parameters
    ----------
    tau_us        : free-precession wait time in µs  (swept during experiment)
    rp_duration   : repump pulse length in clock cycles
    mw_pi_duration: π-pulse length in clock cycles
    ro_duration   : readout window length in clock cycles
    clock_mhz     : FPGA clock frequency (default 50 MHz)
    """

    RP_START = 0
    MARGIN   = 35   # trailing idle cycles

    def __init__(
        self,
        tau_us:         float = 2.8,
        rp_duration:    int   = 150,
        mw_pi_duration: int   = 5,
        ro_start:       int   = 200,
        ro_duration:    int   = 15,
        clock_mhz:      float = 50.0,
    ):
        self._clock_mhz    = clock_mhz
        self._rp_duration  = rp_duration
        self._mw_pi        = mw_pi_duration
        self._ro_start     = ro_start
        self._ro_duration  = ro_duration
        self._tau_cyc      = round(tau_us * clock_mhz)

        cycles, cycle_time = self._build()
        super().__init__(
            cycles              = cycles,
            super_cycle         = [("cal_0", 1), ("cal_1", 1), ("t1", 1)],
            cycle_time          = cycle_time,
            sync                = True,
            super_cycle_repeats = 0,
        )

    # ── Internal builder ────────────────────────────────────────────────────

    def _build(self) -> tuple[dict[str, Cycle], int]:
        mw_start      = self.RP_START + self._rp_duration
        # Calibration RO positions (fixed regardless of tau)
        cal_ro_start  = mw_start + 10                          # bright ref: right after RP
        dark_ro_start = mw_start + self._mw_pi + 5            # dark  ref: right after MW
        sig_ro_start  = mw_start + self._mw_pi + self._tau_cyc  # signal:    after tau

        cycle_time = (
            max(cal_ro_start, dark_ro_start, sig_ro_start)
            + self._ro_duration + self.MARGIN
        )

        cal_0 = Cycle(
            rp   = [(self.RP_START, self._rp_duration)],
            ro   = [(self._ro_start,  self._ro_duration)],
            veto = [(self.RP_START, self._rp_duration + self._mw_pi)],
            marker = 0,
        )
        cal_1 = Cycle(
            rp   = [(self.RP_START, self._rp_duration)],
            mw   = [(mw_start,      self._mw_pi)],
            ro   = [(self._ro_start, self._ro_duration)],
            veto = [(self.RP_START, self._rp_duration + self._mw_pi)],
            marker = 1,
        )
        t1_cycle = Cycle(
            rp   = [(self.RP_START, self._rp_duration)],
            mw   = [(mw_start,      self._mw_pi)],
            ro   = [(self._ro_start,  self._ro_duration)],
            veto = [(self.RP_START, self._rp_duration + self._mw_pi)],
            marker = 2,
        )

        return {"cal_0": cal_0, "cal_1": cal_1, "t1": t1_cycle}, cycle_time

    def _rebuild(self) -> None:
        cycles, cycle_time = self._build()
        self.cycles     = cycles
        self.cycle_time = cycle_time

    # ── tau property ────────────────────────────────────────────────────────

    @property
    def tau(self) -> float:
        """Free-precession wait time in µs."""
        return self._tau_cyc / self._clock_mhz

    @tau.setter
    def tau(self, val_us: float) -> None:
        self._tau_cyc = round(val_us * self._clock_mhz)
        self._rebuild()

    # ── rp_duration property ────────────────────────────────────────────────

    @property
    def rp_duration(self) -> int:
        """RP pulse duration in clock cycles (applied to all three cycles)."""
        return self._rp_duration

    @rp_duration.setter
    def rp_duration(self, val: int) -> None:
        self._rp_duration = val
        self._rebuild()
