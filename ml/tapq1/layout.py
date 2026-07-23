"""Feature contract shared with the Swift runtime.

This file mirrors ``Sources/TapQDetectionBaseline/EncoderContract.swift`` — the two
must agree exactly. The Swift test suite pins these values
(``EncoderContractTests``); any change here without a matching Swift change and a
new VERSION string will be refused at model load by ``CoreMLMotionScorer``.
"""

VERSION = "tapq1-features-v1"

CHANNEL_NAMES = [
    "user_acceleration_x", "user_acceleration_y", "user_acceleration_z",
    "rotation_rate_x", "rotation_rate_y", "rotation_rate_z",
    "gravity_x", "gravity_y", "gravity_z",
]
CHANNEL_COUNT = len(CHANNEL_NAMES)

WINDOW_LENGTH = 32
SAMPLE_RATE_HZ = 25.0

ACCELERATION_FULL_SCALE = 2.0
ROTATION_FULL_SCALE = 8.0

# Output-vector order of the joint classification head. "quiet" is the background
# class; "tap" means the complete double-tap pattern within one window (both
# transients of a double tap fit in 1.28 s) — lone bumps are labeled quiet.
CLASSES = [
    "quiet", "nod", "shake", "tilt_left", "tilt_right",
    "tap", "swipe_up", "swipe_down",
]
CLASS_COUNT = len(CLASSES)

METADATA_FEATURE_LAYOUT_KEY = "com.tapq.tapq1.feature_layout"
METADATA_CLASSES_KEY = "com.tapq.tapq1.classes"
METADATA_WINDOW_LENGTH_KEY = "com.tapq.tapq1.window_length"

# Per-channel full-scale divisors, in CHANNEL_NAMES order.
CHANNEL_FULL_SCALES = (
    [ACCELERATION_FULL_SCALE] * 3 + [ROTATION_FULL_SCALE] * 3 + [1.0] * 3
)


def scale(raw):
    """Normalize raw channel values into [-1, 1] with fixed physical full scales.

    ``raw`` is an array shaped [..., CHANNEL_COUNT] in CHANNEL_NAMES order.
    Mirrors ``EncoderFeatureLayout.featureRow``.
    """
    import numpy as np

    scales = np.asarray(CHANNEL_FULL_SCALES, dtype=np.float32)
    return np.clip(np.asarray(raw, dtype=np.float32) / scales, -1.0, 1.0)
