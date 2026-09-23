# Heard

[![CI](https://github.com/1Pio/heard/actions/workflows/ci.yml/badge.svg)](https://github.com/1Pio/heard/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Heard records separate microphone and Mac output tracks and streams each to [ElevenLabs Scribe v2 Realtime](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime). It writes final, timestamped utterances to a local JSONL file that an agent can follow while a meeting is running. The microphone is labeled `you`; Mac output is labeled `remote`. Heard does not infer names or distinguish people mixed together in the system track.

## Requirements and install

- Apple Silicon Mac running macOS 14.2 or newer, Xcode 16 or newer
- ElevenLabs API key with Speech to Text access and available credits
- Microphone and Screen & System Audio Recording permissions

```sh
git clone https://github.com/1Pio/heard.git
cd heard
./install.sh
```

The installer builds from source and atomically installs `${XDG_BIN_HOME:-~/.local/bin}/heard`. It does not install a background service or change the Mac's output device. The launcher must have the required macOS capture permissions.

## Credential setup

`ELEVENLABS_API_KEY` takes precedence when present and nonempty. For GUI launchers such as Stream Deck, select an existing Keychain generic-password item in Heard's **local, uncommitted** config. The config contains only the service and account names, never the key:

```json
{
  "elevenLabsKeychain": {
    "service": "your-keychain-service",
    "account": "your-keychain-account"
  },
  "excludedApps": []
}
```

Create or edit `~/.config/heard/config.json` (or `$XDG_CONFIG_HOME/heard/config.json`). `heard status` prints the active config path. With `HEARD_HOME`, the config is `$HEARD_HOME/config.json`. Protect it with `chmod 600`; Heard never writes an API key to it or to a log. An installation without the environment variable or a valid Keychain selector receives a setup error.

## Live use

```sh
heard start                   # mic + whole-Mac output
heard status                  # capture, callback and error state
heard follow --since 5m      # existing context, then continuous JSONL
heard follow --simple         # compact human view
heard pause
heard start                   # resume
heard stop                    # finish pending speech and close recordings
```

`heard start --mic-only` avoids system capture. `heard start --exclude-app com.apple.Music` excludes an app from the system tap for this run; `excludedApps` in the local config supplies persistent exclusions. Restart after changing the configured list. The global Core Audio tap captures the Mac's output mix, including conference audio, without selecting a display, app, or virtual device. Heard pauses delivery and rebuilds the tap when a listed app launches or exits; a failed exclusion refresh leaves system delivery unavailable and reports an error. If Core Audio setup fails, Heard tries ScreenCaptureKit and reports which source is unavailable.

Heard keeps the mic and system tracks separate through capture and transcription. They can overlap in time. Only ElevenLabs' delayed `committed_transcript_with_timestamps` events enter the canonical log; changing partials do not. The active model is `scribe_v2_realtime` on both tracks. A disconnected transcription stream leaves local recording active and reconnects with bounded backoff. Capture and transcription gaps appear as explicit events.

### Agent following

Keep one `heard follow --since 5m` process open in a persistent terminal or tool session. Its default output is one JSON object per line and streams new records as they are fsynced. The agent can wait on that process for new output rather than rerunning extraction every few seconds. Start capture for an identified live meeting, check `heard status`, then consume `utterance` and gap/error events by `session` and `sequence`. If the follower reconnects, reread the recent meeting interval and deduplicate by event identity. A notification that Heard started is not proof that both audio tracks are producing speech; inspect callback freshness and the latest source events.

`heard follow --simple` prints text only for people reading along. `--since` accepts `s`, `m`, `h`, and `d`. The follower handles an explicit `heard forget` replacement of the memory file.

## Local data and event contract

The default data root is `~/.local/share/heard`, or `$HEARD_HOME`. `memory.jsonl` is append-only until an explicit `heard forget`; state and health files are also local. Each final utterance has fractional-second `start`, `end`, and `ts`, a session-scoped `sequence`, `source`, `speaker`, `model`, `timing`, text, available word timestamps, and `receivedAt` for measuring delivery delay:

```json
{"v":2,"type":"utterance","session":"...","sequence":12,"source":"microphone","speaker":"you","model":"scribe_v2_realtime","start":"2026-09-23T10:00:01.200Z","end":"2026-09-23T10:00:02.400Z","ts":"2026-09-23T10:00:02.400Z","text":"Let's start.","timing":"word","words":[{"text":"Let's","start":"2026-09-23T10:00:01.200Z","end":"2026-09-23T10:00:01.600Z"}]}
```

The example omits optional fields. A track's committed utterances are ordered and do not overlap each other; `you` and `remote` are allowed to overlap. `timing` marks provider word timing, shifted timing when an upstream timestamp regresses, or an estimate when word timing is absent. A `remote` label means only “heard in Mac output.”

Heard also rotates one-minute mono 16 kHz PCM WAV files in `recordings/<session>/`, one series per source. These files preserve the exact audio sent to Scribe for recovery or later evaluation. They are private local data, not automatically pruned. Audio and transcript data are sent to ElevenLabs for transcription under that service's terms.

`heard forget --before ISO_TIME` and `heard forget --all` explicitly rewrite memory only while capture is stopped. They do not delete the WAV recordings.

## Development and replay

```sh
swift test
HEARD_HOME=/tmp/heard-test .build/debug/heard status
HEARD_HOME=/tmp/heard-test .build/debug/heard replay --file /path/to/meeting.m4a --start 60 --duration 30 --source system
```

Replay uses `ffmpeg` to decode the selected interval and streams it at real speed through Scribe. A mixed recording is useful to inspect transcription, but separate mic and system files are needed to evaluate overlapping speakers. The legacy FluidAudio implementation remains in source for comparison; it is not the live default and its models are not downloaded at startup.

## License

MIT. See [LICENSE](LICENSE).
