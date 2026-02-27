#!/usr/bin/env python
"""
ctl.py  --  Pulse sequencer control for DE10-Nano HPS

Writes parameters to the pulse_sequencer_avalon FPGA component via /dev/mem.
Must be run as root (or with appropriate /dev/mem permissions).

Usage:
    python ctl.py start SEQ_LIMIT RP_START RP_DUR RO_START RO_DUR SYNC_START [REPEATS]
    python ctl.py stop
    python ctl.py status
    python ctl.py wait [POLL_SECONDS]

Arguments for 'start' (all in FPGA clock cycles):
    SEQ_LIMIT   Period length
    RP_START    RP AOM pulse start offset from period start
    RP_DUR      RP AOM pulse duration
    RO_START    RO AOM pulse start offset from period start
    RO_DUR      RO AOM pulse duration
    SYNC_START  Sync pulse start offset (fixed duration: 20 cycles)
    REPEATS     Number of periods to run; 0 or omitted = infinite
"""
from __future__ import print_function

import contextlib
import mmap
import os
import struct
import sys
import time

# ---------------------------------------------------------------------------
# Hardware constants
# ---------------------------------------------------------------------------
COMPONENT_ADDR = 0xFF24000   # Base address of the Avalon-MM slave in /dev/mem
SPAN           = 4096        # mmap window size (must be a multiple of page size)

SYNC_DUR_FIXED = 20          # Must match the localparam in the RTL

# Byte offsets into the mmap window  (Avalon word address x 4)
OFFSET_CONTROL      = 0x00   # W: bit0=start, bit1=stop  |  R: bit0=running
OFFSET_SEQ_LIMIT    = 0x04   # R/W  Avalon 0x01
OFFSET_RP_START     = 0x08   # R/W  Avalon 0x02
OFFSET_RP_DUR       = 0x0C   # R/W  Avalon 0x03
OFFSET_RO_START     = 0x10   # R/W  Avalon 0x04
OFFSET_RO_DUR       = 0x14   # R/W  Avalon 0x05
OFFSET_SYNC_START   = 0x18   # R/W  Avalon 0x06
OFFSET_REPEAT_LIMIT = 0x1C   # R/W  Avalon 0x07  (0 = infinite)
OFFSET_REPEAT_COUNT = 0x20   # R/O  Avalon 0x08

# ---------------------------------------------------------------------------
# Low-level register access
# ---------------------------------------------------------------------------
def write_reg(mem, offset, value):
    mem[offset:offset + 4] = struct.pack('<I', value)

def read_reg(mem, offset):
    return struct.unpack('<I', mem[offset:offset + 4])[0]

@contextlib.contextmanager
def fpga_mem():
    """Open /dev/mem and yield the mmap'd register window.
    Guarantees cleanup even if an exception is raised by the caller."""
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        mem = mmap.mmap(fd, SPAN, mmap.MAP_SHARED,
                        mmap.PROT_READ | mmap.PROT_WRITE,
                        offset=COMPONENT_ADDR)
        try:
            yield mem
        finally:
            mem.close()
    finally:
        os.close(fd)

# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------
def validate(seq_limit, rp_start, rp_dur, ro_start, ro_dur, sync_start, repeats):
    errors = []
    if seq_limit < 1:
        errors.append("SEQ_LIMIT must be >= 1")
    if rp_start + rp_dur > seq_limit:
        errors.append("RP pulse extends past end of period "
                      "({0} + {1} > {2})".format(rp_start, rp_dur, seq_limit))
    if ro_start + ro_dur > seq_limit:
        errors.append("RO pulse extends past end of period "
                      "({0} + {1} > {2})".format(ro_start, ro_dur, seq_limit))
    if sync_start + SYNC_DUR_FIXED > seq_limit:
        errors.append("SYNC pulse extends past end of period "
                      "({0} + {1} > {2})".format(sync_start, SYNC_DUR_FIXED, seq_limit))
    if repeats < 0:
        errors.append("REPEATS must be >= 0  (0 = infinite)")
    if errors:
        raise ValueError("\n".join(errors))

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_start(argv):
    if len(argv) not in (6, 7):
        _usage_error("'start' requires 6 or 7 arguments")
    try:
        seq_limit  = int(argv[0])
        rp_start   = int(argv[1])
        rp_dur     = int(argv[2])
        ro_start   = int(argv[3])
        ro_dur     = int(argv[4])
        sync_start = int(argv[5])
        repeats    = int(argv[6]) if len(argv) == 7 else 0
    except ValueError:
        _usage_error("all 'start' arguments must be integers")

    validate(seq_limit, rp_start, rp_dur, ro_start, ro_dur, sync_start, repeats)

    with fpga_mem() as mem:
        write_reg(mem, OFFSET_SEQ_LIMIT,    seq_limit)
        write_reg(mem, OFFSET_RP_START,     rp_start)
        write_reg(mem, OFFSET_RP_DUR,       rp_dur)
        write_reg(mem, OFFSET_RO_START,     ro_start)
        write_reg(mem, OFFSET_RO_DUR,       ro_dur)
        write_reg(mem, OFFSET_SYNC_START,   sync_start)
        write_reg(mem, OFFSET_REPEAT_LIMIT, repeats)
        write_reg(mem, OFFSET_CONTROL, 1)   # start strobe

def cmd_stop(argv):
    with fpga_mem() as mem:
        write_reg(mem, OFFSET_CONTROL, 2)   # stop strobe

def cmd_status(argv):
    with fpga_mem() as mem:
        running      = read_reg(mem, OFFSET_CONTROL) & 1
        seq_limit    = read_reg(mem, OFFSET_SEQ_LIMIT)
        rp_start     = read_reg(mem, OFFSET_RP_START)
        rp_dur       = read_reg(mem, OFFSET_RP_DUR)
        ro_start     = read_reg(mem, OFFSET_RO_START)
        ro_dur       = read_reg(mem, OFFSET_RO_DUR)
        sync_start   = read_reg(mem, OFFSET_SYNC_START)
        repeat_limit = read_reg(mem, OFFSET_REPEAT_LIMIT)
        repeat_count = read_reg(mem, OFFSET_REPEAT_COUNT)

    print("running:      {0}".format(bool(running)))
    print("seq_limit:    {0} cycles".format(seq_limit))
    print("rp_start:     {0} cycles".format(rp_start))
    print("rp_dur:       {0} cycles".format(rp_dur))
    print("ro_start:     {0} cycles".format(ro_start))
    print("ro_dur:       {0} cycles".format(ro_dur))
    print("sync_start:   {0} cycles".format(sync_start))
    print("repeat_limit: {0}  (0 = infinite)".format(repeat_limit))
    print("repeat_count: {0}".format(repeat_count))

def cmd_wait(argv):
    """Block until the sequencer is no longer running.
    Useful after a finite-count start to know when acquisition is complete."""
    try:
        poll = float(argv[0]) if argv else 0.05
    except ValueError:
        _usage_error("'wait' optional argument POLL_SECONDS must be a number")

    with fpga_mem() as mem:
        while read_reg(mem, OFFSET_CONTROL) & 1:
            time.sleep(poll)

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------
COMMANDS = {
    'start':  cmd_start,
    'stop':   cmd_stop,
    'status': cmd_status,
    'wait':   cmd_wait,
}

def _usage_error(msg=None):
    if msg:
        print("Error: {0}\n".format(msg), file=sys.stderr)
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        _usage_error()
    try:
        COMMANDS[sys.argv[1]](sys.argv[2:])
    except ValueError as e:
        print("Error: {0}".format(e), file=sys.stderr)
        sys.exit(1)
