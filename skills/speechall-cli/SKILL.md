---
name: speechall-cli
description: "Install and use the speechall CLI tool for speech-to-text transcription. Use when the user wants to: (1) transcribe audio or video files to text, (2) install speechall on macOS or Linux, (3) list available STT models and their capabilities, (4) use speaker diarization, subtitles, or other transcription features from the terminal, (5) check or set up the Speechall API key (`speechall auth status`, `speechall auth login`). Triggers on mentions of speechall, audio transcription CLI, or speech-to-text from the command line."
---

# speechall-cli

CLI for speech-to-text transcription via the Speechall API. Supports multiple providers (OpenAI, Deepgram, AssemblyAI, Google, Gemini, Groq, ElevenLabs, Cloudflare, and more).

## Installation

### Homebrew (macOS and Linux)

```bash
brew install Speechall/tap/speechall
```

**Without Homebrew**: Download the binary for your platform from https://github.com/Speechall/speechall-cli/releases and place it on your `PATH`.

### Verify

```bash
speechall --version
```

## Authentication

Before running any other command, check that an API key is available:

```bash
speechall auth status
```

- Exit code 0: a key is available. The output shows its source (`--api-key` flag, `SPEECHALL_API_KEY`, or stored key) and a masked form such as `****abcd`. Continue.
- Non-zero exit code: no key is available. Stop and ask the user to run this **in their own terminal** (not through you):

  ```bash
  speechall auth login
  ```

  It prompts for the key with input hidden, verifies it with the Speechall API, and stores it (macOS Keychain, or `~/.config/speechall/credentials` on Linux). The user can create a key at https://speechall.com/console/api-keys. After they confirm, run `speechall auth status` again.

**Never ask the user to paste their API key into the chat**, and never put a key in a command you run, in an environment variable you set, or in a file you write. If the user pastes a key into the chat anyway, do not use it; tell them to run `speechall auth login` in their terminal, and suggest they rotate the key since it is now in the conversation.

`speechall auth logout` deletes the stored key.

## Commands

### transcribe (default)

Transcribe an audio or video file. This is the default subcommand — `speechall audio.wav` is equivalent to `speechall transcribe audio.wav`.

```bash
speechall <file> [options]
```

**Options:**

| Flag | Description | Default |
|---|---|---|
| `--model <provider.model>` | STT model identifier | `openai.gpt-4o-mini-transcribe` |
| `--language <code>` | Language code (e.g. `en`, `tr`, `de`) | API default (auto-detect) |
| `--output-format <format>` | Output format (`text`, `json`, `verbose_json`, `srt`, `vtt`) | API default |
| `--diarization` | Enable speaker diarization | off |
| `--speakers-expected <n>` | Expected number of speakers (use with `--diarization`) | — |
| `--no-punctuation` | Disable automatic punctuation | — |
| `--temperature <0.0-1.0>` | Model temperature | — |
| `--initial-prompt <text>` | Text prompt to guide model style | — |
| `--custom-vocabulary <term>` | Terms to boost recognition (repeatable) | — |
| `--ruleset-id <uuid>` | Replacement ruleset UUID | — |

**Examples:**

```bash
# Basic transcription
speechall interview.mp3

# Specific model and language
speechall call.wav --model deepgram.nova-2 --language en

# Speaker diarization with SRT output
speechall meeting.wav --diarization --speakers-expected 3 --output-format srt

# Custom vocabulary for domain-specific terms
speechall medical.wav --custom-vocabulary "myocardial" --custom-vocabulary "infarction"

# Transcribe a video file (macOS extracts audio automatically)
speechall presentation.mp4
```

### models

List available speech-to-text models. Outputs JSON to stdout. Filters combine with AND logic.

```bash
speechall models [options]
```

**Filter flags:**

| Flag | Description |
|---|---|
| `--provider <name>` | Filter by provider (e.g. `openai`, `deepgram`) |
| `--language <code>` | Filter by supported language (`tr` matches `tr`, `tr-TR`, `tr-CY`) |
| `--diarization` | Only models supporting speaker diarization |
| `--srt` | Only models supporting SRT output |
| `--vtt` | Only models supporting VTT output |
| `--punctuation` | Only models supporting automatic punctuation |
| `--streamable` | Only models supporting real-time streaming |
| `--vocabulary` | Only models supporting custom vocabulary |

**Examples:**

```bash
# List all available models
speechall models

# Models from a specific provider
speechall models --provider deepgram

# Models that support Turkish and diarization
speechall models --language tr --diarization

# Pipe to jq for specific fields
speechall models --provider openai | jq '.[].identifier'
```

## Tips

- On macOS, video files (`.mp4`, `.mov`, etc.) are automatically converted to audio before upload.
- On Linux, pass audio files directly (`.wav`, `.mp3`, `.m4a`, `.flac`, etc.).
- Output goes to stdout. Redirect to save: `speechall audio.wav > transcript.txt`
- Errors go to stderr, so piping stdout is safe.
- If a command fails with "API key required" or HTTP 401, run `speechall auth status` and follow the Authentication section above.
- Run `speechall --help`, `speechall transcribe --help`, `speechall models --help`, or `speechall auth --help` to see all valid enum values for model identifiers, language codes, and output formats.
