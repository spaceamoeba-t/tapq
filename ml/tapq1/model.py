"""TapQ-1 stage-1 encoder: a LIMU-BERT-scale transformer for 25 Hz earbud IMU.

Sized to ~70k parameters — small enough for always-on ANE inference, large enough
for the 8-class window vocabulary. The same trunk serves masked-reconstruction
pretraining (unlabeled captures) and the supervised joint head.
"""

import torch
from torch import nn

from . import layout


class TapQ1Encoder(nn.Module):
    def __init__(self, d_model=64, n_layers=2, n_heads=4, d_ff=128, dropout=0.1):
        super().__init__()
        self.input_projection = nn.Linear(layout.CHANNEL_COUNT, d_model)
        self.positional = nn.Parameter(torch.zeros(layout.WINDOW_LENGTH, d_model))
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=n_heads, dim_feedforward=d_ff,
            dropout=dropout, activation="gelu", batch_first=True, norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(encoder_layer, n_layers)
        self.norm = nn.LayerNorm(d_model)
        self.classifier = nn.Linear(d_model, layout.CLASS_COUNT)
        self.reconstructor = nn.Linear(d_model, layout.CHANNEL_COUNT)
        nn.init.trunc_normal_(self.positional, std=0.02)

    def features(self, x):
        """[B, WINDOW_LENGTH, 9] → per-timestep features [B, WINDOW_LENGTH, d]."""
        return self.norm(self.encoder(self.input_projection(x) + self.positional))

    def forward(self, x):
        """Class logits [B, CLASS_COUNT] via mean pooling."""
        return self.classifier(self.features(x).mean(dim=1))

    def reconstruct(self, x):
        """Per-timestep channel reconstruction, for masked pretraining."""
        return self.reconstructor(self.features(x))

    def parameter_count(self):
        return sum(parameter.numel() for parameter in self.parameters())


class ExportWrapper(nn.Module):
    """Inference-only view matching the runtime contract: probabilities, not
    logits, so `EncoderMotionPipeline` thresholds are calibrated quantities."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, features):
        return torch.softmax(self.encoder(features), dim=-1)
