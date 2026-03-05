#!/usr/bin/env python3
"""
plot_sequence.py — Interactive timing diagram viewer for pulse sequencer JSON configs.
Outputs an HTML file you can open in any browser.

Each channel (RP, RO, MW, Veto, Sync, Mk 0-2) is a separate digital waveform trace,
vertically separated within a per-cycle-type subplot.  A super-cycle strip at the
bottom shows how cycle types chain together.

Usage:
    python plot_sequence.py config.json
    python plot_sequence.py config.json --clock-mhz 50
    python plot_sequence.py config.json --out timing.html
    python plot_sequence.py config.json --no-sequence-strip
"""
from __future__ import annotations

import sys
import json
import argparse
import webbrowser
import os

try:
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
except ImportError:
    sys.exit("plotly is required: pip install plotly")

# ---------------------------------------------------------------------------
# Channel display order (top → bottom), short labels, and stroke colours
# ---------------------------------------------------------------------------
CHANNELS = [
    ("rp",      "RP",    "#2ca02c"),   # green  — repump / init laser
    ("ro",      "RO",    "#ff7f0e"),   # orange — readout window
    ("mw",      "MW",    "#1f77b4"),   # blue   — microwave
    ("veto",    "Veto",  "#d62728"),   # red    — PicoHarp inhibit
    ("sync",    "Sync",  "#7f7f7f"),   # grey   — sync pulse
    ("marker0", "Mk 0",  "#9467bd"),   # purple
    ("marker1", "Mk 1",  "#8c564b"),   # brown
    ("marker2", "Mk 2",  "#e377c2"),   # pink
]

# Pastel colours for cycle-type blocks in the sequence strip
CT_COLORS = [
    "#aec7e8", "#ffbb78", "#98df8a", "#ff9896",
    "#c5b0d5", "#c49c94", "#f7b6d2", "#dbdb8d",
]

CH_SPACING = 2.5    # vertical units between channel baselines
CH_HEIGHT  = 1.2    # height of the HIGH portion of each waveform


def _rgba(hex_color: str, alpha: float) -> str:
    """Convert a #rrggbb hex colour to an rgba() string with the given alpha."""
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r},{g},{b},{alpha})"


# ---------------------------------------------------------------------------
# New-format → internal-format converter
# ---------------------------------------------------------------------------

_NEW_FORMAT_RESERVED = {"cycle_time", "sync", "super_cycle", "super_cycle_repeats"}

SYNC_DURATION   = 5
MARKER_DURATION = 5


def _parse_new_format(cfg: dict) -> dict:
    """
    Convert the new JSON format (identified by top-level 'cycle_time' key)
    into the internal format that plot_config() expects:
      {cycle_types: [...], sequence: [...], super_repeat_limit: N}
    """
    cycle_time          = int(cfg["cycle_time"])
    sync                = bool(cfg.get("sync", True))
    super_cycle_steps   = cfg.get("super_cycle", [])
    super_cycle_repeats = int(cfg.get("super_cycle_repeats", 0))

    name_to_idx: dict[str, int] = {}
    cycle_types: list[dict] = []

    for step in super_cycle_steps:
        name = step["cycle"]
        if name in name_to_idx:
            continue
        raw = cfg.get(name)
        if raw is None or not isinstance(raw, dict):
            raise ValueError(f"Cycle '{name}' referenced in super_cycle but not found")

        ct: dict = {
            "_name":    name,
            "seq_limit": cycle_time,
        }

        for ch in ("rp", "ro", "mw", "veto"):
            ct[ch] = raw.get(ch, [])

        if sync:
            ct["sync"] = [0, SYNC_DURATION]

        marker_ch = raw.get("marker")
        for i in range(3):
            if marker_ch is not None and i == int(marker_ch):
                ct[f"marker{i}"] = [0, MARKER_DURATION]
            else:
                ct[f"marker{i}"] = None

        name_to_idx[name] = len(cycle_types)
        cycle_types.append(ct)

    sequence = [
        {"cycle_type_index": name_to_idx[step["cycle"]], "count": int(step.get("count", 1))}
        for step in super_cycle_steps
    ]

    return {
        "cycle_types":        cycle_types,
        "sequence":           sequence,
        "super_repeat_limit": super_cycle_repeats,
    }


# ---------------------------------------------------------------------------
# JSON parsing helpers
# ---------------------------------------------------------------------------

def _parse_slot(v) -> tuple[int, int] | None:
    """Return (start, dur) in cycles if enabled (dur > 0), else None."""
    if v is None:
        return None
    start, dur = int(v[0]), int(v[1])
    return (start, dur) if dur > 0 else None


