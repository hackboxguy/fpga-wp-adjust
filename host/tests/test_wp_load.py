import copy
import json
import logging
from pathlib import Path

import pytest

from host.wp_load import (
    apply_profile,
    load_profile,
    main,
    make_dry_run_registers,
    make_mock_registers,
    validate_profile,
)
from host.wp_registers import MockWpAdjustBackend, Register, WpAdjustRegisters, transaction_summary


ROOT = Path(__file__).resolve().parents[2]
SEED_PATH = ROOT / "examples" / "calibration" / "12-3-nq1v1-seed.json"


def _seed_profile():
    return json.loads(SEED_PATH.read_text(encoding="utf-8"))


class AutoConsumeBackend(MockWpAdjustBackend):
    def __init__(self):
        super().__init__()
        self.pending_status_reads = 0

    def read16(self, addr: int) -> int:
        if addr == Register.STATUS and self.commit_pending:
            self.pending_status_reads += 1
            if self.pending_status_reads >= 2:
                self.consume_commit()
        return super().read16(addr)


def test_load_profile_validates_committed_seed():
    profile = load_profile(SEED_PATH)

    assert profile["gains"] == {"r": 3865, "g": 4096, "b": 3779}


def test_validate_profile_rejects_missing_gains():
    profile = _seed_profile()
    del profile["gains"]

    with pytest.raises(Exception):
        validate_profile(profile)


def test_dry_run_loader_emits_expected_logical_sequence():
    regs = make_dry_run_registers()
    result = apply_profile(regs, _seed_profile())

    assert result.state == "commit_status_unknown"
    assert transaction_summary(result.transactions) == [
        ("read", Register.ID, 0x57A1),
        ("read", Register.VERSION, 0x0113),
        ("read", Register.STATUS, 0x0C00),
        ("read", Register.STATUS, 0x0C00),
        ("write", Register.R_GAIN_SHADOW, 0x0F19),
        ("write", Register.G_GAIN_SHADOW, 0x1000),
        ("write", Register.B_GAIN_SHADOW, 0x0EC3),
        ("write", Register.R_OFFSET_SHADOW, 0),
        ("write", Register.G_OFFSET_SHADOW, 0),
        ("write", Register.B_OFFSET_SHADOW, 0),
        ("write", Register.CONTROL_SHADOW, 1),
        ("read", Register.R_GAIN_SHADOW, 0x0F19),
        ("read", Register.G_GAIN_SHADOW, 0x1000),
        ("read", Register.B_GAIN_SHADOW, 0x0EC3),
        ("read", Register.R_OFFSET_SHADOW, 0),
        ("read", Register.G_OFFSET_SHADOW, 0),
        ("read", Register.B_OFFSET_SHADOW, 0),
        ("read", Register.CONTROL_SHADOW, 1),
        ("write", Register.COMMIT, 0xCA1B),
        ("read", Register.STATUS, 0x0C00),
    ]


def test_mock_loader_reports_pending_until_video_and_latches_on_vsync():
    regs = make_mock_registers()
    result = apply_profile(regs, _seed_profile())

    assert result.state == "pending_until_video"
    assert result.status.commit_pending
    assert regs.read(Register.R_GAIN_ACTIVE) == 0x1000

    regs.backend.consume_commit()

    assert regs.read(Register.R_GAIN_ACTIVE) == 0x0F19
    assert regs.read(Register.G_GAIN_ACTIVE) == 0x1000
    assert regs.read(Register.B_GAIN_ACTIVE) == 0x0EC3
    assert regs.read_status().commit_consumed


def test_loader_polls_until_commit_consumed():
    regs = WpAdjustRegisters(AutoConsumeBackend())

    result = apply_profile(
        regs,
        _seed_profile(),
        timeout_sec=0.1,
        poll_interval_sec=0,
        sleep_fn=lambda _seconds: None,
    )

    assert result.state == "committed"
    assert regs.read(Register.R_GAIN_ACTIVE) == 0x0F19
    assert regs.read_status().commit_consumed


def test_strict_commit_rejects_pending_without_vsync():
    regs = make_mock_registers()

    with pytest.raises(TimeoutError, match="video/vsync"):
        apply_profile(regs, _seed_profile(), allow_pending_until_video=False)


def test_loader_refuses_to_start_when_commit_pending():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)
    backend.commit_pending = True

    with pytest.raises(RuntimeError, match="already pending"):
        apply_profile(regs, _seed_profile())


def test_loader_rejects_frac_bits_mismatch():
    regs = WpAdjustRegisters(MockWpAdjustBackend(frac_bits=14))

    with pytest.raises(RuntimeError, match="FRAC_BITS"):
        apply_profile(regs, _seed_profile())


