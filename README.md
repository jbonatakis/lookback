# Lookback

Lookback is a read-only Swift library for exploring local Claude Code, Codex, Pi, and Google Antigravity CLI sessions. The package requires Swift 6 and targets macOS 13 and later. It uses Foundation and has no external package dependencies.

Lookback is released under the [MIT License](LICENSE).

## Try the example

Run these commands from the Lookback repository.

```sh
swift run lookback-demo                # Preview the most recently updated session
swift run lookback-demo --list         # List sessions with IDs and titles
swift run lookback-demo SESSION_ID     # Preview a session by its ID
swift run lookback-demo --source codex --list
swift run lookback-demo --source codex SESSION_ID
```

The [example program](Examples/LookbackDemo/main.swift) shows recent conversation excerpts, the most-used tools, and message counts for the active conversation and the full recorded history.

## Documentation

- [Reading sessions](docs/reading-sessions.md) — reading Claude Code, Codex, Pi, and Google Antigravity CLI sessions, choosing a view, adding providers, and compatibility notes.
