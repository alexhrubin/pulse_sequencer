# Extended NV Center Pulse Sequencer — Architecture Plan

## Context

The current sequencer generates one fixed set of pulses per period (one RP, one RO, one sync) cycling infinitely or N times. For NV center experiments we need:

1. A configurable **super-cycle** of N steps — e.g. cal_ms0 × 1 → cal_ms1 × 1 → experiment × 10 (arbitrary ordering and ratios in both directions)
2. **Arbitrary pulse patterns** per step: multiple RO/RP/MW pulses, not just one of each
3. New output channels: **MW switch TTL** and up to **3 PicoHarp marker pulses**
4. All of the above **configurable from Python** via the existing mmap interface

---

## Architecture Overview

### Key Design Decisions

**1. BRAM-backed cycle type config**
Cycle type definitions (up to 8) live in on-chip BRAM (not Avalon-MM register space), accessed via an indirect port in the small Avalon register file. This keeps the Avalon address bus at 7 bits while supporting MAX_CYCLE_TYPES=8, MAX_SLOTS=16 without bloating address space.

**2. Super-cycle sequence array**
Two Avalon-accessible arrays (`SEQ_TYPE[0..31]` + `SEQ_COUNT[0..31]`) define the super-cycle as an ordered list of (cycle_type_index, repeat_count) pairs. Examples:
- `[(0,1),(1,1),(2,1)]` → ms0 cal, ms1 cal, experiment (1:1:1)
- `[(0,1),(1,1),(2,10)]` → 2 calibrations + 10 experiments per super-cycle
- `[(0,5),(2,1)]` → 5 ms0 cals then 1 experiment (ms1 disabled)
- `[(0,1),(2,1),(1,1),(2,1)]` → ms0 cal, expt, ms1 cal, expt (interleaved)

**3. Double-buffered prefetch — zero dead-time between cycles**
Two identical banks of active config registers (Bank A and Bank B, each 105 words) eliminate dead-time at cycle transitions. One bank is *active* (drives comparators); the other is the *shadow* (being loaded from BRAM in the background). At a cycle type transition, banks swap in one clock cycle and the next cycle starts immediately. Loading the next step's config overlaps with the current step's execution — as long as the cycle's `seq_limit` is ≥ 106 clock cycles (2.1 µs), the prefetch always completes in time. If a step repeats multiple times (`SEQ_COUNT > 1`), the shadow bank loads the next *different* step's config on the first repeat, so it's ready well before the repetitions finish. The only startup cost is one initial load before the very first cycle begins (≈2 µs from `start` command to first output). Edge case: if `seq_limit < 106` on a step that is followed by a different cycle type, the FSM stalls a few extra cycles at the transition — in practice this means keeping experiment periods above 2 µs, which is always true for NV center work.

**4. Parameterized RTL**
`MAX_CYCLE_TYPES`, `MAX_SLOTS`, `MAX_SEQ_LEN`, `NUM_MARKERS` are Verilog parameters. Defaults: 8, 16, 32, 3.

**5. Configurable sync duration per cycle**
The old `SYNC_DUR_FIXED = 20` localparam is replaced by a per-cycle configurable sync duration stored in BRAM. The Python legacy shim explicitly writes 20 to preserve old behavior.

---

## Output Channels

| Signal | Type | Note |
|--------|------|------|
| `aom_rp_out` | active-high | RP AOM — unchanged |
| `aom_ro_out` | active-high | RO AOM — unchanged |
| `mw_out` | active-high | Microwave switch TTL — **NEW** |
| `sync_out` | active-low (idles high) | Sync — duration now configurable |
| `marker_out[0]` | active-high | PicoHarp marker 1 — **NEW** |
| `marker_out[1]` | active-high | PicoHarp marker 2 — **NEW** |
| `marker_out[2]` | active-high | PicoHarp marker 3 — **NEW** |

---

## Avalon Register Map (7-bit, 128 entries, SPAN=4096 unchanged)

