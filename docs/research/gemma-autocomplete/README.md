# Gemma 3 270M autocomplete experiment

Measured locally on 2026-10-12 on Apple M1, 8 GB unified memory, Ollama 0.23.0. No cloud inference. This is a small smoke experiment, not a production benchmark or a comparison against larger models.

## Model and configuration

`ollama pull gemma3:270m` completed successfully. The model was already installed; pull verified the current manifest and reused its weights. Actual installed model: 268.10M parameters, GGUF Q8_0, digest `e7d36fb2c3b3293cfe56d55889867a064b3a2b22e98335f2e6e8a387e081d6be`, approximately 292 MB on disk. This is the default Ollama tag, not a 4-bit model.

Tests used a 1024-token context, greedy decoding (`temperature: 0`), seed 42, and at most 80 generated tokens for the primary test. Requests ran sequentially through the localhost streaming API. First-text latency is wall time to the first nonempty response chunk; total latency includes the complete response and HTTP overhead. Empty responses have no first-text measurement.

## Observations

- After explicitly unloading this model, the first request took 1,892 ms total, with first text at 1,756 ms. Ollama reported 1,166 ms load duration. This is a model reload with the OS file cache potentially warm, not a first-ever launch or reboot test.
- In the next eight requests, nonempty first-text latencies ranged from 128 to 159 ms. Total response latencies ranged from 140 to 616 ms, including empty or unhelpful responses. These timings do not establish the speed of useful suggestions.
- Ollama reported a 502,604,320-byte model allocation (about 503 MB decimal / 479 MiB), entirely on GPU, at 1024 context tokens. This is not total application memory. A process snapshot showed runner RSS about 331 MiB; RSS and unified GPU memory overlap and must not be added as independent allocations.
- `best laptop for` returned three plausible queries: gaming, video editing, photo editing, in 370 ms total.
- `как приготовить` returned an English query; `погода в` and `купить` returned empty responses in the primary test.
- Russian instructions, few-shot examples, and requesting a single completion failed to consistently produce useful Russian extensions. A raw assistant-prefill attempt also returned empty Russian suffixes.

## Decision

The model runs quickly once loaded, but this checkpoint is not suitable for Russian query autocomplete out of the box in these tests. Do not integrate it into the live omnibox based on latency alone. Compare a stronger multilingual checkpoint or a task-tuned model before selecting an AI provider. Evaluate usefulness, prefix preservation, duplicates, language, complete-list latency, and cancellation under real typing.

Immediate suggestions from known domains, browsing/search history, and open tabs can operate independently of a model.

## Reproduction and evidence

With Ollama running and the model installed, execute `python3 docs/research/gemma-autocomplete/benchmark.py`. The script unloads only `gemma3:270m` before the first request, then keeps it alive for five minutes and writes `results.json` beside itself. It sends only fixed synthetic prefixes and does not read browsing history. Timing will vary with other work, thermal state, caches, and Ollama/runtime versions.

- `results.json`: primary streaming test and Ollama allocation snapshot.
- `prompt-variants.json`: Russian, few-shot, and single-completion experiments (96-token cap).
- `prefill.json`: raw assistant-prefix experiment (24-token cap).

References: [Ollama model](https://ollama.com/library/gemma3:270m), [Ollama generate API](https://docs.ollama.com/api/generate), [Google model announcement](https://developers.googleblog.com/en/introducing-gemma-3-270m/).
