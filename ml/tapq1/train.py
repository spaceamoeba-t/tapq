"""Supervised fine-tuning of the joint gesture head on labeled captures.

    python -m tapq1.train --manifest data/manifest.json \
        --pretrained checkpoints/pretrained.pt --out checkpoints/tapq1.pt
"""

import argparse
from pathlib import Path

import numpy as np
import torch
from torch import nn

from . import augment, data, layout
from .model import TapQ1Encoder


def class_weights(labels):
    """Inverse-frequency weights: quiet dominates any honest capture and would
    otherwise swallow the gesture classes."""
    counts = np.bincount(labels, minlength=layout.CLASS_COUNT).astype(np.float64)
    weights = np.where(counts > 0, 1.0 / np.maximum(counts, 1), 0.0)
    total = weights.sum()
    if total > 0:
        weights = weights * layout.CLASS_COUNT / total
    return torch.tensor(weights, dtype=torch.float32)


def split(x, y, validation_fraction, rng):
    order = rng.permutation(len(x))
    cut = max(1, int(len(x) * validation_fraction)) if len(x) > 1 else 0
    validation, training = order[:cut], order[cut:]
    return x[training], y[training], x[validation], y[validation]


def per_class_report(model, x, y, log=print):
    if len(x) == 0:
        return
    with torch.no_grad():
        predictions = model(torch.from_numpy(x)).argmax(dim=-1).numpy()
    for index, name in enumerate(layout.CLASSES):
        expected = y == index
        emitted = predictions == index
        if not expected.any() and not emitted.any():
            continue
        true_positives = int((expected & emitted).sum())
        precision = true_positives / max(1, int(emitted.sum()))
        recall = true_positives / max(1, int(expected.sum()))
        log(f"  {name:12s} precision {precision:.2f}  recall {recall:.2f}  "
            f"support {int(expected.sum())}")


def train(x, y, pretrained=None, epochs=100, batch_size=64, learning_rate=5e-4,
          validation_fraction=0.2, seed=0, log=print):
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    encoder = TapQ1Encoder()
    if pretrained:
        encoder.load_state_dict(torch.load(pretrained, weights_only=True))
        log(f"loaded pretrained trunk from {pretrained}")

    train_x, train_y, validation_x, validation_y = split(
        x, y, validation_fraction, rng)
    criterion = nn.CrossEntropyLoss(weight=class_weights(train_y))
    optimizer = torch.optim.AdamW(encoder.parameters(), lr=learning_rate)

    for epoch in range(epochs):
        order = rng.permutation(len(train_x))
        total, batches = 0.0, 0
        for begin in range(0, len(train_x), batch_size):
            chosen = order[begin:begin + batch_size]
            batch = torch.from_numpy(augment.augment(train_x[chosen], rng))
            loss = criterion(encoder(batch), torch.from_numpy(train_y[chosen]))
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            total += float(loss)
            batches += 1
        if (epoch + 1) % 10 == 0 or epoch == epochs - 1:
            log(f"train epoch {epoch + 1}/{epochs} loss {total / max(1, batches):.5f}")

    encoder.eval()
    log("validation:")
    per_class_report(encoder, validation_x, validation_y, log=log)
    return encoder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--pretrained")
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=5e-4)
    parser.add_argument("--validation-fraction", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=0)
    arguments = parser.parse_args()

    x, y, _ = data.load_manifest(arguments.manifest)
    if len(x) == 0:
        raise SystemExit("manifest contains no labeled windows")
    gesture_windows = int((y != 0).sum())
    print(f"training on {len(x)} windows ({gesture_windows} non-quiet)")
    encoder = train(
        x, y, pretrained=arguments.pretrained, epochs=arguments.epochs,
        batch_size=arguments.batch_size, learning_rate=arguments.learning_rate,
        validation_fraction=arguments.validation_fraction, seed=arguments.seed)
    Path(arguments.out).parent.mkdir(parents=True, exist_ok=True)
    torch.save(encoder.state_dict(), arguments.out)
    print(f"saved {arguments.out} ({encoder.parameter_count()} parameters)")


if __name__ == "__main__":
    main()
