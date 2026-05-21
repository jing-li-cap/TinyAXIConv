"""TinyAXIConv AXI-Lite master and simulation backend.

The SimBackend mirrors the RTL register map in ``hw/rtl/reg_ctrl.v``:
all array elements use 32-bit word-aligned addresses, int8 values live in
WDATA[7:0], and int32 outputs are returned as 32-bit two's-complement words.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


DATA_MASK = 0xFFFF_FFFF
BYTE_MASK = 0xFF

ADDR_CTRL = 0x000
ADDR_STATUS = 0x004
ADDR_KERNEL_BASE = 0x008
ADDR_INPUT_BASE_REG = 0x02C
ADDR_INPUT_BASE = 0x080
ADDR_OUTPUT_BASE = 0x100
WORD_STRIDE = 4

KERNEL_COUNT = 9
INPUT_COUNT = 25
OUTPUT_COUNT = 9


class Backend(Protocol):
    """Minimal backend contract used by AXILiteMaster."""

    def write(self, addr: int, data: int) -> None:
        """Write one 32-bit AXI-Lite word."""

    def read(self, addr: int) -> int:
        """Read one 32-bit AXI-Lite word."""


def to_u32(value: int) -> int:
    """Convert Python int to a 32-bit unsigned bus value."""

    return value & DATA_MASK


def to_s32(value: int) -> int:
    """Interpret a 32-bit bus value as signed int32."""

    value &= DATA_MASK
    if value & 0x8000_0000:
        return value - 0x1_0000_0000
    return value


def to_s8(value: int) -> int:
    """Interpret the low 8 bits as signed int8."""

    value &= BYTE_MASK
    if value & 0x80:
        return value - 0x100
    return value


def sign_extend_i8_to_u32(value: int) -> int:
    """Return the RTL-style sign-extended readback for int8 registers."""

    return to_u32(to_s8(value))


@dataclass
class SimBackend:
    """Pure Python model of the TinyAXIConv register file and compute core."""

    kernel: list[int] = field(default_factory=lambda: [0] * KERNEL_COUNT)
    input_mem: list[int] = field(default_factory=lambda: [0] * INPUT_COUNT)
    output_mem: list[int] = field(default_factory=lambda: [0] * OUTPUT_COUNT)
    input_base_reg: int = ADDR_INPUT_BASE
    done_latch: bool = False

    @property
    def irq(self) -> bool:
        """IRQ is high whenever the done latch is set."""

        return self.done_latch

    def write(self, addr: int, data: int) -> None:
        """Decode an AXI-Lite write exactly like reg_ctrl.v."""

        addr &= 0xFFF
        data = to_u32(data)

        if addr == ADDR_CTRL:
            if data & 0x1:
                self._run_conv()
                self.done_latch = True
            return

        if addr == ADDR_INPUT_BASE_REG:
            self.input_base_reg = data
            return

        kernel_index = self._word_index(addr, ADDR_KERNEL_BASE, KERNEL_COUNT)
        if kernel_index is not None:
            self.kernel[kernel_index] = to_s8(data)
            return

        input_index = self._word_index(addr, ADDR_INPUT_BASE, INPUT_COUNT)
        if input_index is not None:
            self.input_mem[input_index] = to_s8(data)
            return

        # STATUS and OUTPUT are read-only in the RTL model; unknown writes are ignored.

    def read(self, addr: int) -> int:
        """Decode an AXI-Lite read exactly like reg_ctrl.v."""

        addr &= 0xFFF

        if addr == ADDR_CTRL:
            return 0

        if addr == ADDR_STATUS:
            value = 1 if self.done_latch else 0
            self.done_latch = False
            return value

        if addr == ADDR_INPUT_BASE_REG:
            return to_u32(self.input_base_reg)

        kernel_index = self._word_index(addr, ADDR_KERNEL_BASE, KERNEL_COUNT)
        if kernel_index is not None:
            return sign_extend_i8_to_u32(self.kernel[kernel_index])

        input_index = self._word_index(addr, ADDR_INPUT_BASE, INPUT_COUNT)
        if input_index is not None:
            return sign_extend_i8_to_u32(self.input_mem[input_index])

        output_index = self._word_index(addr, ADDR_OUTPUT_BASE, OUTPUT_COUNT)
        if output_index is not None:
            return to_u32(self.output_mem[output_index])

        return 0

    @staticmethod
    def _word_index(addr: int, base: int, count: int) -> int | None:
        """Return word-aligned array index, or None when addr is outside."""

        if addr < base or addr >= base + count * WORD_STRIDE:
            return None
        offset = addr - base
        if offset % WORD_STRIDE != 0:
            return None
        return offset // WORD_STRIDE

    def _run_conv(self) -> None:
        """Run the same 5x5 by 3x3 sliding-window convolution as conv3x3.v."""

        results: list[int] = []
        for out_row in range(3):
            for out_col in range(3):
                acc = 0
                for ker_row in range(3):
                    for ker_col in range(3):
                        in_index = (out_row + ker_row) * 5 + (out_col + ker_col)
                        ker_index = ker_row * 3 + ker_col
                        product = self.input_mem[in_index] * self.kernel[ker_index]
                        acc = to_s32(acc + product)
                results.append(acc)
        self.output_mem = results


@dataclass
class SerialBackend:
    """Placeholder backend for future board bring-up over a serial protocol."""

    port: str
    baudrate: int = 115_200
    timeout_s: float = 1.0

    def write(self, addr: int, data: int) -> None:
        raise NotImplementedError(
            "SerialBackend is reserved for board bring-up; define a framing "
            "protocol before using it."
        )

    def read(self, addr: int) -> int:
        raise NotImplementedError(
            "SerialBackend is reserved for board bring-up; define a framing "
            "protocol before using it."
        )


@dataclass
class AXILiteMaster:
    """Tiny blocking AXI-Lite master facade used by software drivers."""

    backend: Backend

    def write(self, addr: int, data: int) -> None:
        self.backend.write(addr, to_u32(data))

    def read(self, addr: int) -> int:
        return to_u32(self.backend.read(addr))
