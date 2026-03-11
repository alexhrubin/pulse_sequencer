#!/usr/bin/env python
"""
pulse_sequencer_control.py  --  NV center pulse sequencer control for DE10-Nano HPS

Communicates with the pulse_sequencer_avalon FPGA component via /dev/mem.
Must be run as root (or with appropriate /dev/mem permissions).

New API (super-cycle mode):
    python pulse_sequencer_control.py configure <json_file>
        Load a full SequencerConfig from a JSON file and write it to the FPGA.

    python pulse_sequencer_control.py start-super <json_file> [--repeats N]
        Configure and start. N=0 or omitted = infinite.

    python pulse_sequencer_control.py stop
    python pulse_sequencer_control.py status
    python pulse_sequencer_control.py wait [POLL_SECONDS]

Legacy API (backward compatible, single experiment cycle):
    python pulse_sequencer_control.py start SEQ_LIMIT RP_START RP_DUR \\
                                            RO_START RO_DUR SYNC_START [REPEATS]
        All values in FPGA clock cycles. REPEATS=0 or omitted = infinite.
        Maps to a single-step super-cycle using cycle type 0.
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
COMPONENT_ADDR = 0xFF240000  # Base address of the Avalon-MM slave in /dev/mem
SPAN           = 4096        # mmap window size (bytes)

# FPGA parameters (must match RTL parameters)
MAX_CYCLE_TYPES  = 8
MAX_SLOTS        = 16
MAX_SEQ_LEN      = 32
NUM_MARKERS      = 3
BRAM_WORDS_PER_CYCLE = 256   # power-of-2 block size; 137 used, 119 reserved

# ---------------------------------------------------------------------------
# Avalon register word addresses (multiply by 4 for byte offset)
# ---------------------------------------------------------------------------
REG_CONTROL       = 0x00  # W: bit0=start, bit1=stop  R: bit0=running
REG_SUPER_LIMIT   = 0x01  # R/W  super-cycle repeat limit (0=infinite)
REG_SUPER_COUNT   = 0x02  # R/O  super-cycles completed
REG_STATUS_EXT    = 0x03  # R/O  {running, active_bank, prefetch_busy, 0,0,0, seq_pos[4:0]}
REG_TIMER_SNAP    = 0x04  # R/O  timer latched at read
REG_SEQ_LEN       = 0x05  # R/W  number of valid sequence entries
REG_BRAM_ADDR     = 0x06  # R/W  BRAM access pointer (word address)
REG_BRAM_DATA     = 0x07  # R/W  BRAM data; writes auto-increment pointer
REG_SEQ_TYPE_BASE = 0x10  # R/W  SEQ_TYPE[0..31]  @ 0x10..0x2F
REG_SEQ_CNT_BASE  = 0x30  # R/W  SEQ_COUNT[0..31] @ 0x30..0x4F

# BRAM word offsets within a cycle-type block (must match RTL localparams)
OFF_SEQ_LIMIT = 0
OFF_RP        = 1
OFF_RO        = 1 + MAX_SLOTS * 2    # 33
OFF_MW        = 1 + MAX_SLOTS * 4    # 65
OFF_VETO      = 1 + MAX_SLOTS * 6    # 97
OFF_SYNC_ST   = 1 + MAX_SLOTS * 8    # 129
OFF_SYNC_DUR  = 2 + MAX_SLOTS * 8    # 130
OFF_MK_BASE   = 3 + MAX_SLOTS * 8    # 131

WORDS_PER_CYCLE = 1 + MAX_SLOTS * 8 + 2 + NUM_MARKERS * 2   # 137


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

class PulseSlot:
    """One pulse window: start offset and duration, both in FPGA clock cycles.
    duration=0 disables this slot (produces no output)."""

    def __init__(self, start=0, duration=0):
        self.start = start
        self.duration = duration

    def validate(self, seq_limit, name="slot"):
        errs = []
        if self.duration < 0:
            errs.append("%s: duration must be >= 0" % name)
        if self.duration > 0 and self.start + self.duration > seq_limit:
            errs.append("%s: pulse extends past period end "
                        "(%d + %d > %d)" % (name, self.start, self.duration, seq_limit))
        return errs


class CycleTypeDef:
    """Configuration for one reusable cycle type, stored in one BRAM block."""

    def __init__(self, seq_limit=5000, rp=None, ro=None, mw=None, veto=None,
                 sync=None, markers=None):
        self.seq_limit = seq_limit
        self.rp = rp if rp is not None else []
        self.ro = ro if ro is not None else []
        self.mw = mw if mw is not None else []
        self.veto = veto if veto is not None else []
        self.sync = sync if sync is not None else PulseSlot()
        self.markers = markers if markers is not None else [PulseSlot() for _ in range(NUM_MARKERS)]

    def validate(self, name="cycle"):
        errs = []
        if self.seq_limit < 1:
            errs.append("%s: seq_limit must be >= 1" % name)
        for ch_name, slots in [("rp", self.rp), ("ro", self.ro),
                                ("mw", self.mw), ("veto", self.veto)]:
            if len(slots) > MAX_SLOTS:
                errs.append("%s.%s: too many slots (max %d)" % (name, ch_name, MAX_SLOTS))
            for i, s in enumerate(slots):
                errs.extend(s.validate(self.seq_limit, "%s.%s[%d]" % (name, ch_name, i)))
        errs.extend(self.sync.validate(self.seq_limit, "%s.sync" % name))
        for i, m in enumerate(self.markers[:NUM_MARKERS]):
            errs.extend(m.validate(self.seq_limit, "%s.marker%d" % (name, i)))
        return errs

    def to_words(self):
        """Serialize to a flat list of WORDS_PER_CYCLE 32-bit integers."""
        words = [self.seq_limit]
        for slots in [self.rp, self.ro, self.mw, self.veto]:
            for s in range(MAX_SLOTS):
                slot = slots[s] if s < len(slots) else PulseSlot()
                words.append(slot.start)
                words.append(slot.duration)
        words.append(self.sync.start)
        words.append(self.sync.duration)
        for m in range(NUM_MARKERS):
            slot = self.markers[m] if m < len(self.markers) else PulseSlot()
            words.append(slot.start)
            words.append(slot.duration)
        assert len(words) == WORDS_PER_CYCLE, "word count mismatch: %d" % len(words)
        return words

    @classmethod
    def from_dict(cls, d):
        def slot(v):
            if v is None:
                return PulseSlot()
            return PulseSlot(start=v[0], duration=v[1])
        return cls(
            seq_limit=d.get("seq_limit", 5000),
            rp=[slot(s) for s in d.get("rp", [])],
            ro=[slot(s) for s in d.get("ro", [])],
            mw=[slot(s) for s in d.get("mw", [])],
            veto=[slot(s) for s in d.get("veto", [])],
            sync=slot(d.get("sync")),
            markers=[slot(d.get("marker%d" % i)) for i in range(NUM_MARKERS)],
        )


class SuperCycleStep:
    """One entry in the super-cycle sequence."""

    def __init__(self, cycle_type_index, count=1):
        self.cycle_type_index = cycle_type_index
        self.count = count


class SequencerConfig:
    """Complete configuration for the pulse sequencer."""

    def __init__(self, cycle_types, sequence, super_repeat_limit=0):
        self.cycle_types = cycle_types
        self.sequence = sequence
        self.super_repeat_limit = super_repeat_limit

    def validate(self):
        errs = []
        if not self.cycle_types:
            errs.append("cycle_types must not be empty")
        if len(self.cycle_types) > MAX_CYCLE_TYPES:
            errs.append("too many cycle types (max %d)" % MAX_CYCLE_TYPES)
        if not self.sequence:
            errs.append("sequence must not be empty")
        if len(self.sequence) > MAX_SEQ_LEN:
            errs.append("sequence too long (max %d)" % MAX_SEQ_LEN)
        if self.super_repeat_limit < 0:
            errs.append("super_repeat_limit must be >= 0 (0=infinite)")
        for i, ct in enumerate(self.cycle_types):
            errs.extend(ct.validate("cycle_type[%d]" % i))
        for j, step in enumerate(self.sequence):
            if step.cycle_type_index >= len(self.cycle_types):
                errs.append("sequence[%d].cycle_type_index "
                            "%d out of range" % (j, step.cycle_type_index))
            if step.count < 1:
                errs.append("sequence[%d].count must be >= 1" % j)
        if errs:
            raise ValueError("\n".join(errs))

    @classmethod
    def from_dict(cls, d):
        cts = [CycleTypeDef.from_dict(c) for c in d.get("cycle_types", [])]
        seq = [SuperCycleStep(cycle_type_index=s["cycle_type_index"],
                              count=s.get("count", 1))
               for s in d.get("sequence", [])]
        return cls(cycle_types=cts, sequence=seq,
                   super_repeat_limit=d.get("super_repeat_limit", 0))


# ---------------------------------------------------------------------------
# Low-level register access
# All public functions use *word addresses* (same as Avalon address bus).
# Byte offset = word_addr * 4.
# ---------------------------------------------------------------------------

def _write(mem, word_addr, value):
    off = word_addr * 4
    mem[off:off + 4] = struct.pack('<I', value & 0xFFFFFFFF)

def _read(mem, word_addr):
    off = word_addr * 4
    return struct.unpack('<I', mem[off:off + 4])[0]

@contextlib.contextmanager
def fpga_mem():
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
# BRAM and register file writers
# ---------------------------------------------------------------------------

def write_cycle_type(mem, idx, defn):
    """Write one cycle type definition to its BRAM block."""
    words = defn.to_words()
    base  = idx * BRAM_WORDS_PER_CYCLE
    _write(mem, REG_BRAM_ADDR, base)
    for w in words:
        _write(mem, REG_BRAM_DATA, w)   # auto-increments BRAM pointer


def write_config(mem, cfg):
    """Write complete sequencer configuration. Does not start the sequencer."""
    _write(mem, REG_SUPER_LIMIT, cfg.super_repeat_limit)
    _write(mem, REG_SEQ_LEN, len(cfg.sequence))

    for idx, ct in enumerate(cfg.cycle_types):
        write_cycle_type(mem, idx, ct)

    for j, step in enumerate(cfg.sequence):
        _write(mem, REG_SEQ_TYPE_BASE + j, step.cycle_type_index)
        _write(mem, REG_SEQ_CNT_BASE  + j, step.count)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_configure(argv):
    """Load config from JSON file and write to FPGA (no start)."""
    if not argv:
        _usage_error("'configure' requires a JSON file argument")
    cfg = _load_json_config(argv[0])
    cfg.validate()
    with fpga_mem() as mem:
        write_config(mem, cfg)
    print("Configuration written.")


def cmd_start_super(argv):
    """Load config from JSON file, write, and start."""
    if not argv:
        _usage_error("'start-super' requires a JSON file argument")
    repeats = None
    json_file = argv[0]
    if len(argv) >= 3 and argv[1] == "--repeats":
        repeats = int(argv[2])

    cfg = _load_json_config(json_file)
    if repeats is not None:
        cfg.super_repeat_limit = repeats
    cfg.validate()

    with fpga_mem() as mem:
        write_config(mem, cfg)
        _write(mem, REG_CONTROL, 1)   # start strobe


def cmd_stop(argv):
    with fpga_mem() as mem:
        _write(mem, REG_CONTROL, 2)   # stop strobe


def cmd_status(argv):
    with fpga_mem() as mem:
        ctrl        = _read(mem, REG_CONTROL)
        super_limit = _read(mem, REG_SUPER_LIMIT)
        super_count = _read(mem, REG_SUPER_COUNT)
        status_ext  = _read(mem, REG_STATUS_EXT)
        timer_snap  = _read(mem, REG_TIMER_SNAP)
        seq_len     = _read(mem, REG_SEQ_LEN)
        seq_types   = [_read(mem, REG_SEQ_TYPE_BASE + j) for j in range(seq_len)]
        seq_counts  = [_read(mem, REG_SEQ_CNT_BASE  + j) for j in range(seq_len)]

    running         = bool(ctrl & 1)
    active_bank     = bool((status_ext >> 6) & 1)
    prefetch_busy   = bool((status_ext >> 5) & 1)
    seq_pos         = status_ext & 0x1F

    print("running:            %s" % running)
    print("active_bank:        %d" % int(active_bank))
    print("prefetch_busy:      %s" % prefetch_busy)
    print("seq_pos:            %d" % seq_pos)
    print("timer_snapshot:     %d" % timer_snap)
    print("super_repeat_limit: %d  (0=infinite)" % super_limit)
    print("super_repeat_count: %d" % super_count)
    print("sequence (%d steps):" % seq_len)
    for j in range(seq_len):
        print("  [%d] cycle_type=%d  count=%d" % (j, seq_types[j], seq_counts[j]))


def cmd_wait(argv):
    """Block until the sequencer stops running."""
    try:
        poll = float(argv[0]) if argv else 0.05
    except ValueError:
        _usage_error("'wait' optional argument POLL_SECONDS must be a number")
    with fpga_mem() as mem:
        while _read(mem, REG_CONTROL) & 1:
            time.sleep(poll)


def cmd_start_legacy(argv):
    """
    Backward-compatible 'start' command.
    Maps old flat parameters to a single-step super-cycle using cycle type 0.

    Usage: start SEQ_LIMIT RP_START RP_DUR RO_START RO_DUR SYNC_START [REPEATS]
    """
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

    cfg = SequencerConfig(
        cycle_types=[CycleTypeDef(
            seq_limit=seq_limit,
            rp=[PulseSlot(rp_start, rp_dur)],
            ro=[PulseSlot(ro_start, ro_dur)],
            sync=PulseSlot(sync_start, 20),  # preserve legacy fixed 20-cycle sync
        )],
        sequence=[SuperCycleStep(cycle_type_index=0, count=1)],
        super_repeat_limit=repeats,
    )
    cfg.validate()

    with fpga_mem() as mem:
        write_config(mem, cfg)
        _write(mem, REG_CONTROL, 1)   # start strobe


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_new_json(d):
    """
    Parse the new JSON format (identified by the 'cycle_time' top-level key)
    into a SequencerConfig.

    New format keys:
      cycle_time          -- shared seq_limit for all cycle types
      sync                -- bool; if True adds PulseSlot(0, 5) to every cycle
      super_cycle         -- list of {cycle: name, count: N}
      super_cycle_repeats -- int (0 = infinite)
      <name>: {...}       -- cycle definition dicts
    """
    cycle_time          = int(d["cycle_time"])
    sync                = bool(d.get("sync", True))
    super_cycle_repeats = int(d.get("super_cycle_repeats", 0))
    super_cycle_steps   = d.get("super_cycle", [])

    # Build cycle types in the order they first appear in super_cycle
    name_to_idx = {}
    cycle_type_list = []

    for step in super_cycle_steps:
        name = step["cycle"]
        if name in name_to_idx:
            continue
        raw = d.get(name)
        if raw is None or not isinstance(raw, dict):
            raise ValueError("Cycle '%s' referenced in super_cycle but not found in config" % name)

        rp   = [PulseSlot(int(s[0]), int(s[1])) for s in raw.get("rp",   []) if int(s[1]) > 0]
        ro   = [PulseSlot(int(s[0]), int(s[1])) for s in raw.get("ro",   []) if int(s[1]) > 0]
        mw   = [PulseSlot(int(s[0]), int(s[1])) for s in raw.get("mw",   []) if int(s[1]) > 0]
        veto = [PulseSlot(int(s[0]), int(s[1])) for s in raw.get("veto", []) if int(s[1]) > 0]

        sync_slot = PulseSlot(0, 5) if sync else PulseSlot()

        markers = [PulseSlot() for _ in range(NUM_MARKERS)]
        marker_ch = raw.get("marker")
        if marker_ch is not None:
            idx = int(marker_ch)
            if 0 <= idx < NUM_MARKERS:
                markers[idx] = PulseSlot(0, 5)

        ct = CycleTypeDef(
            seq_limit = cycle_time,
            rp   = rp,
            ro   = ro,
            mw   = mw,
            veto = veto,
            sync = sync_slot,
            markers = markers,
        )
        name_to_idx[name] = len(cycle_type_list)
        cycle_type_list.append(ct)

    sequence = [
        SuperCycleStep(
            cycle_type_index = name_to_idx[step["cycle"]],
            count            = int(step.get("count", 1)),
        )
        for step in super_cycle_steps
    ]

    return SequencerConfig(
        cycle_types        = cycle_type_list,
        sequence           = sequence,
        super_repeat_limit = super_cycle_repeats,
    )


def _parse_json(text):
    """Minimal JSON parser for trusted local config files."""
    text = text.replace("true", "True").replace("false", "False").replace("null", "None")
    return eval(text)


def _load_json_config(path):
    with open(path) as f:
        d = _parse_json(f.read())
    if "cycle_time" in d:
        return _parse_new_json(d)
    return SequencerConfig.from_dict(d)


# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------
COMMANDS = {
    'start':       cmd_start_legacy,
    'start-super': cmd_start_super,
    'configure':   cmd_configure,
    'stop':        cmd_stop,
    'status':      cmd_status,
    'wait':        cmd_wait,
}

def _usage_error(msg=None):
    if msg:
        print("Error: %s\n" % msg, file=sys.stderr)
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        _usage_error()
    try:
        COMMANDS[sys.argv[1]](sys.argv[2:])
    except ValueError as e:
        print("Error: %s" % e, file=sys.stderr)
        sys.exit(1)
