# Contributing

Contributions should preserve heard's narrow contract: one local CLI, final
append-only transcript records, no cloud dependency, and no automatic memory
deletion.

## Development

Requirements are listed in the README. From the repository root:

```sh
swift package resolve
swift build
swift test
```

Keep changes focused. Do not commit `.build`, model caches, runtime memory,
audio recordings, logs, credentials, or machine-specific paths. Integration
tests that download models are opt-in through `HEARD_INTEGRATION_AUDIO`; the
default suite must remain self-contained.

Open a pull request describing the user-visible behavior, reliability tradeoffs,
and exact checks performed. For audio-pipeline changes, include evidence from a
real continuous capture session rather than relying only on compilation.
