#!/usr/bin/env python3
"""Convert BAAI/bge-small-zh-v1.5 to the Core ML package consumed by PointVerse."""

from pathlib import Path
import argparse
import shutil

import coremltools as ct
import torch
from transformers import AutoModel, AutoTokenizer


class Encoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask, token_type_ids):
        return self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            return_dict=False,
        )[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("PointVerseApp/Resources/Embedding"))
    parser.add_argument("--max-length", type=int, default=128)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    model_id = "BAAI/bge-small-zh-v1.5"
    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModel.from_pretrained(model_id).eval()
    shape = (1, args.max_length)
    example = tuple(torch.zeros(shape, dtype=torch.int32) for _ in range(3))
    traced = torch.jit.trace(Encoder(model), example)

    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        # BERT builds its attention mask with a very large negative Float32 value.
        # Blind FP16 conversion overflows that constant and produces NaN embeddings.
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=int),
            ct.TensorType(name="attention_mask", shape=shape, dtype=int),
            ct.TensorType(name="token_type_ids", shape=shape, dtype=int),
        ],
        outputs=[ct.TensorType(name="last_hidden_state")],
    )
    converted.author = "PointVerse / BAAI"
    converted.short_description = "bge-small-zh-v1.5 Float32 token embeddings; CLS pooling is performed in Swift."
    package_path = args.output / "BGESmallZhV15.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    converted.save(package_path)
    vocabulary = sorted(tokenizer.get_vocab().items(), key=lambda item: item[1])
    (args.output / "bge-small-zh-v1.5-vocab.txt").write_text(
        "\n".join(token for token, _ in vocabulary) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
