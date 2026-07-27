"""End-to-end smoke test on synthetic motion — no captured data required.

    python -m tapq1.smoke [--export /tmp/tapq1-smoke.mlpackage]

Fabricates windows with class-distinct synthetic signatures, runs a few
pretraining and training steps, checks the parameter budget, and (when
coremltools is installed) exports and re-loads a Core ML package. Proves the
pipeline end to end before any capture study data exists; the accuracy numbers
it prints are meaningless by design.
"""

import argparse

import numpy as np
import torch

from . import layout
from .model import TapQ1Encoder
from .pretrain import pretrain
from .train import train


def synthetic_windows(per_class=40, seed=0):
    """Each class gets a crude, well-separated signature on the channels its real
    counterpart would excite. This validates plumbing, not detection."""
    rng = np.random.default_rng(seed)
    length = layout.WINDOW_LENGTH
    grid = np.linspace(0, 2 * np.pi, length, dtype=np.float32)
    windows, labels = [], []
    for class_index in range(layout.CLASS_COUNT):
        for _ in range(per_class):
            window = rng.normal(0, 0.02, (length, layout.CHANNEL_COUNT)).astype(np.float32)
            window[:, 8] -= 0.9  # gravity mostly -z, as worn
            amplitude = rng.uniform(0.3, 0.6)
            if class_index == 1:    # nod: pitch-axis rotation oscillation
                window[:, 3] += amplitude * np.sin(2 * grid)
            elif class_index == 2:  # shake: yaw-axis oscillation, faster
                window[:, 5] += amplitude * np.sin(4 * grid)
            elif class_index == 3:  # tilt left: one roll excursion
                window[:, 4] -= amplitude * np.sin(grid)
            elif class_index == 4:  # tilt right
                window[:, 4] += amplitude * np.sin(grid)
            elif class_index == 5:  # double tap: two sharp accel spikes
                for center in (length // 3, 2 * length // 3):
                    window[center:center + 2, 0:3] += amplitude
            elif class_index == 6:  # swipe up: sustained accel plateau, +gravity axis
                window[8:20, 2] += 0.5 * amplitude
            elif class_index == 7:  # swipe down
                window[8:20, 2] -= 0.5 * amplitude
            windows.append(np.clip(window, -1, 1))
            labels.append(class_index)
    return np.stack(windows), np.array(labels, dtype=np.int64)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", help="also export a Core ML package to this path")
    arguments = parser.parse_args()

    encoder = TapQ1Encoder()
    parameters = encoder.parameter_count()
    print(f"parameter count: {parameters}")
    assert 40_000 <= parameters <= 120_000, "outside the tiny-encoder budget"

    x, y = synthetic_windows()
    print(f"synthetic windows: {len(x)}")
    pretrain(x, epochs=2, log=lambda message: print(f"  {message}"))
    trained = train(x, y, epochs=5, log=lambda message: print(f"  {message}"))

    with torch.no_grad():
        probabilities = torch.softmax(trained(torch.from_numpy(x[:4])), dim=-1)
    assert probabilities.shape == (4, layout.CLASS_COUNT)
    assert torch.allclose(probabilities.sum(dim=-1), torch.ones(4), atol=1e-5)
    print("forward pass OK")

    if arguments.export:
        import tempfile
        from pathlib import Path

        from .export import export

        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "smoke.pt"
            torch.save(trained.state_dict(), checkpoint)
            saved = export(checkpoint, arguments.export)
            print(f"export OK: {saved}")

    print("smoke test passed")


if __name__ == "__main__":
    main()
