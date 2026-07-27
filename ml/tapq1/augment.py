"""Training-time augmentation for scaled IMU windows [N, WINDOW_LENGTH, 9].

The three vector triads (acceleration, rotation rate, gravity) live in the same
earbud frame, so geometric transforms must rotate all three identically —
independently perturbing them would fabricate physically impossible samples.
Time warping addresses the papers' consistent finding that gesture *speed* varies
per user more than gesture *shape* (EarDA; DTW's warping invariance).
"""

import numpy as np


def _random_rotation(rng, max_radians):
    axis = rng.normal(size=3)
    axis /= np.linalg.norm(axis) + 1e-12
    angle = rng.uniform(-max_radians, max_radians)
    x, y, z = axis * np.sin(angle / 2)
    w = np.cos(angle / 2)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float32)


def rotate(windows, rng, max_radians=0.2):
    """Small random 3D rotation, one per window, applied to every triad — models
    ear-fit variation between insertions."""
    out = windows.copy()
    for index in range(len(out)):
        rotation = _random_rotation(rng, max_radians)
        for triad in range(0, 9, 3):
            out[index, :, triad:triad + 3] = out[index, :, triad:triad + 3] @ rotation.T
    return out


def time_warp(windows, rng, low=0.8, high=1.2):
    """Linear-resample each window at a random speed, then crop/pad back to length."""
    length = windows.shape[1]
    out = np.empty_like(windows)
    grid = np.arange(length)
    for index in range(len(windows)):
        speed = rng.uniform(low, high)
        source = np.clip(grid * speed, 0, length - 1)
        floor = source.astype(int)
        ceil = np.minimum(floor + 1, length - 1)
        fraction = (source - floor)[:, None].astype(np.float32)
        out[index] = (1 - fraction) * windows[index, floor] + fraction * windows[index, ceil]
    return out


def jitter(windows, rng, scale_sigma=0.05, noise_sigma=0.01):
    """Per-window amplitude scale plus white noise on the motion channels (gravity
    is a direction, not an amplitude — leave it out of scaling)."""
    out = windows.copy()
    scales = rng.normal(1.0, scale_sigma, size=(len(out), 1, 1)).astype(np.float32)
    out[:, :, :6] *= scales
    out += rng.normal(0.0, noise_sigma, size=out.shape).astype(np.float32)
    return np.clip(out, -1.0, 1.0)


def augment(windows, rng):
    return jitter(time_warp(rotate(windows, rng), rng), rng)
