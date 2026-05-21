"""High-level Python driver for the TinyAXIConv accelerator."""

from __future__ import annotations

from dataclasses import dataclass

from axi_lite import (
    ADDR_CTRL,
    ADDR_INPUT_BASE,
    ADDR_KERNEL_BASE,
    ADDR_OUTPUT_BASE,
    ADDR_STATUS,
    AXILiteMaster,
    INPUT_COUNT,
    KERNEL_COUNT,
    OUTPUT_COUNT,
    WORD_STRIDE,
    to_s32,
)


def _check_int8_values(name: str, values: list[int], expected_len: int) -> None:
    if len(values) != expected_len:
        raise ValueError(f"{name} must contain {expected_len} values, got {len(values)}")
    for index, value in enumerate(values):
        if value < -128 or value > 127:
            raise ValueError(f"{name}[{index}]={value} is outside int8 range")


def _pack_int8(value: int) -> int:
    return value & 0xFF


@dataclass
class ConvAccel:
    """Convenience wrapper around the TinyAXIConv register map."""

    master: AXILiteMaster
    poll_limit: int = 10_000

    def set_kernel(self, weights: list[int]) -> None:
        """Write 9 int8 kernel weights."""

        _check_int8_values("weights", weights, KERNEL_COUNT)
        for index, weight in enumerate(weights):
            addr = ADDR_KERNEL_BASE + index * WORD_STRIDE
            self.master.write(addr, _pack_int8(weight))

    def set_input(self, data: list[int]) -> None:
        """Write 25 int8 input pixels into the 5x5 scratchpad."""

        _check_int8_values("data", data, INPUT_COUNT)
        for index, value in enumerate(data):
            addr = ADDR_INPUT_BASE + index * WORD_STRIDE
            self.master.write(addr, _pack_int8(value))

    def run(self) -> None:
        """Trigger the accelerator and poll status.done until it is set."""

        self.master.write(ADDR_CTRL, 0x1)
        for _ in range(self.poll_limit):
            status = self.master.read(ADDR_STATUS)
            if status & 0x1:
                return
        raise TimeoutError("TinyAXIConv did not report done before poll_limit")

    def get_output(self) -> list[int]:
        """Read 9 signed int32 output values."""

        values: list[int] = []
        for index in range(OUTPUT_COUNT):
            addr = ADDR_OUTPUT_BASE + index * WORD_STRIDE
            values.append(to_s32(self.master.read(addr)))
        return values

    def run_once(self, weights: list[int], data: list[int]) -> list[int]:
        """Small helper for tests and demos."""

        self.set_kernel(weights)
        self.set_input(data)
        self.run()
        return self.get_output()
