"""Linux i2c-dev RegisterBackend for the wp_adjust page transport.

Implements the hardware transport decided in
docs/i2c-master-sw-integration-guideline.md section 1.2: the wp_adjust
logical register map (8-bit register, 16-bit data) exposed on the FPGA "new"
I2C slave (default 7-bit address 0x1E) as one page (default 0x03), byte
addressed at 2 bytes per logical register, big-endian:

    byte_addr = logical_register << 1   (even = hi byte, odd = lo byte)

On-wire framing (the slave latches the pointer across STOP and a single-byte
pointer would default to page 0, so the explicit two-byte {page, reg}
pointer is always sent):

    write: [page, byte_addr, hi, lo]
    read:  [page, byte_addr] then read 2 bytes

One 16-bit register per I2C transaction; multi-register bursts are not part
of the v1 host contract.

Stdlib only (fcntl ioctl + os read/write) so it runs on a bare target image.
"""

from __future__ import annotations

import fcntl
import os

I2C_SLAVE_IOCTL = 0x0703  # linux/i2c-dev.h I2C_SLAVE

DEFAULT_I2C_DEVICE = "/dev/i2c-1"
DEFAULT_I2C_ADDRESS = 0x1E
DEFAULT_WP_PAGE = 0x03


class I2CDevBackend:
    """RegisterBackend (read16/write16) over /dev/i2c-N."""

    def __init__(
        self,
        device: str = DEFAULT_I2C_DEVICE,
        address: int = DEFAULT_I2C_ADDRESS,
        page: int = DEFAULT_WP_PAGE,
    ):
        if not isinstance(address, int) or not 0x03 <= address <= 0x77:
            raise ValueError("I2C address must be a 7-bit address in [0x03, 0x77]")
        if not isinstance(page, int) or not 0x00 <= page <= 0xFF:
            raise ValueError("page must fit in uint8")
        self.device = device
        self.address = address
        self.page = page
        self.fd = os.open(device, os.O_RDWR)
        try:
            fcntl.ioctl(self.fd, I2C_SLAVE_IOCTL, address)
        except OSError:
            os.close(self.fd)
            self.fd = -1
            raise

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self) -> "I2CDevBackend":
        return self

    def __exit__(self, _exc_type, _exc, _tb) -> None:
        self.close()

    @staticmethod
    def _byte_addr(addr: int) -> int:
        if not isinstance(addr, int) or not 0x00 <= addr <= 0x7F:
            raise ValueError("logical register address must be in [0x00, 0x7F]")
        return (addr << 1) & 0xFF

    def read16(self, addr: int) -> int:
        pointer = bytes([self.page, self._byte_addr(addr)])
        if os.write(self.fd, pointer) != len(pointer):
            raise RuntimeError(
                f"short I2C pointer write at page 0x{self.page:02X} reg 0x{addr:02X}")
        data = os.read(self.fd, 2)
        if len(data) != 2:
            raise RuntimeError(
                f"short I2C read at page 0x{self.page:02X} reg 0x{addr:02X}")
        return (data[0] << 8) | data[1]

    def write16(self, addr: int, value: int) -> None:
        if not isinstance(value, int) or not 0x0000 <= value <= 0xFFFF:
            raise ValueError("register value must fit in uint16")
        payload = bytes([
            self.page,
            self._byte_addr(addr),
            (value >> 8) & 0xFF,
            value & 0xFF,
        ])
        if os.write(self.fd, payload) != len(payload):
            raise RuntimeError(
                f"short I2C write at page 0x{self.page:02X} reg 0x{addr:02X}")