def _gather_pulses(ct: dict) -> dict[str, list[tuple[int, int]]]:
    """Return {channel_key: [(start_cyc, dur_cyc), ...]} for one cycle type."""
    pulses: dict[str, list] = {key: [] for key, *_ in CHANNELS}

    for ch in ("rp", "ro", "mw", "veto"):
        for raw in ct.get(ch, []):
            r = _parse_slot(raw)
            if r:
                pulses[ch].append(r)

    r = _parse_slot(ct.get("sync"))
    if r:
        pulses["sync"].append(r)

    for i in range(3):
        r = _parse_slot(ct.get(f"marker{i}"))
        if r:
            pulses[f"marker{i}"].append(r)

    return pulses


# ---------------------------------------------------------------------------
# Active-channel filter
# ---------------------------------------------------------------------------

def _active_channel_keys(cycle_types: list[dict]) -> set[str]:
    """Return the set of channel keys that have at least one pulse in any cycle type."""
    active: set[str] = set()
    for ct in cycle_types:
        for key, *_ in CHANNELS:
            if _gather_pulses(ct)[key]:
                active.add(key)
    return active


# ---------------------------------------------------------------------------
# Waveform geometry
# ---------------------------------------------------------------------------

def _waveform_xy(
    pulses_us: list[tuple[float, float]],
    period_us: float,
    y_base: float,
) -> tuple[list[float], list[float]]:
    """
    Build (x, y) arrays for a digital step-function waveform suitable for
    Plotly Scatter with fill='toself'.

    Signal is LOW (y_base) at rest; goes HIGH (y_base + CH_HEIGHT) during
    each pulse.  The closed polygon fills only the active pulse regions.
    """
    x: list[float] = [0.0]
    y: list[float] = [y_base]

    for start, dur in sorted(pulses_us, key=lambda p: p[0]):
        end = start + dur
        x += [start, start,           end,              end   ]
        y += [y_base, y_base + CH_HEIGHT, y_base + CH_HEIGHT, y_base]

    x.append(period_us)
    y.append(y_base)
    return x, y


# ---------------------------------------------------------------------------
# Reusable waveform trace builders
# ---------------------------------------------------------------------------

def add_channel_traces(
    fig: go.Figure,
    channels: list,
    pulses_by_channel_us: dict,
    period_us: float,
    clock_mhz: float,
    *,
    row: int | None = None,
    col: int | None = None,
    showlegend: bool = True,
) -> None:
    """
    Add waveform traces for *channels* to *fig*.

    Each active channel gets:
      - a visual Scatter trace (fill='toself', hoverinfo='skip')
      - a dense invisible marker trace for reliable hover tooltips

    pulses_by_channel_us maps channel key → [(start_us, dur_us), ...]
    Pass row/col to target a specific make_subplots cell; omit for a plain Figure.
    """
    n_ch = len(channels)
    _pos = {"row": row, "col": col} if row is not None else {}

    for ch_idx, (key, label, color) in enumerate(channels):
        y_base    = (n_ch - 1 - ch_idx) * CH_SPACING
        pulses_us = pulses_by_channel_us.get(key, [])
        x, y      = _waveform_xy(pulses_us, period_us, y_base)

        fig.add_trace(
            go.Scatter(
                x=x, y=y,
                mode="lines",
                name=label,
                legendgroup=key,
                showlegend=showlegend,
                line=dict(color=color, width=2),
                fill="toself",
                fillcolor=_rgba(color, 0.20),
                hoverinfo="skip",
            ),
            **_pos,
        )

        if pulses_us:
            hxs, hys, htmpl = [], [], []
            for s_us, d_us in pulses_us:
                n    = max(3, min(50, round(d_us * clock_mhz / 5)))
                tmpl = (
                    f"<b>{label}</b><br>"
                    f"{s_us:.4f} → {s_us + d_us:.4f} µs"
                    f"  ({round(d_us * clock_mhz)} cyc)<extra></extra>"
                )
                for i in range(n):
                    hxs.append(s_us + (i + 0.5) * d_us / n)
                    hys.append(y_base + CH_HEIGHT / 2)
                    htmpl.append(tmpl)
            fig.add_trace(
                go.Scatter(
                    x=hxs, y=hys,
                    mode="markers",
                    marker=dict(size=8, color=_rgba(color, 0.01)),
                    hovertemplate=htmpl,
                    name=label,
                    legendgroup=key,
                    showlegend=False,
                ),
                **_pos,
            )


