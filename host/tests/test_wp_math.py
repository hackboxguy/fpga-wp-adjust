import json
from pathlib import Path

import pytest

from host.wp_math import (
    XYZ,
    XyY,
    enforce_gain_limits,
    fixed_hex,
    fixed_to_gain,
    gain_to_fixed,
    gains_to_fixed,
    linear_to_code_domain_gains,
    normalize_to_headroom,
    solve_linear_gains,
    xyY_to_XYZ,
    XYZ_to_xyY,
)


ROOT = Path(__file__).resolve().parents[2]
SEED_PATH = ROOT / "examples" / "calibration" / "12-3-nq1v1-seed.json"


def test_seed_profile_gains_round_to_q4_12():
    seed = json.loads(SEED_PATH.read_text(encoding="utf-8"))

    fixed = gains_to_fixed(seed["gain_metadata"]["code_domain_float"], frac_bits=12)

    assert fixed == seed["gains"]
    assert {channel: fixed_hex(value) for channel, value in fixed.items()} == seed[
        "gain_metadata"
    ]["q_format_hex"]
    assert fixed == {"r": 0x0F1D, "g": 0x1000, "b": 0x0EC6}


def test_prd_linear_seed_converts_to_expected_code_domain_values():
    linear = {"r": 0.883, "g": 1.0, "b": 0.840}
    code = linear_to_code_domain_gains(linear, gamma=2.184)

    assert code["r"] == pytest.approx(0.9446, abs=0.001)
    assert code["g"] == pytest.approx(1.0, abs=0.0001)
    assert code["b"] == pytest.approx(0.9233, abs=0.001)
    assert gains_to_fixed(code) == {"r": 0x0F1D, "g": 0x1000, "b": 0x0EC6}


def test_fixed_point_round_half_up_and_inverse():
    assert gain_to_fixed(1.0) == 0x1000
    assert gain_to_fixed(0.5) == 0x0800
    assert gain_to_fixed(1.5) == 0x1800
    assert gain_to_fixed((100.5) / 4096.0) == 101
    assert fixed_to_gain(0x1000) == pytest.approx(1.0)
    assert fixed_hex(0x0F1D) == "0x0F1D"


def test_xyY_XYZ_round_trip():
    white = XyY(x=0.3127, y=0.3290, Y=100.0)
    xyz = xyY_to_XYZ(white)
    round_trip = XYZ_to_xyY(xyz)

    assert round_trip.x == pytest.approx(white.x)
    assert round_trip.y == pytest.approx(white.y)
    assert round_trip.Y == pytest.approx(white.Y)


def test_synthetic_rgbw_solve_and_normalize():
    red = XYZ(X=0.64, Y=0.33, Z=0.03)
    green = XYZ(X=0.30, Y=0.60, Z=0.10)
    blue = XYZ(X=0.15, Y=0.06, Z=0.79)

    gains = solve_linear_gains(
        red=red,
        green=green,
        blue=blue,
        target_xy=(0.3127, 0.3290),
        target_Y=red.Y + green.Y + blue.Y,
    )
    normalized = normalize_to_headroom(gains)

    assert set(normalized) == {"r", "g", "b"}
    assert max(normalized.values()) == pytest.approx(1.0)
    assert all(value >= 0.0 for value in normalized.values())


def test_gain_safety_limits_fail_closed():
    enforce_gain_limits({"r": 0.5, "g": 1.0, "b": 0.75})

    with pytest.raises(ValueError, match="outside allowed range"):
        enforce_gain_limits({"r": 0.49, "g": 1.0, "b": 0.75})

    with pytest.raises(ValueError, match="outside allowed range"):
        enforce_gain_limits({"r": 0.5, "g": 1.01, "b": 0.75})

    enforce_gain_limits(
        {"r": 0.5, "g": 1.01, "b": 0.75},
        allow_above_unity=True,
    )


def test_invalid_inputs_are_rejected():
    with pytest.raises(ValueError):
        xyY_to_XYZ(XyY(x=0.3, y=0.0, Y=1.0))

    with pytest.raises(ValueError):
        gains_to_fixed({"r": 1.0, "g": 1.0})

    with pytest.raises(ValueError):
        gain_to_fixed(-0.1)
