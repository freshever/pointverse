"""Normalize Chinese ASR output without rewriting other languages or timestamps."""
from opencc import OpenCC


def transcription_result(segments, language, model):
    raw = "".join(segment["text"] for segment in segments).strip()
    output = [dict(segment) for segment in segments]
    result = {"model": model, "language": language}
    if language in ("zh", "yue"):
        converter = OpenCC("t2s")
        for segment in output:
            segment["text"] = converter.convert(segment["text"])
        result["text_script"] = "Hans"
    text = "".join(segment["text"] for segment in output).strip()
    result.update(text=text, segments=output)
    if text != raw:
        result["raw_text"] = raw
    return result
