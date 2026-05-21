from axi_lite import AXILiteMaster, SimBackend
from conv_driver import ConvAccel


def test_all_ones_convolution_outputs_nine() -> None:
    backend = SimBackend()
    accel = ConvAccel(AXILiteMaster(backend))

    result = accel.run_once([1] * 9, [1] * 25)

    assert result == [9] * 9


def test_driver_rejects_wrong_kernel_size() -> None:
    accel = ConvAccel(AXILiteMaster(SimBackend()))

    try:
        accel.set_kernel([1] * 8)
    except ValueError as exc:
        assert "9 values" in str(exc)
    else:
        raise AssertionError("set_kernel should reject wrong kernel size")


def test_driver_rejects_out_of_range_input() -> None:
    accel = ConvAccel(AXILiteMaster(SimBackend()))
    data = [0] * 25
    data[7] = 200

    try:
        accel.set_input(data)
    except ValueError as exc:
        assert "outside int8 range" in str(exc)
    else:
        raise AssertionError("set_input should reject int8 overflow")
