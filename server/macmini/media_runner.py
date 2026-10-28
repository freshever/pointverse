"""One inference per process; all weights are local and released on exit."""
import contextlib
import json
import os
import sys
from pathlib import Path

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")

def run(kind, root, payload):
    import torch
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    metadata = json.loads((root / "revision.json").read_text())
    identity = metadata["repo"] + "@" + metadata["revision"]
    if kind == "embeddings":
        from transformers import AutoTokenizer, AutoModel
        tokenizer = AutoTokenizer.from_pretrained(root, local_files_only=True)
        model = AutoModel.from_pretrained(root, local_files_only=True, use_safetensors=True).eval()
        inputs = tokenizer([payload["input_type"] + ": " + text for text in payload["input"]], max_length=512, padding=True, truncation=True, return_tensors="pt")
        with torch.inference_mode():
            hidden = model(**inputs).last_hidden_state
            mask = inputs["attention_mask"].unsqueeze(-1)
            vectors = torch.nn.functional.normalize((hidden * mask).sum(1) / mask.sum(1).clamp(min=1), p=2, dim=1)
        return {"object": "list", "model": identity, "dimension": 384, "input_type": payload["input_type"],
                "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vectors.tolist())]}
    if kind == "audio":
        import numpy as np
        import soundfile as sf
        from scipy.signal import resample_poly
        from transformers import ClapModel, ClapProcessor
        audio, sample_rate = sf.read(payload["audio_path"], dtype="float32")
        audio = resample_poly(audio, 48000, sample_rate).astype(np.float32)
        processor = ClapProcessor.from_pretrained(root, local_files_only=True)
        # The upstream repository publishes a .bin; PyTorch's restricted loader
        # is required. No remote model code or arbitrary pickle objects execute.
        model = ClapModel.from_pretrained(root, local_files_only=True, weights_only=True).eval()
        candidates = payload["candidates"]
        batch = processor(text=["This is a sound of " + x for x in candidates], audios=audio, sampling_rate=48000, return_tensors="pt", padding=True)
        with torch.inference_mode():
            output = model(**batch)
            scores = output.logits_per_audio.softmax(-1)[0].tolist()
        ranked = sorted(zip(candidates, scores), key=lambda x: x[1], reverse=True)
        return {"model": identity, "scores_relative": True, "labels": [{"label": x, "score": y} for x, y in ranked],
                "embedding": output.audio_embeds[0].tolist(), "dimension": 512}
    if kind == "image":
        from diffusers import StableDiffusionPipeline, DPMSolverMultistepScheduler
        torch.mps.set_per_process_memory_fraction(0.75)
        # Read compact fp16 weights, but compute in float32: this Mac's MPS
        # fp16 path produced NaN pixels. Keep the bundled safety checker intact.
        pipeline = StableDiffusionPipeline.from_pretrained(root, torch_dtype=torch.float32, variant="fp16", use_safetensors=True, local_files_only=True)
        pipeline.scheduler = DPMSolverMultistepScheduler.from_config(pipeline.scheduler.config)
        pipeline.to("mps")
        pipeline.enable_attention_slicing()
        pipeline.enable_vae_slicing()
        generator = torch.Generator(device="cpu").manual_seed(payload["seed"])
        result = pipeline(payload["prompt"], width=512, height=512, num_inference_steps=20, guidance_scale=7.0, generator=generator)
        if result.nsfw_content_detected and any(result.nsfw_content_detected):
            raise ValueError("image_filtered")
        result.images[0].save(payload["output_path"], format="PNG")
        return {"model": identity, "seed": payload["seed"], "size": "512x512"}
    raise ValueError("unknown_capability")

if __name__ == "__main__":
    payload = json.load(sys.stdin)
    with contextlib.redirect_stdout(sys.stderr):
        result = run(sys.argv[1], Path(sys.argv[2]), payload)
    print(json.dumps(result, allow_nan=False))
