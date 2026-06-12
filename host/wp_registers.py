"""Logical register adapter for the wp_adjust scalar v1 block."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Dict, List, Optional, Protocol, Tuple


WP_ADJUST_ID = 0x57A1
WP_ADJUST_VERSION = 0x0113
WP_ADJUST_VERSION_MAJOR = WP_ADJUST_VERSION >> 8
COMMIT_MAGIC = 0xCA1B
COMMIT_CANCEL_MAGIC = 0xC0FF
DEFAULTS_MAGIC = 0xD65D
DEFAULT_FRAC_BITS = 12
UNITY_GAIN_Q4_12 = 0x1000


class Register(IntEnum):
    CONTROL_SHADOW = 0x00
    R_GAIN_SHADOW = 0x01
    G_GAIN_SHADOW = 0x02
    B_GAIN_SHADOW = 0x03
    R_OFFSET_SHADOW = 0x04
    G_OFFSET_SHADOW = 0x05
    B_OFFSET_SHADOW = 0x06
    CONTROL_ACTIVE = 0x20
    R_GAIN_ACTIVE = 0x21
    G_GAIN_ACTIVE = 0x22
    B_GAIN_ACTIVE = 0x23
    R_OFFSET_ACTIVE = 0x24
    G_OFFSET_ACTIVE = 0x25
    B_OFFSET_ACTIVE = 0x26
    ID = 0x70
    VERSION = 0x71
    STATUS = 0x72
    COMMIT = 0x7E
    DEFAULTS = 0x7F


@dataclass(frozen=True)
class Status:
    raw: int

    @property
    def commit_pending(self) -> bool:
        return bool(self.raw & 0x0001)

    @property
    def commit_consumed(self) -> bool:
        return bool(self.raw & 0x0002)

    @property
    def active_enable(self) -> bool:
        return bool(self.raw & 0x0004)

    @property
    def active_offset_enable(self) -> bool:
        return bool(self.raw & 0x0008)

    @property
    def frac_bits(self) -> int:
        return (self.raw >> 8) & 0xFF


class RegisterBackend(Protocol):
    def read16(self, addr: int) -> int:
        ...

    def write16(self, addr: int, value: int) -> None:
        ...


@dataclass(frozen=True)
class Transaction:
    op: str
    addr: int
    value: Optional[int] = None


class DryRunBackend:
    """Backend that records logical transactions without touching hardware.

    Reads return the last value written to the same address, falling back to
    the configured ``reads`` map, so write-then-verify sequences behave the
    same as on a real register bank.
    """

    def __init__(self, reads: Optional[Dict[int, int]] = None):
        self.reads = dict(reads or {})
        self.transactions: List[Transaction] = []

    def read16(self, addr: int) -> int:
        addr = _u8(addr)
        value = _u16(self.reads.get(addr, 0))
        self.transactions.append(Transaction("read", addr, value))
        return value

    def write16(self, addr: int, value: int) -> None:
        addr = _u8(addr)
        value = _u16(value)
        self.transactions.append(Transaction("write", addr, value))
        self.reads[addr] = value


class MockWpAdjustBackend:
    """Behavioral mock of the wp_adjust register bank for host tests."""

    def __init__(self, frac_bits: int = DEFAULT_FRAC_BITS):
        if frac_bits < 0 or frac_bits > 15:
            raise ValueError("frac_bits must fit in STATUS[15:8]")
        self.frac_bits = frac_bits
        self.transactions: List[Transaction] = []
        self._reset_registers()

    def read16(self, addr: int) -> int:
        addr = _u8(addr)
        value = _u16(self._read(addr))
        self.transactions.append(Transaction("read", addr, value))
        return value

    def write16(self, addr: int, value: int) -> None:
        addr = _u8(addr)
        value = _u16(value)
        self.transactions.append(Transaction("write", addr, value))
        self._write(addr, value)

    def consume_commit(self) -> None:
        """Simulate the next filtered active-high vsync consuming COMMIT."""

        if not self.commit_pending:
            return
        self.active.update(self.shadow)
        self.commit_pending = False
        self.commit_consumed = True

    def _reset_registers(self) -> None:
        defaults = {
            Register.CONTROL_SHADOW: 0,
            Register.R_GAIN_SHADOW: UNITY_GAIN_Q4_12,
            Register.G_GAIN_SHADOW: UNITY_GAIN_Q4_12,
            Register.B_GAIN_SHADOW: UNITY_GAIN_Q4_12,
            Register.R_OFFSET_SHADOW: 0,
            Register.G_OFFSET_SHADOW: 0,
            Register.B_OFFSET_SHADOW: 0,
        }
        self.shadow = dict(defaults)
        self.active = {
            Register.CONTROL_SHADOW: defaults[Register.CONTROL_SHADOW],
            Register.R_GAIN_SHADOW: defaults[Register.R_GAIN_SHADOW],
            Register.G_GAIN_SHADOW: defaults[Register.G_GAIN_SHADOW],
            Register.B_GAIN_SHADOW: defaults[Register.B_GAIN_SHADOW],
            Register.R_OFFSET_SHADOW: defaults[Register.R_OFFSET_SHADOW],
            Register.G_OFFSET_SHADOW: defaults[Register.G_OFFSET_SHADOW],
            Register.B_OFFSET_SHADOW: defaults[Register.B_OFFSET_SHADOW],
        }
        self.commit_pending = False
        self.commit_consumed = False

    def _read(self, addr: int) -> int:
        reg = Register(addr) if addr in {item.value for item in Register} else None
        if reg == Register.ID:
            return WP_ADJUST_ID
        if reg == Register.VERSION:
            return WP_ADJUST_VERSION
        if reg == Register.STATUS:
            return self._status_raw()
        if reg in self.shadow:
            return self.shadow[reg]

        active_reg = _active_to_shadow(reg)
        if active_reg is not None:
            return self.active[active_reg]
        return 0

    def _write(self, addr: int, value: int) -> None:
        reg = Register(addr) if addr in {item.value for item in Register} else None
        if reg in self.shadow:
            self.shadow[reg] = value
        elif reg == Register.COMMIT and value == COMMIT_MAGIC:
            self.commit_pending = True
            self.commit_consumed = False
        elif reg == Register.COMMIT and value == COMMIT_CANCEL_MAGIC:
            self.commit_pending = False
            self.commit_consumed = False
        elif reg == Register.DEFAULTS and value == DEFAULTS_MAGIC:
            self._reset_registers()

    def _status_raw(self) -> int:
        control = self.active[Register.CONTROL_SHADOW]
        return (
            (self.frac_bits << 8)
            | ((control & 0x2) << 2)
            | ((control & 0x1) << 2)
            | (0x2 if self.commit_consumed else 0)
            | (0x1 if self.commit_pending else 0)
        )


class WpAdjustRegisters:
    """Typed logical accessors for the wp_adjust register map."""

    def __init__(self, backend: RegisterBackend):
        self.backend = backend

    def read(self, reg: Register) -> int:
        return _u16(self.backend.read16(reg.value))

    def write(self, reg: Register, value: int) -> None:
        self.backend.write16(reg.value, _u16(value))

    def read_status(self) -> Status:
        return Status(self.read(Register.STATUS))

    def probe(self, expected_frac_bits: int = DEFAULT_FRAC_BITS) -> Status:
        device_id = self.read(Register.ID)
        if device_id != WP_ADJUST_ID:
            raise RuntimeError(f"unexpected wp_adjust ID 0x{device_id:04X}")

        version = self.read(Register.VERSION)
        version_major = (version >> 8) & 0xFF
        if version_major != WP_ADJUST_VERSION_MAJOR:
            raise RuntimeError(
                f"unsupported wp_adjust register-map major 0x{version_major:02X}"
            )

        status = self.read_status()
        if status.frac_bits != expected_frac_bits:
            raise RuntimeError(
                f"unexpected wp_adjust FRAC_BITS {status.frac_bits}, expected {expected_frac_bits}"
            )
        return status

    def write_shadow_gains(self, gains: Dict[str, int]) -> None:
        _require_rgb_keys(gains, "gains")
        self.write(Register.R_GAIN_SHADOW, gains["r"])
        self.write(Register.G_GAIN_SHADOW, gains["g"])
        self.write(Register.B_GAIN_SHADOW, gains["b"])

    def write_shadow_offsets(self, offsets: Dict[str, int]) -> None:
        _require_rgb_keys(offsets, "offsets")
        self.write(Register.R_OFFSET_SHADOW, _signed16_to_u16(offsets["r"]))
        self.write(Register.G_OFFSET_SHADOW, _signed16_to_u16(offsets["g"]))
        self.write(Register.B_OFFSET_SHADOW, _signed16_to_u16(offsets["b"]))

    def write_control(self, enable: bool, offset_enable: bool = False) -> None:
        value = (1 if enable else 0) | (2 if offset_enable else 0)
        self.write(Register.CONTROL_SHADOW, value)

    def commit(self, check_pending: bool = True) -> None:
        if check_pending:
            status = self.read_status()
            if status.commit_pending:
                raise RuntimeError("refusing to COMMIT while previous commit is pending")
        self.write(Register.COMMIT, COMMIT_MAGIC)

    def cancel_commit(self) -> None:
        """Cancel an armed commit; shadow and active registers are untouched.

        A cancel racing the commit vsync edge may arrive after the update has
        latched; read the active registers afterwards when that matters.
        Requires register-map revision 0x0113 or later (no-op on 0x0112).
        """

        self.write(Register.COMMIT, COMMIT_CANCEL_MAGIC)

    def defaults(self) -> None:
        self.write(Register.DEFAULTS, DEFAULTS_MAGIC)

    def verify_shadow(
        self,
        gains: Dict[str, int],
        offsets: Dict[str, int],
        enable: bool,
        offset_enable: bool,
    ) -> None:
        """Read back shadow registers and compare against the intended values.

        Catches transport-level corruption (e.g. a lost or garbled I2C write)
        before the values are committed to the active datapath.
        """

        expected = [
            (Register.R_GAIN_SHADOW, _u16(gains["r"])),
            (Register.G_GAIN_SHADOW, _u16(gains["g"])),
            (Register.B_GAIN_SHADOW, _u16(gains["b"])),
            (Register.R_OFFSET_SHADOW, _signed16_to_u16(offsets["r"])),
            (Register.G_OFFSET_SHADOW, _signed16_to_u16(offsets["g"])),
            (Register.B_OFFSET_SHADOW, _signed16_to_u16(offsets["b"])),
            (Register.CONTROL_SHADOW, (1 if enable else 0) | (2 if offset_enable else 0)),
        ]
        for reg, want in expected:
            got = self.read(reg)
            if got != want:
                raise RuntimeError(
                    f"shadow readback mismatch at {reg.name}: "
                    f"wrote 0x{want:04X}, read 0x{got:04X}; not committing"
                )

    def write_calibration(
        self,
        gains: Dict[str, int],
        offsets: Optional[Dict[str, int]] = None,
        offset_enable: bool = False,
        enable: bool = True,
        verify: bool = True,
    ) -> None:
        status = self.read_status()
        if status.commit_pending:
            raise RuntimeError("refusing to write shadow registers while commit is pending")

        self.write_shadow_gains(gains)
        if offsets is None:
            offsets = {"r": 0, "g": 0, "b": 0}
        self.write_shadow_offsets(offsets)
        self.write_control(enable=enable, offset_enable=offset_enable)
        if verify:
            self.verify_shadow(
                gains=gains,
                offsets=offsets,
                enable=enable,
                offset_enable=offset_enable,
            )
        self.commit(check_pending=False)


def transaction_summary(transactions: List[Transaction]) -> List[Tuple[str, int, Optional[int]]]:
    return [(entry.op, entry.addr, entry.value) for entry in transactions]


def _active_to_shadow(reg: Optional[Register]) -> Optional[Register]:
    mapping = {
        Register.CONTROL_ACTIVE: Register.CONTROL_SHADOW,
        Register.R_GAIN_ACTIVE: Register.R_GAIN_SHADOW,
        Register.G_GAIN_ACTIVE: Register.G_GAIN_SHADOW,
        Register.B_GAIN_ACTIVE: Register.B_GAIN_SHADOW,
        Register.R_OFFSET_ACTIVE: Register.R_OFFSET_SHADOW,
        Register.G_OFFSET_ACTIVE: Register.G_OFFSET_SHADOW,
        Register.B_OFFSET_ACTIVE: Register.B_OFFSET_SHADOW,
    }
    return mapping.get(reg)


def _require_rgb_keys(values: Dict[str, int], name: str) -> None:
    if set(values) != {"r", "g", "b"}:
        raise ValueError(f"{name} must contain exactly r, g, and b")


def _signed16_to_u16(value: int) -> int:
    if not isinstance(value, int) or value < -32768 or value > 32767:
        raise ValueError("signed offset must fit in int16")
    return value & 0xFFFF


def _u8(value: int) -> int:
    if not isinstance(value, int) or value < 0 or value > 0xFF:
        raise ValueError("register address must fit in uint8")
    return int(value)


def _u16(value: int) -> int:
    if not isinstance(value, int) or value < 0 or value > 0xFFFF:
        raise ValueError("register value must fit in uint16")
    return int(value)
