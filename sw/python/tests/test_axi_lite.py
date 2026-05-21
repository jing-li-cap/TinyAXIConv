from axi_lite import (
    ADDR_CTRL,
    ADDR_INPUT_BASE,
    ADDR_KERNEL_BASE,
    ADDR_STATUS,
    AXILiteMaster,
    SimBackend,
    WORD_STRIDE,
    to_s32,
)


def test_int8_register_readback_is_sign_extended() -> None:
    backend = SimBackend()
    master = AXILiteMaster(backend)

    master.write(ADDR_KERNEL_BASE, 0xFF)
    master.write(ADDR_INPUT_BASE + 3 * WORD_STRIDE, 0x80)

    assert master.read(ADDR_KERNEL_BASE) == 0xFFFF_FFFF
    assert master.read(ADDR_INPUT_BASE + 3 * WORD_STRIDE) == 0xFFFF_FF80


def test_status_done_is_read_to_clear() -> None:
    backend = SimBackend()
    master = AXILiteMaster(backend)

    assert backend.irq is False
    master.write(ADDR_CTRL, 0x1)
    assert backend.irq is True

    assert master.read(ADDR_STATUS) == 0x1
    assert backend.irq is False
    assert master.read(ADDR_STATUS) == 0x0


def test_sim_backend_convolution_negative_values() -> None:
    backend = SimBackend()
    master = AXILiteMaster(backend)

    for index in range(9):
        master.write(ADDR_KERNEL_BASE + index * WORD_STRIDE, 0xFF)  # -1
    for index in range(25):
        master.write(ADDR_INPUT_BASE + index * WORD_STRIDE, 0x01)

    master.write(ADDR_CTRL, 0x1)
    assert master.read(ADDR_STATUS) == 1
    assert all(to_s32(value) == -9 for value in [master.read(0x100 + i * 4) for i in range(9)])