```
Addr   Name                Description
-----  ----                -----------
0x00   CONTROL             W: bit0=start strobe, bit1=stop strobe
                           R: bit0=running
0x01   SUPER_REPEAT_LIMIT  0=infinite, N=run N complete super-cycles
0x02   SUPER_REPEAT_COUNT  R/O: super-cycles completed since last start
0x03   STATUS_EXT          R/O: bits[4:0]=seq_pos, bit5=prefetch_active, bit6=active_bank, bit7=running
0x04   TIMER_SNAPSHOT      R/O: timer value latched at read
0x05   SEQ_LEN             Number of valid sequence entries (1..32)
0x06   CONFIG_BRAM_ADDR    Write to set BRAM access pointer (word address)
0x07   CONFIG_BRAM_DATA    R/W: access BRAM[bram_addr], auto-increments bram_addr

0x10-0x2F   SEQ_TYPE[0..31]    Cycle type index for each super-cycle position
0x30-0x4F   SEQ_COUNT[0..31]   Repeat count for each super-cycle position
```

---

## BRAM Layout

- **Size**: 2048 × 32-bit (uses 8 of 553 M10K blocks on Cyclone V, ~1%)
- **Block size**: 128 words per cycle type (power-of-2 for easy Python addressing)
- **Base address for cycle type N**: `N * 128`
- **Port A**: Avalon-MM read/write (Python config); **Port B**: hardware prefetch read-only
- Cyclone V M10K supports true dual-port with independent addresses — no arbitration needed

Within each 128-word block:
```
Offset   Contents
------   --------
+0       seq_limit
+1..+32  rp_start[0..15] / rp_dur[0..15]   (interleaved: start, dur, start, dur, ...)
+33..+64 ro_start[0..15] / ro_dur[0..15]
+65..+96 mw_start[0..15] / mw_dur[0..15]
+97      sync_start
+98      sync_dur                            (0 = sync disabled for this cycle)
+99      mk0_start
+100     mk0_dur                             (0 = marker disabled for this cycle)
+101     mk1_start
+102     mk1_dur
+103     mk2_start
+104     mk2_dur
+105..+127  (reserved)
```

**Slot disable convention**: `duration = 0` disables a slot (no output). Applies to all channels.

---

## RTL State Machine

### States and Registers

```
States: IDLE, STARTUP (initial load), RUNNING

Key registers:
  active_bank [1 bit]    -- which config bank drives comparators (0=A, 1=B)
  prefetch_active [1 bit]-- shadow bank load in progress
  load_ptr [7 bits]      -- 0..WORDS_PER_CYCLE+1, tracks BRAM read pipeline
  prefetch_type [3 bits] -- cycle type currently being loaded into shadow bank
  seq_pos [5 bits]       -- current position in SEQ_TYPE[]/SEQ_COUNT[] arrays
  inner_count [31 bits]  -- repetitions completed of current step
  timer [31 bits]        -- clock cycles elapsed in current cycle
  super_repeat_count     -- super-cycles completed
```

### Config Bank Storage

```verilog
// Two register banks; both always present as flip-flops
reg [31:0] cfg [0:1][0:WORDS_PER_CYCLE-1];
// active bank drives comparators: cfg[active_bank][i]
// shadow bank receives prefetch: cfg[~active_bank][i]
```

The BRAM is dual-port (Cyclone V M10K supports this):
- **Port A**: Avalon-MM read/write — Python configuration access
- **Port B**: Hardware prefetch read-only port — used by the loader

### State Transitions