def test_offsets_enabled_are_loaded_from_profile():
    profile = copy.deepcopy(_seed_profile())
    profile["offsets"] = {"enabled": True, "r": -20, "g": 0, "b": 10}
    regs = make_mock_registers()

    result = apply_profile(regs, profile)

    assert result.state == "pending_until_video"
    regs.backend.consume_commit()
    assert regs.read(Register.CONTROL_ACTIVE) == 0x0003
    assert regs.read(Register.R_OFFSET_ACTIVE) == 0xFFEC
    assert regs.read(Register.B_OFFSET_ACTIVE) == 0x000A


def test_loader_rejects_gains_outside_boot_safe_window():
    profile = copy.deepcopy(_seed_profile())
    profile["gains"]["g"] = 0
    regs = make_mock_registers()

    with pytest.raises(ValueError, match="outside boot-safe window"):
        apply_profile(regs, profile)

    assert regs.backend.transactions == []


def test_loader_rejects_above_unity_gains_by_default():
    profile = copy.deepcopy(_seed_profile())
    profile["gains"]["r"] = 0x1001

    with pytest.raises(ValueError, match="outside boot-safe window"):
        apply_profile(make_mock_registers(), profile)


def test_loader_accepts_out_of_range_gains_with_explicit_override():
    profile = copy.deepcopy(_seed_profile())
    profile["gains"]["r"] = 0x1800
    regs = make_mock_registers()

    result = apply_profile(regs, profile, allow_out_of_range_gains=True)

    assert result.state == "pending_until_video"
    assert regs.read(Register.R_GAIN_SHADOW) == 0x1800


def test_loader_accepts_window_boundary_gains():
    profile = copy.deepcopy(_seed_profile())
    profile["gains"] = {"r": 0x0400, "g": 0x1000, "b": 0x1000}

    result = apply_profile(make_mock_registers(), profile)

    assert result.state == "pending_until_video"


def test_validate_profile_rejects_invalid_created_utc():
    profile = _seed_profile()
    profile["created_utc"] = "not-a-timestamp"

    with pytest.raises(Exception):
        validate_profile(profile)


def test_cli_out_of_range_gains_return_controlled_failure(tmp_path, caplog):
    caplog.set_level(logging.ERROR)
    profile = _seed_profile()
    profile["gains"]["b"] = 0
    bad_profile = tmp_path / "zero-gain.json"
    bad_profile.write_text(json.dumps(profile), encoding="utf-8")

    rc = main(["--cal", str(bad_profile), "--dry-run"])

    assert rc == 3
    assert "outside boot-safe window" in caplog.text


def test_cli_allow_out_of_range_gains_flag(tmp_path, caplog):
    caplog.set_level(logging.INFO)
    profile = _seed_profile()
    profile["gains"]["b"] = 0x1400
    boosted = tmp_path / "boosted.json"
    boosted.write_text(json.dumps(profile), encoding="utf-8")

    rc = main(["--cal", str(boosted), "--dry-run", "--allow-out-of-range-gains"])

    assert rc == 0
    assert "write 0x03 0x1400" in caplog.text


def test_cli_dry_run_logs_state_and_transactions(caplog):
    caplog.set_level(logging.INFO)

    rc = main(["--cal", str(SEED_PATH), "--backend", "dry-run"])

    assert rc == 0
    assert "state=commit_status_unknown" in caplog.text
    assert "write 0x01 0x0F19" in caplog.text
    assert "write 0x7E 0xCA1B" in caplog.text


def test_cli_missing_calibration_returns_controlled_failure(tmp_path, caplog):
    caplog.set_level(logging.WARNING)

    rc = main(["--cal", str(tmp_path / "missing.json"), "--dry-run"])

    assert rc == 2
    assert "not applying calibration" in caplog.text


def test_cli_invalid_json_returns_controlled_failure(tmp_path, caplog):
    caplog.set_level(logging.ERROR)
    bad_json = tmp_path / "bad.json"
    bad_json.write_text("{not-json", encoding="utf-8")

    rc = main(["--cal", str(bad_json), "--dry-run"])

    assert rc == 3
    assert "invalid calibration" in caplog.text


def test_cli_schema_invalid_profile_returns_controlled_failure(tmp_path, caplog):
    caplog.set_level(logging.ERROR)
    bad_profile = tmp_path / "schema-invalid.json"
    profile = _seed_profile()
    del profile["gains"]
    bad_profile.write_text(json.dumps(profile), encoding="utf-8")

    rc = main(["--cal", str(bad_profile), "--dry-run"])

    assert rc == 3
    assert "invalid calibration" in caplog.text
