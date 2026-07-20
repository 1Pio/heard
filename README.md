# heard

[![CI](https://github.com/1Pio/heard/actions/workflows/ci.yml/badge.svg)](https://github.com/1Pio/heard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`heard` is one local command that keeps a timestamped, agent-readable memory of
speech around your Mac. It is deliberately not a meeting-notes app: no UI, no
summaries, no cloud, no database, and no automatic retention policy.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 16 or newer, including Swift 6
- Approximately 500 MB for local models downloaded on first use

## Install

```sh
git clone https://github.com/1Pio/heard.git
cd heard
./install.sh
```

The installer builds from source and atomically installs the executable to
`${XDG_BIN_HOME:-~/.local/bin}/heard`.

## Usage

```sh
heard start             # microphone + Zoom/Meet/system audio
heard pause             # models stay loaded; start resumes
heard stop              # flush pending speech and stop
heard status            # includes the exact memory path
heard follow            # show the last 10 records, then follow live JSONL
heard follow --simple --since 5m
heard forget --before 2026-07-12T12:00:00Z
heard forget --all
```

Use `heard start --mic-only` when system audio is not needed. The first start
downloads local models (about 450 MB for ASR plus smaller VAD/speaker models) and
macOS asks for microphone and, unless `--mic-only` is used, Screen & System Audio
Recording permission.

## Excluding app audio

Heard can prevent selected applications from contributing any system audio. Put
their bundle identifiers in the user config shown by `heard status`. The default
location is `~/.config/heard/config.json`, or `$XDG_CONFIG_HOME/heard/config.json`
when `XDG_CONFIG_HOME` is set. If `HEARD_HOME` is set, the config moves with the
rest of Heard's state to `$HEARD_HOME/config.json`.

For example, this permanently excludes Apple Music:

```json
{
  "excludedApps": ["com.apple.Music"]
}
```

Bundle identifiers are used because app display names can change, be localized,
or collide. Exclusions are case-insensitive, additive, and deduplicated. A
one-session exclusion can also be supplied with a repeatable flag:

```sh
heard start --exclude-app com.apple.Music
heard start --exclude-app com.apple.Music --exclude-app com.spotify.client
```

Start flags are added to the configured exclusions. If Heard is already running
and the effective capture options changed, stop and start it so the new options
take effect. Heard applies exclusions in ScreenCaptureKit before audio reaches
speech detection or transcription. It also watches app launches and exits,
temporarily pauses system-audio delivery while rebuilding the filter, and drops
buffered system speech whenever the filter changes. If a live filter update
fails, system-audio delivery stays paused instead of continuing unfiltered. If
a configured app is already running but ScreenCaptureKit cannot resolve it,
Heard leaves system audio unavailable and continues with microphone capture.

## Following memory

`heard follow` is the human-facing equivalent of remembering the memory path and
running `tail -f` yourself. It prints the last 10 records, then streams new ones:

```sh
heard follow
```

Raw output remains the original agent-readable JSONL. `--simple` hides lifecycle
events and prints only each utterance timestamp and text. `--since` adds all
matching history from a compact lookback before continuing to follow:

```sh
heard follow --simple
heard follow --simple --since 5m
heard follow --since 30s
```

Lookbacks accept seconds (`s`), minutes (`m`), hours (`h`), and days (`d`). If a
`forget` command atomically replaces the memory file while a follower is open,
the follower switches to the new file and continues from its end.

## Memory contract

The default memory is `~/.local/share/heard/memory.jsonl`. Set `HEARD_HOME` to
move the complete state directory. Every line is a standalone JSON object:

```json
{"end":"2026-07-12T12:00:04.500Z","session":"...","source":"microphone","speaker":"you","start":"2026-07-12T12:00:01.200Z","text":"Let's prototype the new flow.","ts":"2026-07-12T12:00:04.500Z","type":"utterance","v":1}
```

- Records are appended and fsynced individually, so agents can safely read or
  tail the file while capture continues.
- Speech is committed after a natural pause, normally within about one second.
  Long uninterrupted turns are committed every five seconds with overlapping
  context and transcript-prefix de-duplication.
- Microphone speech is always `you`. System speech uses session-long voice
  embeddings (`remote-1`, `remote-2`, ...) so labels do not reset every chunk.
- `heard` never deletes, rotates, summarizes, or prunes memory automatically.
- `forget` is the only rewrite operation. It is explicit, atomic, preserves
  unknown/malformed records when using `--before`, and refuses to run while
  capture is active. `forget --all` removes every record, including malformed
  lines.
- The file contains text, timestamps, and lifecycle/error events, not raw audio.

For an agent, the last five minutes remain ordinary JSONL filtering. For a human,
the equivalent is `heard follow --simple --since 5m`. An agent can still use the
raw file directly, for example:

```sh
python3 - <<'PY'
import json, pathlib, datetime
p = pathlib.Path.home()/'.local/share/heard/memory.jsonl'
cutoff = datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=5)
for line in p.open():
    row=json.loads(line)
    if row.get('type')=='utterance' and datetime.datetime.fromisoformat(row['ts'].replace('Z','+00:00')) >= cutoff:
        print(f"[{row['ts']}] {row['speaker']}: {row['text']}")
PY
```

## Reliability boundaries

Speaker diarization is intrinsically less reliable than source separation.
`you` versus `remote-*` is strong because microphone and system audio are
captured separately. Distinguishing two remote people is best effort and works
best for turns longer than one second; overlapping remote speech and very short
interjections may be labeled `remote` or attributed incorrectly. Speaker IDs are
stable within one running session, not asserted as identities across days.

System audio uses Apple's ScreenCaptureKit and excludes `heard` itself. It
captures Zoom, Meet, Teams, browser, and other app output without installing a
virtual audio driver. macOS permission changes may require restarting the CLI.

## Development

```sh
swift test
HEARD_HOME=/tmp/heard-test .build/debug/heard status
```

The engine is [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned
to 0.15.5. The project is intended for Apple Silicon and macOS 14 or newer.

## License

MIT. See [LICENSE](LICENSE).
