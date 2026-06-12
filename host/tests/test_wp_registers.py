import pytest

from host.wp_registers import (
    COMMIT_MAGIC,
    DEFAULTS_MAGIC,
    DryRunBackend,
    MockWpAdjustBackend,
    Register,
    Transaction,
    WpAdjustRegisters,
    transaction_summary,
)


SEED_GAINS = {"r": 0x0F19, "g": 0x1000, "b": 0x0EC3}


def test_probe_reads_identity_version_and_frac_bits():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    status = regs.probe()

    assert status.frac_bits == 12
    assert not status.commit_pending
    assert transaction_summary(backend.transactions) == [
        ("read", Register.ID, 0x57A1),
        ("read", Register.VERSION, 0x0113),
        ("read", Register.STATUS, 0x0C00),
    ]


def test_probe_accepts_same_major_version_revision_bump():
    backend = DryRunBackend(
        {
            Register.ID: 0x57A1,
            Register.VERSION: 0x0114,
            Register.STATUS: 0x0C00,
        }
    )
    regs = WpAdjustRegisters(backend)

    assert regs.probe().frac_bits == 12


def test_write_calibration_uses_shadow_then_commit_without_touching_active():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_calibration(SEED_GAINS)

    assert regs.read(Register.R_GAIN_ACTIVE) == 0x1000
    assert regs.read_status().commit_pending

    backend.consume_commit()

    status = regs.read_status()
    assert not status.commit_pending
    assert status.commit_consumed
    assert status.active_enable
    assert regs.read(Register.R_GAIN_ACTIVE) == SEED_GAINS["r"]
    assert regs.read(Register.G_GAIN_ACTIVE) == SEED_GAINS["g"]
    assert regs.read(Register.B_GAIN_ACTIVE) == SEED_GAINS["b"]


def test_refuses_shadow_writes_while_commit_pending():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_calibration(SEED_GAINS)

    with pytest.raises(RuntimeError, match="commit is pending"):
        regs.write_calibration(SEED_GAINS)


def test_cancel_commit_clears_pending_and_preserves_registers():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_calibration(SEED_GAINS)
    assert regs.read_status().commit_pending

    regs.cancel_commit()

    status = regs.read_status()
    assert not status.commit_pending
    assert not status.commit_consumed
    assert regs.read(Register.R_GAIN_SHADOW) == SEED_GAINS["r"]
    assert regs.read(Register.R_GAIN_ACTIVE) == 0x1000

    backend.consume_commit()  # a vsync after cancel must not latch anything
    assert regs.read(Register.R_GAIN_ACTIVE) == 0x1000

    # Re-arming commits the preserved shadow values.
    regs.commit()
    backend.consume_commit()
    assert regs.read(Register.R_GAIN_ACTIVE) == SEED_GAINS["r"]


def test_defaults_restores_passthrough_and_cancels_pending_commit():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_calibration(SEED_GAINS)
    assert regs.read_status().commit_pending

    regs.defaults()

    status = regs.read_status()
    assert not status.commit_pending
    assert not status.commit_consumed
    assert not status.active_enable
    assert regs.read(Register.R_GAIN_ACTIVE) == 0x1000
    assert regs.read(Register.G_GAIN_ACTIVE) == 0x1000
    assert regs.read(Register.B_GAIN_ACTIVE) == 0x1000


def test_negative_offsets_are_encoded_as_unsigned_16_bit_values():
    backend = MockWpAdjustBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_shadow_offsets({"r": -20, "g": 0, "b": 10})

    assert regs.read(Register.R_OFFSET_SHADOW) == 0xFFEC
    assert regs.read(Register.G_OFFSET_SHADOW) == 0x0000
    assert regs.read(Register.B_OFFSET_SHADOW) == 0x000A


