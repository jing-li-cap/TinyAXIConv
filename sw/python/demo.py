"""Sobel demo for TinyAXIConv.

Run with:
    python demo.py
"""

from __future__ import annotations

from axi_lite import AXILiteMaster, SimBackend
from conv_driver import ConvAccel


SOBEL_X: list[int] = [
    -1,
    0,
    1,
    -2,
    0,
    2,
    -1,
    0,
    1,
]

IMAGE_5X5: list[int] = [
    0,
    0,
    1,
    2,
    3,
    0,
    1,
    2,
    3,
    4,
    1,
    2,
    3,
    4,
    5,
    2,
    3,
    4,
    5,
    6,
    3,
    4,
    5,
    6,
    7,
]


def reference_conv3x3(image: list[int], kernel: list[int]) -> list[int]:
    """Pure Python 5x5 image by 3x3 kernel valid convolution."""

    if len(image) != 25:
        raise ValueError("image must contain 25 values")
    if len(kernel) != 9:
        raise ValueError("kernel must contain 9 values")

    result: list[int] = []
    for out_row in range(3):
        for out_col in range(3):
            acc = 0
            for ker_row in range(3):
                for ker_col in range(3):
                    image_index = (out_row + ker_row) * 5 + (out_col + ker_col)
                    kernel_index = ker_row * 3 + ker_col
                    acc += image[image_index] * kernel[kernel_index]
            result.append(acc)
    return result


def numpy_reference_conv3x3(image: list[int], kernel: list[int]) -> list[int]:
    """Use numpy when available, while keeping demo.py runnable without it."""

    try:
        import numpy as np  # type: ignore[import-not-found]
    except ImportError:
        return reference_conv3x3(image, kernel)

    image_np = np.array(image, dtype=np.int32).reshape(5, 5)
    kernel_np = np.array(kernel, dtype=np.int32).reshape(3, 3)
    out: list[int] = []
    for row in range(3):
        for col in range(3):
            window = image_np[row : row + 3, col : col + 3]
            out.append(int(np.sum(window * kernel_np)))
    return out


def run_demo() -> tuple[list[int], list[int]]:
    """Run Sobel on the simulator and return (hardware_result, reference)."""

    backend = SimBackend()
    master = AXILiteMaster(backend)
    accel = ConvAccel(master)

    accel.set_kernel(SOBEL_X)
    accel.set_input(IMAGE_5X5)
    accel.run()
    hw_result = accel.get_output()
    ref_result = numpy_reference_conv3x3(IMAGE_5X5, SOBEL_X)
    return hw_result, ref_result


def print_matrix(values: list[int], width: int) -> None:
    for row in range(0, len(values), width):
        print(" ".join(f"{value:4d}" for value in values[row : row + width]))


def main() -> None:
    hw_result, ref_result = run_demo()

    print("Input image 5x5:")
    print_matrix(IMAGE_5X5, 5)
    print("\nSobel-X kernel 3x3:")
    print_matrix(SOBEL_X, 3)
    print("\nTinyAXIConv output 3x3:")
    print_matrix(hw_result, 3)
    print("\nReference output 3x3:")
    print_matrix(ref_result, 3)

    if hw_result == ref_result:
        print("\nPASS: TinyAXIConv output matches numpy/reference convolution.")
    else:
        print("\nFAIL: TinyAXIConv output does not match reference convolution.")


if __name__ == "__main__":
    main()
