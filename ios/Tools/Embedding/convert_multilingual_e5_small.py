#!/usr/bin/env python3
"""Convert multilingual-e5-small to Core ML with Float32 compute and INT8 weights."""

from pathlib import Path
import argparse
import shutil

import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer


class Encoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        return self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            return_dict=False,
        )[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("PointVerseApp/Resources/Embedding"))
    parser.add_argument("--max-length", type=int, default=128)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    model_id = "intfloat/multilingual-e5-small"
    tokenizer = AutoTokenizer.from_pretrained(model_id)
    encoder = Encoder(AutoModel.from_pretrained(model_id).eval()).eval()
    shape = (1, args.max_length)
    example = tuple(torch.zeros(shape, dtype=torch.int32) for _ in range(2))
    traced = torch.jit.trace(encoder, example)

    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="last_hidden_state")],
    )
    quantized = linear_quantize_weights(
        converted,
        config=OptimizationConfig(global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"
        )),
    )
    quantized.author = "PointVerse / intfloat"
    quantized.short_description = "multilingual-e5-small; Float32 compute, INT8 weights, mean pooling in Swift."

    package_path = args.output / "MultilingualE5Small.mlpackage"
    tokenizer_path = args.output / "multilingual-e5-small-tokenizer"
    if package_path.exists(): shutil.rmtree(package_path)
    if tokenizer_path.exists(): shutil.rmtree(tokenizer_path)
    quantized.save(package_path)
    tokenizer.save_pretrained(tokenizer_path)


if __name__ == "__main__":
    main()
