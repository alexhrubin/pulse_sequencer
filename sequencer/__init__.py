"""
sequencer — Lab PC API for the NV center pulse sequencer.

Quick start::

    from sequencer import FPGAConfig, PulseSequencer
    from sequencer.ro_cal import ROCal
    from sequencer.t1 import T1

    # Build a config
    ro_cal = ROCal(rp_duration=150)
    ro_cal.to_json()           # → new JSON format dict

    # Connect and run
    with PulseSequencer("de10nano.local") as ps:
        ps.configure(ro_cal)
        ps.start()
        ps.stop()
"""

from .api    import Cycle, FPGAConfig, SYNC_DURATION, MARKER_DURATION
from .client import PulseSequencer

__all__ = [
    "Cycle",
    "FPGAConfig",
    "PulseSequencer",
    "SYNC_DURATION",
    "MARKER_DURATION",
]
