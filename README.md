# speechall

CLI for speech-to-text transcription via the [Speechall API](https://speechall.com).

Supports providers like OpenAI, Deepgram, AssemblyAI, Cloudflare, Groq, ElevenLabs, Gemini, Smallest AI, Soniox, and more.

## Install

### Homebrew (macOS and Linux)

```bash
brew install Speechall/tap/speechall
```

### AI Agent Skill

This is a great tool to let your agent to transcribe your recordings into plain text or subtitles. To add this skill to your AI agent:

```bash
npx skills add https://github.com/Speechall/speechall-cli --skill speechall-cli
```

It is available also for OpenClaw at [clawhub](https://clawhub.ai/atacan/speechall-cli)

### From source

Requires Swift 6.2+.

```bash
git clone https://github.com/Speechall/speechall-cli.git
cd speechall-cli
swift build -c release
cp .build/release/speechall /usr/local/bin/
```

## Setup

Get an API key from [speechall.com](https://speechall.com/console/api-keys) and store it once:

```bash
speechall auth login            # prompts with input hidden
pbpaste | speechall auth login  # or read one line from stdin
speechall auth login < keyfile
```

The key is checked against the API before it is saved, and the command never takes the key as an argument, so it stays out of your shell history and process list. Where it is stored:

- **macOS**: the login Keychain (generic password, service `com.speechall.cli`).
- **Linux**: `$XDG_CONFIG_HOME/speechall/credentials` (default `~/.config/speechall/credentials`). The directory is created with mode `0700` and the file with mode `0600`.

```bash
speechall auth status   # shows the key source and a masked key; exits 0 if a key is available, 1 if not
speechall auth logout   # deletes the stored key
```

### Key resolution order

Every command that calls the API looks for a key in this order:

1. `--api-key <key>` flag
2. `SPEECHALL_API_KEY` environment variable
3. The stored key from `speechall auth login`

The flag and environment variable still work for CI and one-off overrides:

```bash
export SPEECHALL_API_KEY="your-key"
speechall audio.wav --api-key your-key
```

## Usage

```bash
# Transcribe an audio file
speechall audio.wav

# Specify a model
speechall audio.wav --model deepgram.nova-2

# Choose output format
speechall audio.wav --output-format srt

# Enable speaker diarization
speechall audio.wav --diarization --speakers-expected 3

# List available models
speechall models

# Filter models by provider or capability
speechall models --provider deepgram
speechall models --language tr
speechall models --diarization --srt
```

### Querying models with jq

`speechall models` outputs JSON, so you can pipe it to `jq` for advanced queries:

```bash
# Cheapest Deepgram model with SRT support
speechall models --provider deepgram --srt | jq 'sort_by(.cost_per_second_usd) | .[0].id'

# All model IDs that support Turkish
speechall models --language tr | jq '[.[].id]'

# Compare diarization models by price
speechall models --diarization | jq '[.[] | {id, cost: .cost_per_second_usd}] | sort_by(.cost)'

# List all providers
speechall models | jq '[.[].provider] | unique'

# Models that support both streaming and custom vocabulary
speechall models --streamable --vocabulary | jq '[.[].id]'
```

Run `speechall --help` for all options.

## License

[MIT](LICENSE)