def configure_waveform_axes(
    fig: go.Figure,
    channels: list,
    period_us: float,
    row: int,
    col: int,
) -> None:
    """Configure y-axis labels and x-axis range for one subplot row."""
    n_ch       = len(channels)
    tick_vals  = [(n_ch - 1 - i) * CH_SPACING + CH_HEIGHT / 2 for i in range(n_ch)]
    tick_texts = [label for _, label, _ in channels]
    y_range    = [-0.8, (n_ch - 1) * CH_SPACING + CH_HEIGHT + 0.8]
    fig.update_yaxes(
        tickmode="array",
        tickvals=tick_vals,
        ticktext=tick_texts,
        tickfont=dict(size=11),
        range=y_range,
        showgrid=True,
        gridcolor="#e4e4e4",
        gridwidth=1,
        zeroline=False,
        showline=True,
        linecolor="#ccc",
        row=row,
        col=col,
    )
    fig.update_xaxes(
        title_text="Time (µs)",
        range=[0, period_us],
        showgrid=True,
        gridcolor="#e4e4e4",
        gridwidth=1,
        showline=True,
        linecolor="#ccc",
        row=row,
        col=col,
    )


# ---------------------------------------------------------------------------
# Main figure builder
# ---------------------------------------------------------------------------

def plot_config(
    cfg: dict,
    clock_mhz: float = 50.0,
    show_sequence_strip: bool = True,
    hide_inactive: bool = False,
) -> go.Figure:
    """Build and return an interactive Plotly Figure from a config dict.

    Accepts the canonical JSON format (with 'cycle_time' key) as produced by
    FPGAConfig.to_json().
    """

    # Convert from canonical JSON format to internal representation
    if "cycle_time" in cfg:
        cfg = _parse_new_format(cfg)

    us_per_cyc   = 1.0 / clock_mhz
    cycle_types  = cfg.get("cycle_types", [])
    sequence     = cfg.get("sequence",    [])
    n_ct         = len(cycle_types)

    if n_ct == 0:
        raise ValueError("No cycle_types found in config.")

    if hide_inactive:
        active_keys = _active_channel_keys(cycle_types)
        channels = [ch for ch in CHANNELS if ch[0] in active_keys]
    else:
        channels = CHANNELS

    has_strip = show_sequence_strip and bool(sequence)
    n_rows    = n_ct + (1 if has_strip else 0)

    # Row height ratios: each CT row is 4×, strip row is 1×
    row_heights = [4.0] * n_ct + ([1.0] if has_strip else [])

    # ── Subplot titles ─────────────────────────────────────────────────────
    def _ct_title(i: int, ct: dict) -> str:
        name     = ct.get("_name", f"Cycle Type {i}")
        period   = int(ct.get("seq_limit", 1)) * us_per_cyc
        n_active = sum(1 for key, *_ in CHANNELS if _gather_pulses(ct)[key])
        return f"<b>CT{i}</b>: {name}  —  {period:.3f} µs  ({n_active}/{len(CHANNELS)} channels active)"
    # note: title always reports against the full CHANNELS list regardless of hide_inactive

    subplot_titles = [_ct_title(i, ct) for i, ct in enumerate(cycle_types)]

    if has_strip:
        total_us = sum(
            int(cycle_types[s["cycle_type_index"]].get("seq_limit", 1))
            * int(s.get("count", 1))
            * us_per_cyc
            for s in sequence
        )
        repeat    = cfg.get("super_repeat_limit", 0)
        rep_str   = f"× {repeat}" if repeat else "× ∞ (infinite)"
        subplot_titles.append(
            f"<b>Super-cycle</b>  —  {total_us:.3f} µs total,  {rep_str}"
        )

    fig = make_subplots(
        rows=n_rows,
        cols=1,
        shared_xaxes=False,
        subplot_titles=subplot_titles,
        row_heights=row_heights,
        vertical_spacing=0.2,
    )

    # ── Per-cycle-type timing diagrams ─────────────────────────────────────
    for ct_idx, ct in enumerate(cycle_types):
        row       = ct_idx + 1
        seq_limit = int(ct.get("seq_limit", 1))
        period_us = seq_limit * us_per_cyc
        pulses    = _gather_pulses(ct)

        pulses_us_by_key = {
            key: [(s * us_per_cyc, d * us_per_cyc) for s, d in pulses[key]]
            for key, *_ in channels
        }
        add_channel_traces(
            fig, channels, pulses_us_by_key, period_us, clock_mhz,
            row=row, col=1,
            showlegend=(ct_idx == 0),
        )
        configure_waveform_axes(fig, channels, period_us, row=row, col=1)

    # ── Sequence timeline strip ─────────────────────────────────────────────
    if has_strip:
        _add_sequence_strip(
            fig,
            row=n_rows,
            sequence=sequence,
            cycle_types=cycle_types,
            us_per_cyc=us_per_cyc,
        )

    # ── Global layout ───────────────────────────────────────────────────────
    fig_height = max(600, n_ct * 300 + (160 if has_strip else 0) + 100)
    fig.update_layout(
        title=dict(
            text="Pulse Sequence Timing Diagram",
            font=dict(size=20, family="monospace"),
            x=0.5,
            xanchor="center",
        ),
        height=fig_height,
        legend=dict(
            title=dict(text="Channels", font=dict(size=12)),
            orientation="v",
            x=1.01,
            y=1.0,
            xanchor="left",
            yanchor="top",
            bgcolor="rgba(255,255,255,0.9)",
            bordercolor="#ccc",
            borderwidth=1,
            itemclick="toggle",
            itemdoubleclick="toggleothers",
        ),
        plot_bgcolor="#f8f8f8",
        paper_bgcolor="#ffffff",
        # hovermode="closest",
        margin=dict(l=90, r=160, t=80, b=50),
    )

    # Increase subplot title font size
    for ann in fig.layout.annotations:
        ann.font.size = 12

    return fig


