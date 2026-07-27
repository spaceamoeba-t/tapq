"""Core ML export with the embedded runtime contract.

    python -m tapq1.export --checkpoint checkpoints/tapq1.pt --out models/tapq1.mlpackage

The exported model carries the feature-layout version, class order, and window
length as creator-defined metadata; ``CoreMLMotionScorer`` refuses to load any
model whose metadata disagrees with the Swift runtime, so a stale export fails
loudly instead of misclassifying quietly.
"""

import argparse
from pathlib import Path

import torch

from . import layout
from .model import ExportWrapper, TapQ1Encoder


def export(checkpoint_path, out_path):
    import coremltools as ct

    encoder = TapQ1Encoder()
    encoder.load_state_dict(torch.load(checkpoint_path, weights_only=True))
    encoder.eval()
    wrapper = ExportWrapper(encoder).eval()

    example = torch.zeros(1, layout.WINDOW_LENGTH, layout.CHANNEL_COUNT)
    traced = torch.jit.trace(wrapper, example)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="features", shape=example.shape)],
        compute_units=ct.ComputeUnit.ALL,
    )
    model.user_defined_metadata[layout.METADATA_FEATURE_LAYOUT_KEY] = layout.VERSION
    model.user_defined_metadata[layout.METADATA_CLASSES_KEY] = ",".join(layout.CLASSES)
    model.user_defined_metadata[layout.METADATA_WINDOW_LENGTH_KEY] = str(
        layout.WINDOW_LENGTH)
    model.short_description = (
        "TapQ-1 stage-1 gesture encoder "
        f"({encoder.parameter_count()} parameters, {layout.VERSION})")

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(out_path))
    return out_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()
    saved = export(arguments.checkpoint, arguments.out)
    print(f"exported {saved}")
    print("try it: tapq replay --input capture.jsonl --labels labels.jsonl "
          f"--encoder-model {saved}")


if __name__ == "__main__":
    main()
