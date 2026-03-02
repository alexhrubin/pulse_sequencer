#!/usr/bin/env python3
"""
sim/run_sim.py — JSON → Verilog stimulus → iverilog/vvp → Plotly HTML

Usage:
    uv run python sim/run_sim.py <config.json> [--out timing.html] [--clock-mhz 50]

Steps:
  1. Parse the JSON config (new format) into an FPGAConfig, then into a
     SequencerConfig (using the HPS control script data model).
  2. Generate sim/generated_stimulus.v — a Verilog task that writes all
     BRAM words and sequence registers, plus a TIMEOUT_CYCLES localparam.
  3. Compile:  iverilog -g2005 sim/supercycle_tb.v rtl/pulse_sequencer_avalon.v
  4. Simulate: vvp → produces sim/tb_output.csv
  5. Read CSV and generate an interactive Plotly HTML timing diagram.
  6. Open the HTML in the default browser.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import webbrowser

# ---------------------------------------------------------------------------
# Path setup — project root is one level up from sim/
# ---------------------------------------------------------------------------
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _ROOT)

from sequencer.api import FPGAConfig
from pulse_sequencer_control import (
    _parse_new_json,
    BRAM_WORDS_PER_CYCLE,
    WORDS_PER_CYCLE,
    REG_SEQ_LEN,
    REG_BRAM_ADDR,
    REG_BRAM_DATA,
    REG_SEQ_TYPE_BASE,
    REG_SEQ_CNT_BASE,
)

try:
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
except ImportError:
    sys.exit("plotly is required: uv add plotly  (or  pip install plotly)")

# Reuse waveform helpers from the main visualiser
from plot_sequence import (
    _rgba,
    CHANNELS,
    CH_SPACING,
    CH_HEIGHT,
    CT_COLORS,
    add_channel_traces,
    configure_waveform_axes,
    _add_sequence_strip,
)

# ---------------------------------------------------------------------------
# CSV column name ↔ CHANNELS key mappings
# ---------------------------------------------------------------------------
_COL_TO_CH_KEY = {
    "rp":   "rp",
    "ro":   "ro",
    "mw":   "mw",
    "veto": "veto",
    "sync": "sync",
    "mk0":  "marker0",
    "mk1":  "marker1",
    "mk2":  "marker2",
}
_CH_KEY_TO_COL = {v: k for k, v in _COL_TO_CH_KEY.items()}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SIM_DIR      = os.path.join(_ROOT, "sim")
RTL_FILE     = os.path.join(_ROOT, "rtl", "pulse_sequencer_avalon.v")
TB_FILE      = os.path.join(SIM_DIR, "supercycle_tb.v")
STIMULUS_FILE= os.path.join(SIM_DIR, "generated_stimulus.v")
SIM_BIN      = os.path.join(SIM_DIR, "supercycle_sim")
CSV_FILE     = os.path.join(SIM_DIR, "tb_output.csv")

# Extra clock cycles of margin appended after the expected supercycle end
TIMEOUT_MARGIN = 200


# ---------------------------------------------------------------------------
# Stimulus generation
# ---------------------------------------------------------------------------

def generate_stimulus(seq_cfg, startup_cycles: int, running_cycles: int) -> str:
    """
    Return a Verilog snippet that defines:
      - localparam STARTUP_CYCLES  (wait this many clocks after start before logging)
      - localparam RUNNING_CYCLES  (log this many clocks = one supercycle + margin)
      - task apply_config  (Avalon-MM writes for BRAM + sequence regs)
    """
    lines: list[str] = []
    lines.append(f"localparam STARTUP_CYCLES = {startup_cycles};")
    lines.append(f"localparam RUNNING_CYCLES = {running_cycles};")
    lines.append("")
    lines.append("task apply_config;")
    lines.append("integer _i;")
    lines.append("begin")

    # Write seq_len
    lines.append(f"    write_reg(7'h{REG_SEQ_LEN:02x}, 32'd{len(seq_cfg.sequence)});")

    # Write each cycle type's BRAM block
    for idx, ct in enumerate(seq_cfg.cycle_types):
        base  = idx * BRAM_WORDS_PER_CYCLE
        words = ct.to_words()
        lines.append(f"    // Cycle type {idx}  (BRAM base = {base})")
        lines.append(f"    write_reg(7'h{REG_BRAM_ADDR:02x}, 32'd{base});")
        for w in words:
            lines.append(f"    write_reg(7'h{REG_BRAM_DATA:02x}, 32'd{w & 0xFFFF_FFFF});")

    # Write sequence steps
    for j, step in enumerate(seq_cfg.sequence):
        lines.append(
            f"    write_reg(7'h{(REG_SEQ_TYPE_BASE + j):02x}, 32'd{step.cycle_type_index});"
        )
        lines.append(
            f"    write_reg(7'h{(REG_SEQ_CNT_BASE  + j):02x}, 32'd{step.count});"
        )

    lines.append("end")
    lines.append("endtask")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

def supercycle_duration(seq_cfg) -> int:
    """Total clock cycles for one complete supercycle."""
    return sum(
        seq_cfg.cycle_types[step.cycle_type_index].seq_limit * step.count
        for step in seq_cfg.sequence
    )


# ---------------------------------------------------------------------------
# CSV → Plotly helpers
# ---------------------------------------------------------------------------

def _load_csv(csv_path: str) -> tuple[list[float], dict[str, list[int]]]:
    """Read tb_output.csv and return (times_ns, signals) without any trimming."""
    times_ns: list[float] = []
    signals: dict[str, list[int]] = {
        "rp": [], "ro": [], "mw": [], "veto": [],
        "sync": [], "mk0": [], "mk1": [], "mk2": [],
    }
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            times_ns.append(float(row["time_ns"]))
            for key in signals:
                signals[key].append(int(row[key]))
    return times_ns, signals


def _series_to_pulses(
    times_ns: list[int], values: list[int], clock_ns: int = 20
) -> list[tuple[float, float]]:
    """Convert a binary time series to a list of (start_us, dur_us) intervals."""
    pulses: list[tuple[float, float]] = []
    in_pulse = False
    start_ns = 0
    for t, v in zip(times_ns, values):
        if v and not in_pulse:
            start_ns = t
            in_pulse = True
        elif not v and in_pulse:
            pulses.append((start_ns / 1000.0, (t - start_ns) / 1000.0))
            in_pulse = False
    if in_pulse and times_ns:
        end_ns = times_ns[-1] + clock_ns
        pulses.append((start_ns / 1000.0, (end_ns - start_ns) / 1000.0))
    return pulses


def build_figure(
    csv_path: str,
    seq_cfg,
    clock_mhz: float = 50.0,
) -> go.Figure:
    """Read tb_output.csv and produce a Plotly timing diagram."""

    # ── Read CSV ─────────────────────────────────────────────────────────────
    times_ns, signals = _load_csv(csv_path)

    if not times_ns:
        raise ValueError(f"CSV file is empty: {csv_path}")

    # Trim leading startup rows (all signals still 0).
    # Find the first row where any output goes active and use that as t=0,
    # so sync/marker pulses that fire at cycle-time t=0 appear at x=0 in the plot.
    all_vals = list(zip(*signals.values()))
    first_active = next((i for i, row in enumerate(all_vals) if any(row)), 0)
    times_ns = times_ns[first_active:]
    for key in signals:
        signals[key] = signals[key][first_active:]

    # Shift x-axis so t=0 is the first active sample
    t0 = times_ns[0]
    times_ns = [t - t0 for t in times_ns]

    # Use the exact supercycle duration as the plot window — don't show trailing idle
    clock_ns  = 1000.0 / clock_mhz
    sc_dur_ns = supercycle_duration(seq_cfg) * clock_ns
    period_us = sc_dur_ns / 1000.0

    # Clip data to the supercycle window
    keep = next((i for i, t in enumerate(times_ns) if t >= sc_dur_ns), len(times_ns))
    times_ns = times_ns[:keep]
    for key in signals:
        signals[key] = signals[key][:keep]

    # Hide completely-inactive channels
    active_keys = {
        _COL_TO_CH_KEY[col]
        for col, vals in signals.items()
        if any(v for v in vals)
    }
    channels = [ch for ch in CHANNELS if ch[0] in active_keys]
    n_ch = len(channels)

    # ── Build figure ──────────────────────────────────────────────────────────
    # Compute supercycle label
    sc_dur_us = supercycle_duration(seq_cfg) / clock_mhz
    n_steps   = len(seq_cfg.sequence)
    title_str = (
        f"Simulation — 1 supercycle  "
        f"({n_steps} steps, {sc_dur_us:.3f} µs)"
    )

    fig = go.Figure()
    fig.update_layout(
        title=dict(
            text=title_str,
            font=dict(size=18, family="monospace"),
            x=0.5, xanchor="center",
        ),
        height=max(400, n_ch * 60 + 200),
        plot_bgcolor="#f8f8f8",
        paper_bgcolor="#ffffff",
        # hovermode="closest",
        margin=dict(l=90, r=160, t=80, b=50),
        xaxis=dict(
            title="Time (µs)",
            range=[0, period_us],
            showgrid=True,
            gridcolor="#e4e4e4",
            showline=True,
            linecolor="#ccc",
        ),
        yaxis=dict(
            tickmode="array",
            tickvals=[(n_ch - 1 - i) * CH_SPACING + CH_HEIGHT / 2 for i in range(n_ch)],
            ticktext=[label for _, label, _ in channels],
            tickfont=dict(size=11),
            range=[-0.8, (n_ch - 1) * CH_SPACING + CH_HEIGHT + 0.8],
            showgrid=True,
            gridcolor="#e4e4e4",
            zeroline=False,
            showline=True,
            linecolor="#ccc",
        ),
        legend=dict(
            title=dict(text="Channels"),
            orientation="v",
            x=1.01, y=1.0,
            xanchor="left", yanchor="top",
            bgcolor="rgba(255,255,255,0.9)",
            bordercolor="#ccc", borderwidth=1,
            itemclick="toggle", itemdoubleclick="toggleothers",
        ),
    )

    # ── Add cycle-boundary lines ──────────────────────────────────────────────
    cursor_us = 0.0
    for step in seq_cfg.sequence:
        ct_idx = step.cycle_type_index
        dur_us = seq_cfg.cycle_types[ct_idx].seq_limit / clock_mhz
        color  = CT_COLORS[ct_idx % len(CT_COLORS)]
        for _ in range(step.count):
            fig.add_vrect(
                x0=cursor_us,
                x1=cursor_us + dur_us,
                fillcolor=_rgba(color, 0.07),
                line_width=1,
                line_color=_rgba(color, 0.40),
                annotation_text=f"CT{ct_idx}",
                annotation_position="top left",
                annotation_font_size=9,
            )
            cursor_us += dur_us

    # ── Add waveform traces ───────────────────────────────────────────────────
    pulses_by_key = {
        key: (_series_to_pulses(times_ns, signals[_CH_KEY_TO_COL[key]])
              if _CH_KEY_TO_COL.get(key) in signals else [])
        for key, *_ in channels
    }
    add_channel_traces(fig, channels, pulses_by_key, period_us, clock_mhz)

    return fig


# ---------------------------------------------------------------------------
# Per-cycle subplot figure (--per-cycle mode)
# ---------------------------------------------------------------------------

def build_figure_per_cycle(
    csv_path: str,
    seq_cfg,
    clock_mhz: float = 50.0,
) -> go.Figure:
    """
    Build one subplot per unique cycle type (using actual simulation data),
    plus a super-cycle strip at the bottom — mirrors the plot_sequence.py layout.
    """
    # ── Read & trim CSV ───────────────────────────────────────────────────────
    times_ns, signals = _load_csv(csv_path)
    if not times_ns:
        raise ValueError(f"CSV file is empty: {csv_path}")

    all_vals    = list(zip(*signals.values()))
    first_active = next((i for i, row in enumerate(all_vals) if any(row)), 0)
    times_ns = times_ns[first_active:]
    for key in signals:
        signals[key] = signals[key][first_active:]
    t0 = times_ns[0]
    times_ns = [t - t0 for t in times_ns]

    # ── Clock / timing ────────────────────────────────────────────────────────
    clock_ns   = 1000.0 / clock_mhz
    sc_dur_ns  = supercycle_duration(seq_cfg) * clock_ns
    sc_dur_us  = sc_dur_ns / 1000.0

    # ── Unique cycle types in first-appearance order ──────────────────────────
    seen: set[int] = set()
    unique_cts: list[int] = []
    for step in seq_cfg.sequence:
        if step.cycle_type_index not in seen:
            seen.add(step.cycle_type_index)
            unique_cts.append(step.cycle_type_index)

    # First occurrence start time (ns) for each unique CT
    ct_first_start_ns: dict[int, float] = {}
    cursor_ns = 0.0
    for step in seq_cfg.sequence:
        ct_idx    = step.cycle_type_index
        ct_dur_ns = seq_cfg.cycle_types[ct_idx].seq_limit * clock_ns
        if ct_idx not in ct_first_start_ns:
            ct_first_start_ns[ct_idx] = cursor_ns
        cursor_ns += ct_dur_ns * step.count

    n_ct = len(unique_cts)

    # ── Active channels (globally across whole CSV) ───────────────────────────
    active_keys = {
        _COL_TO_CH_KEY[col]
        for col, vals in signals.items()
        if any(vals)
    }
    channels = [ch for ch in CHANNELS if ch[0] in active_keys]

    # ── Subplot layout ────────────────────────────────────────────────────────
    subplot_titles = []
    for ct_idx in unique_cts:
        dur_us = seq_cfg.cycle_types[ct_idx].seq_limit / clock_mhz
        subplot_titles.append(f"<b>CT{ct_idx}</b>  —  {dur_us:.3f} µs")
    n_steps = len(seq_cfg.sequence)
    subplot_titles.append(
        f"<b>Super-cycle</b>  —  {sc_dur_us:.3f} µs total  ({n_steps} steps)"
    )

    n_rows      = n_ct + 1
    row_heights = [4.0] * n_ct + [1.0]

    fig = make_subplots(
        rows=n_rows,
        cols=1,
        shared_xaxes=False,
        subplot_titles=subplot_titles,
        row_heights=row_heights,
        vertical_spacing=0.1,
    )

    # ── Per-CT waveforms ──────────────────────────────────────────────────────
    for subplot_i, ct_idx in enumerate(unique_cts):
        row          = subplot_i + 1
        t_start_ns   = ct_first_start_ns[ct_idx]
        ct_dur_ns_i  = seq_cfg.cycle_types[ct_idx].seq_limit * clock_ns
        t_end_ns     = t_start_ns + ct_dur_ns_i
        period_us_i  = ct_dur_ns_i / 1000.0

        # Extract and normalise the time slice for this cycle
        mask         = [t_start_ns <= t < t_end_ns for t in times_ns]
        slice_times  = [t - t_start_ns for t, m in zip(times_ns, mask) if m]
        slice_sigs   = {
            k: [v for v, m in zip(vals, mask) if m]
            for k, vals in signals.items()
        }

        pulses_by_key = {
            key: (_series_to_pulses(slice_times, slice_sigs[_CH_KEY_TO_COL[key]])
                  if _CH_KEY_TO_COL.get(key) else [])
            for key, *_ in channels
        }
        add_channel_traces(
            fig, channels, pulses_by_key, period_us_i, clock_mhz,
            row=row, col=1,
            showlegend=(subplot_i == 0),
        )
        configure_waveform_axes(fig, channels, period_us_i, row=row, col=1)

    # ── Sequence strip (bottom row) ───────────────────────────────────────────
    _add_sequence_strip(
        fig,
        row=n_rows,
        sequence=[{"cycle_type_index": s.cycle_type_index, "count": s.count}
                  for s in seq_cfg.sequence],
        cycle_types=[{"seq_limit": ct.seq_limit} for ct in seq_cfg.cycle_types],
        us_per_cyc=1.0 / clock_mhz,
    )

    # ── Global layout ─────────────────────────────────────────────────────────
    fig.update_layout(
        title=dict(
            text=(
                f"Simulation (per-cycle)  —  "
                f"{n_steps} steps,  {sc_dur_us:.3f} µs"
            ),
            font=dict(size=18, family="monospace"),
            x=0.5, xanchor="center",
        ),
        height=max(600, n_ct * 300 + 200),
        plot_bgcolor="#f8f8f8",
        paper_bgcolor="#ffffff",
        hovermode="closest",
        margin=dict(l=90, r=160, t=80, b=50),
        legend=dict(
            title=dict(text="Channels"),
            orientation="v",
            x=1.01, y=1.0,
            xanchor="left", yanchor="top",
            bgcolor="rgba(255,255,255,0.9)",
            bordercolor="#ccc", borderwidth=1,
            itemclick="toggle", itemdoubleclick="toggleothers",
        ),
    )
    for ann in fig.layout.annotations:
        ann.font.size = 12

    return fig


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("config",        help="JSON config file (new format)")
    ap.add_argument("--out",         default=None,
                    help="Output HTML file  [default: <config>_sim.html]")
    ap.add_argument("--clock-mhz",   type=float, default=50.0,
                    help="FPGA clock frequency in MHz  [%(default)s]")
    ap.add_argument("--per-cycle",   action="store_true",
                    help="Per-cycle subplot view (like plot_sequence.py) instead of full supercycle")
    ap.add_argument("--no-browser",  action="store_true",
                    help="Skip opening browser")
    args = ap.parse_args()

    # ── 1. Parse config ───────────────────────────────────────────────────────
    with open(args.config) as f:
        raw = json.load(f)

    if "cycle_time" not in raw:
        sys.exit("Error: config must use the new format (requires 'cycle_time' key).")

    fpga_cfg = FPGAConfig.from_json(raw)
    seq_cfg  = _parse_new_json(fpga_cfg.to_hps_config())

    # ── 2. Generate Verilog stimulus ──────────────────────────────────────────
    # STARTUP_CYCLES: wait after start before logging.
    # Skip most of the BRAM prefetch but start logging a bit early so the
    # Python trimmer can find the exact start of the first RUNNING cycle.
    startup_cycles = WORDS_PER_CYCLE - 10   # ~127 cycles — lands ~20 cycles before outputs
    sc_cycles      = supercycle_duration(seq_cfg)
    running_cycles = sc_cycles + TIMEOUT_MARGIN   # log one supercycle + small buffer

    stimulus = generate_stimulus(seq_cfg, startup_cycles, running_cycles)
    with open(STIMULUS_FILE, "w") as f:
        f.write(stimulus)
    print(f"Generated {STIMULUS_FILE}  ({len(stimulus.splitlines())} lines)")
    print(f"  startup skip   : {startup_cycles} cycles  ({startup_cycles*20/1e3:.1f} µs)")
    print(f"  supercycle     : {sc_cycles} cycles  ({sc_cycles/args.clock_mhz:.3f} µs)")
    print(f"  log window     : {running_cycles} cycles  ({running_cycles*20/1e3:.1f} µs)")

    # ── 3. Compile ────────────────────────────────────────────────────────────
    compile_cmd = [
        "iverilog", "-g2005",
        "-I", SIM_DIR,   # allow `include "generated_stimulus.v"` to resolve
        "-o", SIM_BIN,
        TB_FILE,
        RTL_FILE,
    ]
    print(f"\nCompiling: {' '.join(compile_cmd)}")
    result = subprocess.run(compile_cmd, cwd=_ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Compilation failed:\n{result.stderr}")
    print("Compilation OK.")

    # ── 4. Simulate ───────────────────────────────────────────────────────────
    print(f"Running:   vvp {SIM_BIN}")
    result = subprocess.run(
        ["vvp", SIM_BIN],
        cwd=_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"Simulation failed:\n{result.stderr}\n{result.stdout}")
    if result.stdout.strip():
        print(result.stdout.strip())
    print(f"Simulation complete. CSV: {CSV_FILE}")

    # ── 5. Build Plotly figure ────────────────────────────────────────────────
    if args.per_cycle:
        fig = build_figure_per_cycle(CSV_FILE, seq_cfg, clock_mhz=args.clock_mhz)
    else:
        fig = build_figure(CSV_FILE, seq_cfg, clock_mhz=args.clock_mhz)

    if args.out:
        out_path = args.out
    else:
        base     = os.path.splitext(os.path.abspath(args.config))[0]
        suffix   = "_sim_percycle.html" if args.per_cycle else "_sim.html"
        out_path = base + suffix

    fig.write_html(out_path, include_plotlyjs="cdn")
    print(f"Saved  → {out_path}")

    # ── 6. Open browser ───────────────────────────────────────────────────────
    if not args.no_browser:
        webbrowser.open(f"file://{os.path.abspath(out_path)}")


if __name__ == "__main__":
    main()