# ---------------------------------------------------------------------------
# Sequence strip helper
# ---------------------------------------------------------------------------

def _add_sequence_strip(
    fig: go.Figure,
    row: int,
    sequence: list[dict],
    cycle_types: list[dict],
    us_per_cyc: float,
) -> None:
    """Draw super-cycle blocks as filled rectangles in the bottom strip row."""
    cursor   = 0.0
    seen_ct: set[int] = set()

    # Compute total duration for x-axis range
    total_us = sum(
        int(cycle_types[s["cycle_type_index"]].get("seq_limit", 1))
        * int(s.get("count", 1))
        * us_per_cyc
        for s in sequence
    )

    for step in sequence:
        ct_idx = int(step.get("cycle_type_index", 0))
        count  = int(step.get("count", 1))
        dur_us = int(cycle_types[ct_idx].get("seq_limit", 1)) * us_per_cyc
        color  = CT_COLORS[ct_idx % len(CT_COLORS)]

        for rep in range(count):
            x0, x1 = cursor, cursor + dur_us
            mid_x   = (x0 + x1) / 2

            # Filled rectangle via closed Scatter polygon
            fig.add_trace(
                go.Scatter(
                    x=[x0, x1, x1, x0, x0],
                    y=[0.05, 0.05, 0.95, 0.95, 0.05],
                    mode="lines",
                    fill="toself",
                    fillcolor=_rgba(color, 0.80),
                    line=dict(color="#555", width=1),
                    name=f"CT{ct_idx}",
                    legendgroup=f"strip_ct{ct_idx}",
                    showlegend=False,
                    hovertemplate=(
                        f"<b>CT{ct_idx}</b><br>"
                        f"start = {x0:.4f} µs<br>"
                        f"end   = {x1:.4f} µs<br>"
                        f"dur   = {dur_us:.4f} µs<extra></extra>"
                    ),
                ),
                row=row,
                col=1,
            )

            # Label text centred in the block
            fig.add_trace(
                go.Scatter(
                    x=[mid_x],
                    y=[0.5],
                    mode="text",
                    text=[f"CT{ct_idx}"],
                    textfont=dict(size=10, color="#111", family="monospace"),
                    showlegend=False,
                    hoverinfo="skip",
                ),
                row=row,
                col=1,
            )

            seen_ct.add(ct_idx)
            cursor += dur_us

    fig.update_yaxes(
        range=[0, 1],
        showticklabels=False,
        showgrid=False,
        zeroline=False,
        showline=True,
        linecolor="#ccc",
        row=row,
        col=1,
    )
    fig.update_xaxes(
        title_text="Time (µs)",
        range=[0, total_us],
        showgrid=True,
        gridcolor="#e4e4e4",
        showline=True,
        linecolor="#ccc",
        row=row,
        col=1,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("config",
                    help="SequencerConfig JSON file to visualise")
    ap.add_argument("--clock-mhz", type=float, default=50.0,
                    help="FPGA clock frequency in MHz  [%(default)s]")
    ap.add_argument("--out", default=None,
                    help="Output HTML file path (default: <config>_timing.html)")
    ap.add_argument("--no-sequence-strip", action="store_true",
                    help="Omit the super-cycle timeline strip at the bottom")
    ap.add_argument("--hide-inactive", action="store_true",
                    help="Only plot channels that have at least one pulse somewhere in the config")
    args = ap.parse_args()

    with open(args.config) as f:
        cfg = json.load(f)

    fig = plot_config(
        cfg,
        clock_mhz=args.clock_mhz,
        show_sequence_strip=not args.no_sequence_strip,
        hide_inactive=args.hide_inactive,
    )

    if args.out:
        out_path = args.out
    else:
        base     = os.path.splitext(os.path.abspath(args.config))[0]
        out_path = base + "_timing.html"

    fig.write_html(out_path, include_plotlyjs="cdn")
    print(f"Saved  → {out_path}")
    webbrowser.open(f"file://{out_path}")


if __name__ == "__main__":
    main()
