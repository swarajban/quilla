# quill

A minimal macOS meeting recorder + transcriber. One menu-bar click records
your mic and all system audio as two separate tracks; when you stop, quill
transcribes both into a speaker-tagged transcript, then has an LLM summarize
it.

**Engines:** transcription uses **xAI** speech-to-text by default (a local
on-device engine is available as the `parakeet` option); summaries are written
by **xAI (Grok)** or **Anthropic (Claude)** — pick the provider and its model
in `~/.config/quill/config.json`. Cloud providers only ever see the audio and
text you upload; choose a fully local setup if you prefer.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** A small dialog
   offers an optional name (with your previously used names as suggestions —
   handy for recurring meetings); it lands in the session folder name.
   First use prompts for microphone and System Audio Recording permissions.
   While recording, the icon turns red with a running elapsed counter, and
   macOS shows the purple recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/` under a 12-hour timestamp folder, with
your name appended when given — `2026-08-06-0230p-team-sync` (shown here at
2:30 PM):

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `summary.json` | LLM meeting summary — provider provenance + the summary text |
| `summary.md` | the same summary rendered for reading |
| `transcribe.log` | transcription + summary progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Automatic after every stop. Two engines behind one protocol; pick with
`transcription.engine` in the config:

| Engine | Where it runs | What it costs | Required |
|---|---|---|---|
| `xai` (default) | **xAI's cloud** (`/v1/stt`, Groq-compatible, word-level timestamps) | ~$0.10/hr of audio | `XAI_API_KEY` |
| `parakeet` | **on-device** — Parakeet TDT 0.6B v2 via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port, ~20 s/hr on Apple Silicon | free | just disk (~600 MB first download) |

The cloud engine uploads each track to xAI (tracks are re-encoded to M4A
first — CAF isn't a supported upload container; a 1-hour meeting stays a few
megabytes). `transcript.json` records `"engine": "xai"` / its provenance
either way. With `xai` selected and no key configured, transcription is
skipped and the failure is logged per session — `quill doctor` tells you
before an important meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

## Summaries

When a transcript is written, quill asks an LLM to summarize it. xAI
(`grok-4.5`) is the default provider; Anthropic (`claude-sonnet-5`) is a
config switch. The summary is written as `summary.md` next to the transcript
and covers Summary / Key topics / Decisions / Action items / Open questions.
Summaries are best-effort — a failure only adds a line to `transcribe.log`,
and disabling them never affects recording or transcripts.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "xai", "language": "en" },
  "summary": { "enabled": true, "provider": "xai", "model": "grok-4.5" },
  "api_keys": { "xai": "...", "anthropic": "..." },
  "notes_dir": "~/Documents/Obsidian/Meetings",
  "mic_voice_processing": false,
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `"xai"` (default, cloud) or `"parakeet"` (local).
- `transcription.language` — language hint (`en`, `fr`, …) for xAI's inverse
  text normalization (numbers/currency written out). Only the xai engine reads
  it.
- `transcription` is skipped entirely when `xai` is selected and no key is
  present; recordings still happen.
- `summary.enabled` — set `false` to skip the LLM summary (default on).
- `summary.provider` — `"xai"` (default) or `"anthropic"`.
- `summary.model` — optional; defaults `grok-4.5` (xai) / `claude-sonnet-5`
  (anthropic).
- `api_keys` — provider keys. Read from the config file so the LaunchAgent
  works without hand-editing its plist; `XAI_API_KEY` / `ANTHROPIC_API_KEY`
  environment variables override for terminal runs. Keyless runs skip
  transcription/summaries and log why. Keep the file readable only by you:
  `chmod 600 ~/.config/quill/config.json`.
- `notes_dir` — optional folder (usually inside an Obsidian vault) where each
  session's `transcript.md` and `summary.md` are mirrored, flat, as
  `quill-transcript-<session>.md` / `quill-summary-<session>.md` (the `<session>`
  name is the timestamp + name, e.g. `quill-summary-2026-08-06-0230p-team-sync.md`)
  so time-based search works. Audio + JSON stay in the recordings root. Unset
  by default — notes then live next to their recordings.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript and summary are written** (or right after
  recording if transcription is disabled). Wire it to whatever comes next:
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, keys, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription (optional)
- **xAI STT** (`/v1/stt`) — cloud transcription, default engine
- **URLSession** — xAI STT + LLM summarization; no HTTP SDKs
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- The xAI engine sends each track's audio to xAI (M4A, a few MB/hour). The
  parakeet engine keeps every byte local. Pick per meeting, or switch in
  config.
- Parakeet v2 is English-only; the xAI engine transcribes any supported
  language, with `language` only controlling number/currency formatting.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