```
IDLE  --[start_trigger]-->  STARTUP
        load_ptr=0, prefetch_type=SEQ_TYPE[0]
        begin reading BRAM[SEQ_TYPE[0]*128 + 0] on Port B

STARTUP --[load_ptr == WORDS_PER_CYCLE]--> RUNNING
          active_bank <= ~active_bank  (loaded bank becomes active)
          seq_pos=0, inner_count=0, timer=0
          schedule_prefetch(next_step_type)  -- start loading step 1 immediately

RUNNING: timer increments each clock
         prefetch runs in background (if prefetch_active):
           load_ptr++
           cfg[~active_bank][load_ptr-1] <= bram_b_dout  (1-cycle BRAM latency)
           if load_ptr == WORDS_PER_CYCLE+1: prefetch_active <= 0

RUNNING --[timer >= seq_limit - 1]-->

  Case A: inner_count + 1 < SEQ_COUNT[seq_pos]
          -- repeat same cycle type, no bank flip needed
          inner_count++, timer=0
          -- shadow bank already has the next-different step loading
          (no action on prefetch)

  Case B: advancing to next step (last repeat of current step)
          if prefetch_active: STALL until prefetch_active==0  (edge case only)
          active_bank <= ~active_bank  (swap: prefetched config is now live)
          timer=0

          if seq_pos + 1 < SEQ_LEN:
              seq_pos++, inner_count=0
          elif more super-cycles remain:
              super_repeat_count++, seq_pos=0, inner_count=0
          else:
              all outputs deasserted → IDLE

          schedule_prefetch(next_step_type)  -- start loading what comes after this

RUNNING --[stop_req]--> IDLE (all outputs deasserted immediately)
```

### schedule_prefetch(next_type)

Called at the start of each new step. Computes what the step *after* the current one will be (looking one step further ahead), and starts loading that cycle type into the shadow bank. This ensures the shadow is ready by the time the current step's last repetition ends.

```
next_next_pos = compute_next_seq_pos(seq_pos, inner_count, seq_len, super_repeat_limit)
if next_next_pos is valid (not end-of-sequence with no more super-cycles):
    prefetch_type <= SEQ_TYPE[next_next_pos]
    bram_b_addr <= SEQ_TYPE[next_next_pos] * BRAM_WORDS_PER_CYCLE
    load_ptr <= 0
    prefetch_active <= 1
```

If the next-different step is the **same cycle type** as the one just loaded, the hardware can skip the BRAM read (data already correct in shadow bank). This is an optional optimization but avoids unnecessary BRAM port traffic.

### Pulse Comparators

Comparators read from the active bank — combinatorial, then registered at output:

```verilog
// Generate block per multi-slot channel (RP, RO, MW):
for s = 0..MAX_SLOTS-1:
    slot_hit[s] = (cfg[active_bank][ch_offset + s*2 + 1] != 0)       // dur != 0
               && (timer >= cfg[active_bank][ch_offset + s*2    ])    // >= start
               && (timer <  cfg[active_bank][ch_offset + s*2    ]
                           + cfg[active_bank][ch_offset + s*2 + 1])   // < start+dur
channel_active = |slot_hit   // OR-reduce across slots

// Single-slot channels (sync, each marker) — same pattern, one slot
```

All outputs registered on the clock edge (1-cycle latency, same as original design).

---

## Module Interface

```verilog
module pulse_sequencer_avalon #(
    parameter MAX_CYCLE_TYPES = 8,
    parameter MAX_SLOTS       = 16,
    parameter MAX_SEQ_LEN     = 32,
    parameter NUM_MARKERS     = 3
)(
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM (7-bit address, was 5-bit)
    input  wire [6:0]  avs_s0_address,
    input  wire        avs_s0_write,
    input  wire [31:0] avs_s0_writedata,
    input  wire        avs_s0_read,
    output reg  [31:0] avs_s0_readdata,

    // Outputs
    output reg         aom_rp_out,
    output reg         aom_ro_out,
    output reg         mw_out,        // new
    output reg         sync_out,
    output reg [2:0]   marker_out     // new
);
```

---

## Python Data Model

```python
@dataclass
class PulseSlot:
    start: int = 0
    duration: int = 0  # 0 = disabled

@dataclass
class CycleTypeDef:
    """One reusable cycle type stored in BRAM slot N."""
    seq_limit: int = 5000
    rp:   list[PulseSlot] = ...  # up to MAX_SLOTS
    ro:   list[PulseSlot] = ...
    mw:   list[PulseSlot] = ...
    sync: PulseSlot = ...        # single slot (duration=0 → disabled)
    markers: list[PulseSlot] = ... # [mk0, mk1, mk2]; duration=0 → disabled

@dataclass
class SuperCycleStep:
    cycle_type_index: int  # index into cycle_types list (0..7)
    count: int = 1         # how many times to repeat this step

@dataclass
class SequencerConfig:
    cycle_types: list[CycleTypeDef]  # library of up to 8 definitions
    sequence:    list[SuperCycleStep] # ordered steps
    super_repeat_limit: int = 0      # 0 = infinite
```

