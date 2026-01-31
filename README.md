# speechall

CLI for speech-to-text transcription via the [Speechall API](https://speechall.com).

Supports providers like OpenAI, Deepgram, AssemblyAI, Cloudflare, Groq, ElevenLabs, Google, Gemini, and more.

## Install

### Homebrew (macOS and Linux)

```bash
brew install Speechall/tap/speechall
```

### From source

Requires Swift 6.2+.

```bash
git clone https://github.com/Speechall/speechall-cli.git
cd speechall-cli
swift build -c release
cp .build/release/speechall /usr/local/bin/
```

## Setup

Get an API key from [speechall.com](https://speechall.com) and either export it or pass it directly:

```bash
export SPEECHALL_API_KEY="your-key"
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

# Pass API key directly
speechall audio.wav --api-key your-key

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
