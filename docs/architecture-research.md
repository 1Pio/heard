# Architecture research

Research date: 2026-07-12. The target machine was an Apple M5 Pro Mac with
24 GB RAM on macOS 26.4. The selection criterion was not maximum benchmark
accuracy in isolation; it was reliable unattended local operation, low latency,
stable installability, permissive licensing, and an agent-readable live file.

## Closest complete products

### Muesli

[Muesli](https://github.com/pHequals7/muesli) is the closest existing system. It
is MIT-licensed, native Swift, local, captures microphone and system audio,
uses VAD-driven chunks, transcribes during meetings, and diarizes remote
speakers. It provides strong evidence that this exact pipeline works on current
macOS. It was not adopted directly because recording is controlled by a GUI and
its agent CLI reads completed database records; the desired contract is one
background CLI writing a continuously readable append-only file. Its capture
and model choices strongly informed `heard`.

### Meeting-transcription CLIs

[ownscribe](https://github.com/paberr/ownscribe),
[MeetScribe](https://github.com/pretyflaco/meetscribe), and related projects are
oriented around record-then-process meeting artifacts, summaries, and exports.
They are broader than the request and generally do not expose a durable live
append stream. WhisperX-based variants also inherit a heavier Python/PyTorch
stack and post-processing diarization.

## Engines considered

### FluidAudio: selected

[FluidAudio](https://github.com/FluidInference/FluidAudio) is Apache-2.0 Swift
software for local ASR, Silero VAD, and speaker embedding/diarization on Apple
devices. It runs models through Core ML and the Apple Neural Engine. Parakeet
TDT v3 provides punctuation, confidence, token timing, and 25-language support;
the model is roughly 450 MB. Models download once and require no account or
Hugging Face token. The library has explicit streaming APIs, but VAD-bounded
batch turns were chosen for committed memory because final-only records are
materially easier to keep append-only than mutable partial hypotheses.

FluidAudio also exposes 256-dimensional speaker embeddings and a persistent
`SpeakerManager`. `heard` uses one manager for the entire process session, so
speaker labels are not reclustered from scratch on every five-second chunk.
FluidAudio's own [benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
warn that true online multi-speaker diarization is fragile and can be 10-15%
worse than offline. `heard` therefore makes the strongest reliable distinction
first: microphone is `you`, system audio is remote. Embedding clustering then
provides best-effort `remote-N` labels.

### whisper.cpp

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) is an excellent portable
MIT-licensed Whisper runtime with Metal/Core ML acceleration. Its
[`whisper-stream`](https://github.com/ggml-org/whisper.cpp/tree/master/examples/stream)
example samples a microphone every 500 ms and supports a sliding-window mode,
but its README calls the example naive and notes its basic VAD. Speaker
diarization and system-audio source separation would still need separate
components. It remains the best portability fallback if this tool is later
extended beyond Apple platforms.

### sherpa-onnx

[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) is Apache-2.0, genuinely
offline, cross-platform, and unusually complete: streaming and offline ASR,
Silero VAD, speaker identification, and diarization APIs. It was the strongest
cross-platform alternative. FluidAudio was preferred here because it provides
a smaller native integration surface and direct Apple Neural Engine execution
on this specific Mac. sherpa-onnx is the recommended foundation for a future
Linux/Windows port.

### faster-whisper and WhisperX

[faster-whisper](https://github.com/SYSTRAN/faster-whisper) is fast on supported
CUDA systems, but its GPU path requires NVIDIA CUDA/cuDNN; CTranslate2 does not
provide an MPS backend for Apple GPUs. CPU mode would discard much of this
machine's advantage. [WhisperX](https://github.com/m-bain/whisperX) adds accurate
alignment and pyannote diarization, but is primarily a post-processing pipeline,
adds PyTorch and model-authentication complexity, and has a documented history
of very slow diarization on Apple Silicon. It is useful for high-quality offline
reprocessing, not the smallest reliable always-on process here.

## macOS audio capture

Three approaches were evaluated:

- A virtual loopback driver can combine system and microphone audio, but adds
  installation, routing, echo, and device-state failure modes.
- Apple's Core Audio process taps are the modern native system-audio API.
  [AudioCap](https://github.com/insidegui/AudioCap) documents the setup. They
  require an aggregate device and more recovery logic; current developer reports
  also describe long-running zero-filled tap buffers in some configurations.
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  captures system audio without a driver and has a much smaller implementation.
  [systemAudioDump](https://github.com/sohzm/systemAudioDump) demonstrates a
  working CLI form.

`heard` uses AVAudioEngine for the microphone and ScreenCaptureKit for system
audio, keeping them as independent streams. This avoids acoustic echo and makes
the `you` versus `remote` attribution deterministic. It excludes the tool's own
process audio. The tradeoff is macOS's Screen & System Audio Recording
permission. Core Audio taps remain a plausible later swap if a concrete route
shows ScreenCaptureKit instability.

## Commit and storage design

Mutable partial transcription is unsuitable for an append-only memory because
every correction either rewrites prior bytes or leaves contradictory records.
The chosen design runs VAD every 256 ms, waits about 650 ms for a natural pause,
and commits only final text. Uninterrupted speech is bounded at five seconds with
overlap-prefix de-duplication. Resulting latency is normally about one second
after a person pauses, while records remain final and monotonically appended.

JSONL was chosen over SQLite and Markdown because:

- a reader can tail it during writes without a database client;
- each fsynced line is an independently recoverable record;
- agents can filter the last five minutes with standard tools;
- lifecycle, warning, and future-version records coexist with utterances;
- explicit retention can be implemented as one atomic replacement.

Normal operation never seeks backwards or rewrites. `forget --before` is the
only exception because physical deletion is impossible in a strictly
append-only file. It refuses to run during capture, retains records it cannot
parse, writes a permission-restricted replacement, then atomically swaps it in.