def test_dry_run_backend_records_expected_calibration_sequence():
    reads = {
        Register.STATUS: 0x0C00,
    }
    backend = DryRunBackend(reads=reads)
    regs = WpAdjustRegisters(backend)

    regs.write_calibration(SEED_GAINS)

    assert transaction_summary(backend.transactions) == [
        ("read", Register.STATUS, 0x0C00),
        ("write", Register.R_GAIN_SHADOW, SEED_GAINS["r"]),
        ("write", Register.G_GAIN_SHADOW, SEED_GAINS["g"]),
        ("write", Register.B_GAIN_SHADOW, SEED_GAINS["b"]),
        ("write", Register.R_OFFSET_SHADOW, 0),
        ("write", Register.G_OFFSET_SHADOW, 0),
        ("write", Register.B_OFFSET_SHADOW, 0),
        ("write", Register.CONTROL_SHADOW, 1),
        ("read", Register.R_GAIN_SHADOW, SEED_GAINS["r"]),
        ("read", Register.G_GAIN_SHADOW, SEED_GAINS["g"]),
        ("read", Register.B_GAIN_SHADOW, SEED_GAINS["b"]),
        ("read", Register.R_OFFSET_SHADOW, 0),
        ("read", Register.G_OFFSET_SHADOW, 0),
        ("read", Register.B_OFFSET_SHADOW, 0),
        ("read", Register.CONTROL_SHADOW, 1),
        ("write", Register.COMMIT, COMMIT_MAGIC),
    ]


def test_dry_run_backend_echoes_writes_for_readback():
    backend = DryRunBackend(reads={Register.STATUS: 0x0C00})

    assert backend.read16(Register.R_GAIN_SHADOW) == 0
    backend.write16(Register.R_GAIN_SHADOW, 0x0F19)
    assert backend.read16(Register.R_GAIN_SHADOW) == 0x0F19
    assert backend.read16(Register.STATUS) == 0x0C00


class _DroppedWriteBackend(MockWpAdjustBackend):
    """Simulates a transport that silently loses one shadow write."""

    def write16(self, addr: int, value: int) -> None:
        if addr == Register.G_GAIN_SHADOW:
            self.transactions.append(Transaction("write", addr, value))
            return
        super().write16(addr, value)


def test_write_calibration_detects_lost_shadow_write_before_commit():
    # The dropped channel must differ from the mock's reset default (unity)
    # for the loss to be observable.
    gains = {"r": 0x0F19, "g": 0x0F80, "b": 0x0EC3}
    backend = _DroppedWriteBackend()
    regs = WpAdjustRegisters(backend)

    with pytest.raises(RuntimeError, match="shadow readback mismatch at G_GAIN_SHADOW"):
        regs.write_calibration(gains)

    assert not backend.commit_pending
    assert ("write", Register.COMMIT, COMMIT_MAGIC) not in transaction_summary(
        backend.transactions
    )


def test_write_calibration_verify_can_be_disabled():
    backend = _DroppedWriteBackend()
    regs = WpAdjustRegisters(backend)

    regs.write_calibration({"r": 0x0F19, "g": 0x0F80, "b": 0x0EC3}, verify=False)

    assert backend.commit_pending


def test_dry_run_defaults_records_magic_write():
    backend = DryRunBackend()
    regs = WpAdjustRegisters(backend)

    regs.defaults()

    assert transaction_summary(backend.transactions) == [
        ("write", Register.DEFAULTS, DEFAULTS_MAGIC),
    ]


def test_probe_rejects_wrong_id_version_or_frac_bits():
    regs = WpAdjustRegisters(DryRunBackend({Register.ID: 0x0000}))
    with pytest.raises(RuntimeError, match="unexpected wp_adjust ID"):
        regs.probe()

    regs = WpAdjustRegisters(
        DryRunBackend({Register.ID: 0x57A1, Register.VERSION: 0x0200})
    )
    with pytest.raises(RuntimeError, match="unsupported wp_adjust register-map major"):
        regs.probe()

    regs = WpAdjustRegisters(
        DryRunBackend(
            {
                Register.ID: 0x57A1,
                Register.VERSION: 0x0112,
                Register.STATUS: 0x0E00,
            }
        )
    )
    with pytest.raises(RuntimeError, match="unexpected wp_adjust FRAC_BITS"):
        regs.probe()


def test_invalid_values_fail_closed():
    regs = WpAdjustRegisters(MockWpAdjustBackend())

    with pytest.raises(ValueError):
        regs.write_shadow_gains({"r": 0x1000, "g": 0x1000})

    with pytest.raises(ValueError):
        regs.write_shadow_offsets({"r": -32769, "g": 0, "b": 0})

    with pytest.raises(ValueError):
        regs.write(Register.R_GAIN_SHADOW, 0x1_0000)
