from demo import IMAGE_5X5, SOBEL_X, reference_conv3x3, run_demo


def test_demo_matches_reference() -> None:
    hw_result, ref_result = run_demo()

    assert hw_result == ref_result
    assert ref_result == reference_conv3x3(IMAGE_5X5, SOBEL_X)
