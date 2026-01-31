After you are done with an implementation run `swift build`. If you see any compiler errors, fix them.

## Verification

After changes, run quick CLI checks:

- `swift build`
- `swift run speechall models`
- `swift run speechall models --provider deepgram`
- `swift run speechall models --language tr`
- `swift run speechall models --diarization --srt`
- `swift run speechall "/Users/atacan/Downloads/09c18f21-c1c2-4739-b33a-3637f1b55c4b.wav"`

## Design Principles

- **AI-agent-first**: The primary users of this CLI are LLMs and AI coding agents. Default output formats should be plain text or machine-parseable (JSON).
- **Self-documenting**: `--help` must contain every piece of information a user needs — all valid enum values listed inline, no external docs required.
