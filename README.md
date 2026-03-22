# Byblos

**Local voice-to-text. Private. Fast. Free.**

Byblos is an open-source voice-to-text app that runs entirely on your machine. No cloud, no subscriptions, no data leaves your computer.

Named after the [ancient Phoenician city](https://en.wikipedia.org/wiki/Byblos) where the alphabet was born, and [BBN's pioneering ASR system](https://en.wikipedia.org/wiki/BBN_Technologies).

## Features

**Voice to Text**
- Whisper speech recognition with Metal GPU acceleration
- Streaming partial results — see text as you speak
- Auto-stop on silence detection
- Single-click or hold-to-record hotkey
- Types directly into any app via Accessibility API

**Dictation Modes**
- **Clean** — removes filler words, fixes punctuation
- **Email** — professional tone with paragraph structure
- **Notes** — converts speech to bullet points
- **Code Comment** — concise, prefixed with `//`
- **Translate** — speak any language, output in English
- **Agent** — AI assistant that reads your screen, searches files, controls apps
- **Raw** — exact transcription, no processing

**Smart Features**
- App-aware mode switching (auto-selects Email in Mail, Code in VS Code, etc.)
- Local LLM post-processing (Phi-3.5 / Qwen 7B via llama.cpp)
- Audio file transcription (drag-and-drop WAV, MP3, M4A, MP4)
- Transcript workspace with search and history
- 18 languages supported

**Privacy First**
- Everything runs locally — voice, LLM, all processing
- No network calls, no telemetry, no accounts
- Open source — audit the code yourself

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon recommended (Metal GPU acceleration)
- ~500MB for Whisper base model
- ~4.5GB for local LLM (optional, for AI-powered modes)

## Quick Start

```bash
# Clone
git clone https://github.com/jb1999/byblos.git
cd byblos

# Install dependencies
./scripts/setup.sh

# Download a speech model
./scripts/download-model.sh whisper-base-en

# Build
./scripts/build.sh
```

Or download from [byblos.im](https://byblos.im).

## Architecture

```
byblos/
├── core/           # Rust engine — Whisper, audio, VAD, text processing, FFI
├── llm-helper/     # Rust — separate process for local LLM (avoids ggml conflicts)
├── macos/          # Swift/AppKit — menu bar app, UI, system integration
├── models/         # Model configs (TOML)
└── scripts/        # Build, setup, model download
```

The Rust core handles speech recognition (whisper.cpp with Metal), audio capture (cpal), resampling, VAD, and text processing. It exposes a C FFI that the native macOS app (Swift/AppKit) consumes.

The LLM runs in a separate helper process (`byblos-llm`) to avoid Metal backend conflicts between whisper.cpp and llama.cpp. Communication is via JSON over stdin/stdout.

## Models

**Speech (Whisper)**
| Model | Size | Speed | Quality |
|---|---|---|---|
| Tiny | 75 MB | Fastest | Basic |
| Base | 142 MB | Fast | Good |
| Small | 466 MB | Moderate | Better |
| Medium | 1.5 GB | Slower | High |
| Large v3 | 1.5 GB | Slowest | Best |
| Turbo | 809 MB | Fast | Excellent |
| Distil-Large v3 | 756 MB | Very fast | Near-large |

Download via Settings → Models or `./scripts/download-model.sh <model-name>`.

**LLM (optional, for AI modes)**

Place any GGUF model in `~/Library/Application Support/Byblos/llm-models/`. Recommended: Qwen2.5-7B-Instruct-Q4_K_M (~4.5GB).

## Shareware

Byblos is free to use with no restrictions. If it becomes part of your workflow, consider getting an [annual license](https://byblos.im/#support) to support development.

## License

MIT
