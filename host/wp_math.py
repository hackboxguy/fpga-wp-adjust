"""White-point calibration math for the scalar wp_adjust block.

The FPGA v1 datapath applies gains directly to encoded pixel codes. Helpers in
this module keep the host-side calculations explicit: solve or seed gains in
linear light, convert them to code-domain gains with a display gamma estimate,
then round to the FPGA fixed-point format.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, Iterable, Mapping


ChannelGains = Dict[str, float]
FixedGains = Dict[str, int]


@dataclass(frozen=True)
class XyY:
    x: float
    y: float
    Y: float


@dataclass(frozen=True)
class XYZ:
    X: float
    Y: float
    Z: float


@dataclass(frozen=True)
class SeedGains:
    linear: ChannelGains
    code_domain: ChannelGains
    fixed: FixedGains


def xyY_to_XYZ(value: XyY) -> XYZ:
    """Convert CIE xyY to XYZ."""

    _require_finite("x", value.x)
    _require_finite("y", value.y)
    _require_finite("Y", value.Y)
    if value.y <= 0.0:
        raise ValueError("xyY y must be greater than zero")
    if value.x < 0.0 or value.y < 0.0 or value.x + value.y > 1.0:
        raise ValueError("xy chromaticity is outside the valid triangle")
    if value.Y < 0.0:
        raise ValueError("luminance Y must be non-negative")

    X = (value.x * value.Y) / value.y
    Z = ((1.0 - value.x - value.y) * value.Y) / value.y
    return XYZ(X=X, Y=value.Y, Z=Z)


def XYZ_to_xyY(value: XYZ) -> XyY:
    """Convert CIE XYZ to xyY."""

    _require_finite("X", value.X)
    _require_finite("Y", value.Y)
    _require_finite("Z", value.Z)
    total = value.X + value.Y + value.Z
    if total <= 0.0:
        raise ValueError("XYZ sum must be greater than zero")
    return XyY(x=value.X / total, y=value.Y / total, Y=value.Y)


def solve_linear_gains(
    red: XYZ,
    green: XYZ,
    blue: XYZ,
    target_xy: tuple[float, float],
    target_Y: float | None = None,
) -> ChannelGains:
    """Solve per-channel linear-light gains for a target white.

    The RGB XYZ values are treated as full-code channel measurements. If
    ``target_Y`` is omitted, the solver preserves the luminance of their sum.
    """

    measured_white_Y = red.Y + green.Y + blue.Y
    if target_Y is None:
        target_Y = measured_white_Y
    _require_finite("target_Y", target_Y)
    if target_Y <= 0.0:
        raise ValueError("target_Y must be greater than zero")

    target = xyY_to_XYZ(XyY(x=target_xy[0], y=target_xy[1], Y=target_Y))
    matrix = (
        (red.X, green.X, blue.X),
        (red.Y, green.Y, blue.Y),
        (red.Z, green.Z, blue.Z),
    )
    solved = _solve_3x3(matrix, (target.X, target.Y, target.Z))
    return {"r": solved[0], "g": solved[1], "b": solved[2]}


def normalize_to_headroom(gains: Mapping[str, float], max_gain: float = 1.0) -> ChannelGains:
    """Scale gains so the largest channel is at or below ``max_gain``."""

    _validate_channels(gains)
    _require_finite("max_gain", max_gain)
    if max_gain <= 0.0:
        raise ValueError("max_gain must be greater than zero")

    largest = max(gains.values())
    if largest <= 0.0:
        raise ValueError("at least one gain must be positive")
    scale = max_gain / largest if largest > max_gain else 1.0
    return {channel: value * scale for channel, value in gains.items()}


def linear_to_code_domain_gains(gains: Mapping[str, float], gamma: float) -> ChannelGains:
    """Convert linear-light gains to encoded-code gains for a gamma display."""

    _validate_channels(gains)
    _require_finite("gamma", gamma)
    if gamma <= 0.0:
        raise ValueError("gamma must be greater than zero")

    return {channel: value ** (1.0 / gamma) for channel, value in gains.items()}


def enforce_gain_limits(
    gains: Mapping[str, float],
    min_gain: float = 0.5,
    max_gain: float = 1.0,
    allow_above_unity: bool = False,
) -> None:
    """Raise if any gain falls outside the allowed v1 safety range."""

    _validate_channels(gains)
    _require_finite("min_gain", min_gain)
    _require_finite("max_gain", max_gain)
    if min_gain < 0.0 or max_gain <= 0.0 or min_gain > max_gain:
        raise ValueError("invalid gain limits")

    upper = math.inf if allow_above_unity else max_gain
    for channel, value in gains.items():
        if value < min_gain or value > upper:
            raise ValueError(f"{channel} gain {value:.6g} outside allowed range")


def gain_to_fixed(gain: float, frac_bits: int = 12, total_bits: int = 16) -> int:
    """Convert a non-negative gain to unsigned fixed point with half-up rounding."""

    _require_finite("gain", gain)
    _validate_fixed_format(frac_bits, total_bits)
    if gain < 0.0:
        raise ValueError("gain must be non-negative")
    raw = int(math.floor(gain * (1 << frac_bits) + 0.5))
    max_raw = (1 << total_bits) - 1
    if raw > max_raw:
        raise ValueError("gain does not fit in the selected fixed-point format")
    return raw


def fixed_to_gain(raw: int, frac_bits: int = 12, total_bits: int = 16) -> float:
    """Convert unsigned fixed-point gain to float."""

    _validate_fixed_format(frac_bits, total_bits)
    if not isinstance(raw, int) or raw < 0 or raw > (1 << total_bits) - 1:
        raise ValueError("raw fixed-point value is out of range")
    return raw / float(1 << frac_bits)


def gains_to_fixed(
    gains: Mapping[str, float],
    frac_bits: int = 12,
    total_bits: int = 16,
) -> FixedGains:
    """Convert RGB gain mapping to unsigned fixed-point integers."""

    _validate_channels(gains)
    return {
        channel: gain_to_fixed(value, frac_bits=frac_bits, total_bits=total_bits)
        for channel, value in gains.items()
    }


def compute_seed_gains(
    red: XYZ,
    green: XYZ,
    blue: XYZ,
    target_xy: tuple[float, float],
    gamma: float,
    frac_bits: int = 12,
    total_bits: int = 16,
    min_gain: float = 0.5,
    max_gain: float = 1.0,
) -> SeedGains:
    """Run the canonical v1 seed pipeline from measured RGB XYZ to fixed gains."""

    linear = normalize_to_headroom(
        solve_linear_gains(red=red, green=green, blue=blue, target_xy=target_xy),
        max_gain=max_gain,
    )
    code_domain = linear_to_code_domain_gains(linear, gamma=gamma)
    enforce_gain_limits(code_domain, min_gain=min_gain, max_gain=max_gain)
    fixed = gains_to_fixed(code_domain, frac_bits=frac_bits, total_bits=total_bits)
    return SeedGains(linear=linear, code_domain=code_domain, fixed=fixed)


def fixed_hex(raw: int, total_bits: int = 16) -> str:
    """Format an unsigned fixed-point register value as Verilog-style hex text."""

    if not isinstance(raw, int) or raw < 0 or raw > (1 << total_bits) - 1:
        raise ValueError("raw fixed-point value is out of range")
    width = max(1, (total_bits + 3) // 4)
    return f"0x{raw:0{width}X}"


def _solve_3x3(matrix: tuple[tuple[float, float, float], ...], vector: tuple[float, float, float]) -> tuple[float, float, float]:
    det = _det3(matrix)
    if abs(det) < 1e-12:
        raise ValueError("RGB primary matrix is singular")

    cols = tuple(zip(*matrix))
    out = []
    for index in range(3):
        replaced_cols = list(cols)
        replaced_cols[index] = vector
        replaced_matrix = tuple(zip(*replaced_cols))
        out.append(_det3(replaced_matrix) / det)
    return (out[0], out[1], out[2])


def _det3(m: Iterable[Iterable[float]]) -> float:
    rows = tuple(tuple(float(v) for v in row) for row in m)
    if len(rows) != 3 or any(len(row) != 3 for row in rows):
        raise ValueError("expected a 3x3 matrix")
    (a, b, c), (d, e, f), (g, h, i) = rows
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)


def _validate_channels(gains: Mapping[str, float]) -> None:
    if set(gains.keys()) != {"r", "g", "b"}:
        raise ValueError("gains must contain exactly r, g, and b")
    for channel, value in gains.items():
        _require_finite(f"{channel} gain", value)
        if value < 0.0:
            raise ValueError(f"{channel} gain must be non-negative")


def _validate_fixed_format(frac_bits: int, total_bits: int) -> None:
    if not isinstance(frac_bits, int) or not isinstance(total_bits, int):
        raise ValueError("fixed-point bit counts must be integers")
    if frac_bits < 0 or total_bits <= 0 or frac_bits >= total_bits:
        raise ValueError("invalid fixed-point format")


def _require_finite(name: str, value: float) -> None:
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
