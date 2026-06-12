import json
from pathlib import Path

import pytest

import host.wp_i2cdev as wp_i2cdev
from host.wp_i2cdev import I2CDevBackend, I2C_SLAVE_IOCTL
from host.wp_load import apply_profile
from host.wp_registers import MockWpAdjustBackend, WpAdjustRegisters


ROOT = Path(__file__).resolve().parents[2]
SEED_PATH = ROOT / "examples" / "calibration" / "12-3-nq1v1-seed.json"
FAKE_FD = 42


class FakeI2CDev:
    """Emulates /dev/i2c-N with a wp_adjust register bank behind the page
    transport: pointer write [page, byte_addr], data write [page, byte_addr,
    hi, lo], read returns 2 bytes from the latched pointer."""

    def __init__(self, page=0x03):
        self.page = page
        self.bank = MockWpAdjustBackend()
        self.opened_path = None
        self.ioctls = []
        self.writes = []
        self.pointer = None
        self.closed = False

    def install(self, monkeypatch):
        monkeypatch.setattr(wp_i2cdev.os, "open", self._open)
        monkeypatch.setattr(wp_i2cdev.os, "close", self._close)
        monkeypatch.setattr(wp_i2cdev.os, "read", self._read)
        monkeypatch.setattr(wp_i2cdev.os, "write", self._write)
        monkeypatch.setattr(wp_i2cdev.fcntl, "ioctl", self._ioctl)

    def _open(self, path, _flags):
        self.opened_path = path
        return FAKE_FD

    def _close(self, fd):
        assert fd == FAKE_FD
        self.closed = True

    def _ioctl(self, fd, request, arg):
        assert fd == FAKE_FD
        self.ioctls.append((request, arg))
        return 0

    def _write(self, fd, data):
        assert fd == FAKE_FD
        self.writes.append(bytes(data))
        assert data[0] == self.page, "wrong page byte on the wire"
        byte_addr = data[1]
        assert byte_addr % 2 == 0, "16-bit access must start at the even (hi) byte"
        logical = byte_addr >> 1
        if len(data) == 2:
            self.pointer = logical
        elif len(data) == 4:
            self.bank.write16(logical, (data[2] << 8) | data[3])
        else:
            raise AssertionError(f"unexpected write length {len(data)}")
        return len(data)

    def _read(self, fd, length):
        assert fd == FAKE_FD
        assert length == 2
        assert self.pointer is not None, "read without pointer write"
        value = self.bank.read16(self.pointer)
        if self.pointer == 0x72 and self.bank.commit_pending:
            # Emulate running video: a frame boundary passes between this
            # STATUS read and the next, consuming the armed commit.
            self.bank.consume_commit()
        return bytes([(value >> 8) & 0xFF, value & 0xFF])


@pytest.fixture
def fake_dev(monkeypatch):
    dev = FakeI2CDev()
    dev.install(monkeypatch)
    return dev


def test_open_sets_slave_address(fake_dev):
    backend = I2CDevBackend(device="/dev/i2c-9", address=0x1E, page=0x03)
    assert fake_dev.opened_path == "/dev/i2c-9"
    assert fake_dev.ioctls == [(I2C_SLAVE_IOCTL, 0x1E)]
    backend.close()
    assert fake_dev.closed


def test_read16_frames_pointer_then_two_bytes(fake_dev):
    backend = I2CDevBackend()

    assert backend.read16(0x70) == 0x57A1  # ID via the mock bank
    assert fake_dev.writes[-1] == bytes([0x03, 0xE0])  # logical 0x70 -> byte 0xE0


def test_write16_frames_four_bytes_big_endian(fake_dev):
    backend = I2CDevBackend()

    backend.write16(0x01, 0x0F19)

    assert fake_dev.writes[-1] == bytes([0x03, 0x02, 0x0F, 0x19])
    assert fake_dev.bank.read16(0x01) == 0x0F19


def test_invalid_address_and_value_rejected(fake_dev):
    backend = I2CDevBackend()

    with pytest.raises(ValueError):
        backend.read16(0x80)  # logical map ends at 0x7F
    with pytest.raises(ValueError):
        backend.write16(0x01, 0x1_0000)
    with pytest.raises(ValueError):
        I2CDevBackend(address=0x100)


def test_apply_profile_end_to_end_over_fake_i2c(fake_dev):
    """The full loader sequence (probe, shadow writes, readback verify,
    COMMIT, status poll) works through the byte-framed transport."""

    profile = json.loads(SEED_PATH.read_text(encoding="utf-8"))
    regs = WpAdjustRegisters(I2CDevBackend())

    result = apply_profile(regs, profile, timeout_sec=0.05,
                           poll_interval_sec=0, sleep_fn=lambda _s: None)

    # The mock bank consumes the commit on a STATUS read, so the loader
    # observes a completed commit and the active gains match the profile.
    assert result.state == "committed"
    assert fake_dev.bank.read16(0x21) == profile["gains"]["r"]
    assert fake_dev.bank.read16(0x22) == profile["gains"]["g"]
    assert fake_dev.bank.read16(0x23) == profile["gains"]["b"]
    # COMMIT magic went over the wire at byte offset 0xFC.
    assert bytes([0x03, 0xFC, 0xCA, 0x1B]) in fake_dev.writes