**Writing cycle type to BRAM:**
```python
BRAM_WORDS_PER_CYCLE = 128

def write_cycle_type(mem, idx: int, defn: CycleTypeDef) -> None:
    """Stream 105 words to BRAM slot idx (power-of-2 base simplifies math)."""
    words = _cycle_def_to_words(defn)  # returns list of 105 words
    write_reg(mem, ADDR_CONFIG_BRAM_ADDR, idx * BRAM_WORDS_PER_CYCLE)
    for w in words:
        write_reg(mem, ADDR_CONFIG_BRAM_DATA, w)  # auto-increments address
```

**Backward-compatible legacy shim:**
Old CLI `start SEQ_LIMIT RP_START RP_DUR RO_START RO_DUR SYNC_START [REPEATS]` maps to:
- A single cycle type definition (index 0) with one RP slot, one RO slot, sync duration=20
- `sequence = [SuperCycleStep(0, 1)]`
- `super_repeat_limit = REPEATS`

---

## Files to Change

| File | Change |
|------|--------|
| `rtl/pulse_sequencer_avalon.v` | Complete rewrite: new ports, BRAM, loader FSM, super-cycle FSM, multi-slot comparators |
| `sim/pulse_sequencer_avalon_tb.v` | Complete rewrite: 7-bit address, new test suite |
| `pulse_sequencer_control.py` | Extend: new data classes, BRAM write helpers, sequence API, legacy shim |
| Quartus Platform Designer (`.qsys`) | Change Avalon slave address width 5→7 bits; regenerate |

---

## Implementation Order

1. RTL: Update module header (ports, parameters)
2. RTL: Instantiate dual-port M10K BRAM; wire Port A to Avalon indirect-access registers (CONFIG_BRAM_ADDR/DATA)
3. RTL: Declare two config banks (`cfg[0:1][0:WORDS_PER_CYCLE-1]`), `active_bank`, `prefetch_active`, `load_ptr`
4. RTL: Implement prefetch loader (reads Port B sequentially into shadow bank; accounts for 1-cycle BRAM read latency)
5. RTL: Implement `schedule_prefetch` logic (computes next-different step, triggers loader)
6. RTL: Implement super-cycle FSM (IDLE → STARTUP → RUNNING; seq_pos, inner_count, bank flip on step advance; stall on prefetch-not-ready edge case)
7. RTL: Multi-slot comparators reading from `cfg[active_bank][...]`; single-slot sync + markers
8. RTL: Register all outputs; handle IDLE/stop deassertions
7. Quartus Platform Designer: address width 5→7 bits; regenerate
8. Testbench: rewrite with new address map; test sequence walk, per-cycle isolation, multi-slot, ratios, BRAM readback, markers, legacy behavior; explicitly verify zero dead-time between cycle types by checking output continuity across transitions; test stall behavior when seq_limit < 106 cycles
9. Python: add data classes, `_cycle_def_to_words`, BRAM write helpers
10. Python: `write_config`, `start_config` command
11. Python: update `status` to show seq_pos, active cycle type, inner_count
12. Python: legacy shim for old `start` CLI

---

## Future Extension: PLL for Finer Timing Resolution

The current design uses the board's 50 MHz clock → 20 ns per timer tick. Replacing the clock source with a PLL output gives finer resolution with minimal RTL changes.

**Target: 200 MHz → 5 ns resolution.** This is well within the Cyclone V 5CSEBA6U23I7 (speed grade I7) capability and is already below the switching time of typical AOM drivers (~30 ns rise) and MW switches (~1–5 ns), so it is the practical resolution limit for this hardware.

**What changes:**

1. **Platform Designer**: Add an `altera_pll` IP core (50 MHz in → 200 MHz out, 4× multiply). Change the pulse sequencer component's clock connection from the raw 50 MHz source to the PLL output. Enable the automatic clock-crossing bridge between the HPS Lightweight bus (50 MHz) and the component (200 MHz) — Platform Designer inserts this transparently.

