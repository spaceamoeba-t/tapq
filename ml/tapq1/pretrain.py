"""Masked-reconstruction pretraining on unlabeled captures (LIMU-BERT recipe).

Random spans of timesteps are zeroed out and the trunk learns to reconstruct the
missing channels — motion structure without labels. Usage:

    python -m tapq1.pretrain --manifest data/manifest.json --out checkpoints/pretrained.pt
"""

import argparse
from pathlib import Path

import numpy as np
import torch
from torch import nn

from . import data
from .model import TapQ1Encoder


def mask_spans(windows, rng, span=4, mask_fraction=0.3):
    """Zeroes random spans covering ~mask_fraction of timesteps; returns the
    masked windows plus a boolean [N, T] mask of which timesteps were hidden."""
    masked = windows.clone()
    hidden = torch.zeros(windows.shape[:2], dtype=torch.bool)
    length = windows.shape[1]
    spans_per_window = max(1, int(length * mask_fraction / span))
    for index in range(len(windows)):
        for _ in range(spans_per_window):
            start = int(rng.integers(0, length - span + 1))
            masked[index, start:start + span] = 0
            hidden[index, start:start + span] = True
    return masked, hidden


def pretrain(windows, epochs=50, batch_size=64, learning_rate=1e-3, seed=0,
             log=print):
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    encoder = TapQ1Encoder()
    optimizer = torch.optim.AdamW(encoder.parameters(), lr=learning_rate)
    tensor = torch.from_numpy(windows)

    for epoch in range(epochs):
        permutation = torch.randperm(len(tensor))
        total, batches = 0.0, 0
        for begin in range(0, len(tensor), batch_size):
            batch = tensor[permutation[begin:begin + batch_size]]
            masked, hidden = mask_spans(batch, rng)
            reconstruction = encoder.reconstruct(masked)
            loss = nn.functional.mse_loss(reconstruction[hidden], batch[hidden])
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            total += float(loss)
            batches += 1
        log(f"pretrain epoch {epoch + 1}/{epochs} loss {total / max(1, batches):.5f}")
    return encoder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--seed", type=int, default=0)
    arguments = parser.parse_args()

    labeled_x, _, unlabeled = data.load_manifest(arguments.manifest)
    windows = np.concatenate([labeled_x, unlabeled]) if len(labeled_x) else unlabeled
    if len(windows) == 0:
        raise SystemExit("manifest produced no windows")
    print(f"pretraining on {len(windows)} windows")
    encoder = pretrain(
        windows, epochs=arguments.epochs, batch_size=arguments.batch_size,
        learning_rate=arguments.learning_rate, seed=arguments.seed)
    Path(arguments.out).parent.mkdir(parents=True, exist_ok=True)
    torch.save(encoder.state_dict(), arguments.out)
    print(f"saved {arguments.out} ({encoder.parameter_count()} parameters)")


if __name__ == "__main__":
    main()
