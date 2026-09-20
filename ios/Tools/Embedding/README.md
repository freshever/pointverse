# bge-small-zh-v1.5 Core ML conversion

Run from `ios/` in a Python virtual environment:

```sh
python -m pip install -r Tools/Embedding/requirements.txt
python Tools/Embedding/convert_bge_small_zh_v15.py
```

The script creates `PointVerseApp/Resources/Embedding/BGESmallZhV15.mlpackage` and
`bge-small-zh-v1.5-vocab.txt`. Regenerate the Xcode project with `xcodegen generate`,
then Xcode compiles the model into the `BGESmallZhV15.mlmodelc` resource expected by
the app. The model and tokenizer must always be updated as one versioned pair.

The first bundled model uses Float32 compute. A blanket Float16 conversion overflows
the BERT attention-mask constant and produces NaN vectors; use mixed precision only
after an output-parity test passes.

For the multilingual production model:

```sh
python Tools/Embedding/convert_multilingual_e5_small.py
```

This exports `multilingual-e5-small` with Float32 compute and per-channel INT8 weights.