2. **RTL**: No logic changes. Just update the localparam or comment documenting the clock frequency.

3. **Python**: Update the clock period constant (20 ns → 5 ns) used for converting physical time (µs) to cycle counts.

**CDC latency is not a concern** for this application. The workflow is: write all config → start FPGA pulsing (indefinitely, `super_repeat_limit=0`) → arm and run the PicoHarp timed measurement → stop the FPGA when the PicoHarp acquisition completes. The few extra clock cycles of Avalon write latency introduced by the clock-crossing bridge are irrelevant.

**If sub-nanosecond resolution is ever needed** (beyond 200 MHz): DDR output registers can toggle at 2× the clock rate (e.g. 1 ns edges at 250 MHz) for the output pins, at the cost of significant RTL rework. Not anticipated for NV center AOM/MW experiments.

---

## Future Extension: IQ Modulation for Phase-Sensitive Experiments (T2, DD)

**Motivation**: T1 and optical readout calibration only need a TTL gate on the LO (ZASW switch, driven by `mw_out`). T2 Ramsey, Hahn echo, and dynamical decoupling require phase control — an IQ mixer driven by two 14-bit DACs (DAC904 dev boards) on the I and Q inputs. The `mw_out` TTL is kept so experiments can be switched between the two hardware paths without RTL changes.

**New FPGA outputs** (added alongside existing `mw_out`):
- `dac_i[13:0]` — 14-bit parallel I channel to DAC904 #1
- `dac_q[13:0]` — 14-bit parallel Q channel to DAC904 #2
- `dac_clk` — sample clock to both DACs (driven from FPGA clock or PLL output)

Two DACs × (14 data + 1 clock) = 30 pins. Fits within one DE10-Nano GPIO header (36 I/O pins) with room to spare.

**Two-phase implementation:**

**Phase 1 — Rectangular pulses with phase control (minimal architecture change):**
Add two extra BRAM words per MW slot: `mw_i_val[s]` and `mw_q_val[s]` (14-bit values stored in the upper bits of a 32-bit word). During an active MW slot, the sequencer holds `dac_i <= mw_i_val[s]` and `dac_q <= mw_q_val[s]` constant. When no MW slot is active, both DACs output zero (or a configurable idle level).

This gives full phase control for rectangular pulses:
- X rotation (φ=0°): I=A, Q=0
- Y rotation (φ=90°): I=0, Q=A
- Arbitrary phase: I=A·cos(φ), Q=A·sin(φ), computed in Python and stored as 14-bit integers

BRAM layout change: each MW slot entry grows from 2 words (start, dur) to 4 words (start, dur, i_val, q_val). `BRAM_WORDS_PER_CYCLE` increases from 128 to 160 (still fits in 2 M10K blocks per cycle type). Python `_cycle_def_to_words` is updated accordingly. This is sufficient for T2, Hahn echo, CPMG, and XY-8 with standard hard pulses.

**Phase 2 — Arbitrary waveform output (separate AWG module):**
For shaped pulses (Gaussian, DRAG, optimal control), a separate AWG module runs alongside the pulse sequencer. It has its own waveform BRAM (e.g., 8K × 14-bit samples, holding multiple named waveforms), receives a trigger and waveform index from the pulse sequencer at the start of each MW slot, and streams samples to the DACs at the configured rate.

This is a significant standalone addition. The existing git work (`610fc05`: "working on arbitrary waveform generation for DAC") is the starting point for this module. It connects to the pulse sequencer via a simple trigger interface rather than being embedded in it, keeping the two concerns separate.

---

## Open Questions / Future Extensions

- **More markers**: NUM_MARKERS is a parameter; could be 4+ if needed
- **Marker multi-slot**: Currently markers have 1 slot per cycle type; could add more slots if needed for complex timing
- **CPMG beyond 16 pulses**: MAX_SLOTS=16 covers CPMG-16. For higher orders, a sub-sequencer (counting loop) would be more efficient than more slots.
- **Real-time sequence switching**: Currently sequence/config must be written before start. Could add double-buffering for live experiment changes.
