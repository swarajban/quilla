# quill

A minimal macOS meeting recorder + transcriber + push-to-talk dictator — a
combined **Granola and Whispr Flow replacement** that runs entirely on your
own Mac. One menu-bar click records your mic and all system audio as two
separate tracks; when you stop, quill transcribes both into a speaker-tagged
transcript, then has an LLM summarize it. And anywhere else on the Mac, hold
**right option** to dictate straight into whatever you're typing in. No
subscription — but you do need an **xAI API key** for transcription (and
optionally an **Anthropic** key if you switch summaries to Claude). Set both
up in Config before recording. For dictation, package it as `quill.app` so
Input Monitoring grants survive rebuilds (see [Install](#install)).

**Push-to-talk dictation (the Whispr Flow half).** Hold **right option**
anywhere on the Mac, speak, release — the transcript pastes itself
wherever your cursor is. See [Dictation](#dictation).

Forked from [digimata/quill](https://github.com/digimata/quill) — named for
the feather, Swift menu-bar tray (sibling of
[parrot](https://github.com/digimata/parrot)).

**Engines:** transcription uses **xAI** speech-to-text by default — the true,
full experience. A local on-device engine (`parakeet`) is available as a
fallback for fully-offline/liveless use, but it's English-only and strictly a
fallback. Summaries are written by **xAI (Grok)** or **Anthropic (Claude)** —
pick the provider and its model in `~/.config/quill/config.json`. Cloud
providers only ever see the audio and text you upload.

## Config

All options live in `~/.config/quill/config.json`.

### Setting it up — exact steps

1. **Create the file** from the repo's example:
   `mkdir -p ~/.config/quill && cp quill.config.example.json ~/.config/quill/config.json`
   (the example lives in the repo root, next to this README). Every option has
   a sensible default, so a minimal file can omit the keys you don't care about.
2. **Get keys** (only the ones you use):
   - xAI (required for transcription AND for the default summary provider):
     https://console.x.ai → API Keys → create one (`xai-…`).
   - Anthropic (only if you want `"provider": "anthropic"` summaries):
     https://console.anthropic.com → API Keys (`sk-ant-…`).
3. **Paste the keys** into `"api_keys"`. Alternatively export
   `XAI_API_KEY` / `ANTHROPIC_API_KEY` — the environment variables override
   the file (useful in the terminal, but the LaunchAgent only sees the file).
4. **Lock it down:** `chmod 600 ~/.config/quill/config.json` (it holds
   secrets).
5. **Verify:** `quill doctor` — every check should show `✓` except the two
   expected permissions warnings (mic + system audio prompt on first use).

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true, "engine": "xai", "language": "en",
    "key_terms": ["Quill", "Digimata"]
  },
  "summary": { "enabled": true, "provider": "xai", "model": "grok-4.5", "prompt": "" },
  "api_keys": { "xai": "xai-…", "anthropic": "sk-ant-…" },
  "notes_dir": "~/Documents/Obsidian/Meetings",
  "mic_voice_processing": false,
  "dictation": { "enabled": false, "hotkey": "right_option" },
  "on_stop": ""
}
```

The **authoritative, copy-ready example** is `quill.config.example.json` in
the repo root — the JSON above is that file rendered inline.

**Defaults are cloud.** With no config file at all, transcription uses xAI
(audio is uploaded to api.x.ai) and LLM summaries are on; exported
`XAI_API_KEY` / `ANTHROPIC_API_KEY` environment variables are picked up too.
For fully-local operation set `"transcription": { "engine": "parakeet" }` and
`"summary": { "enabled": false }`.

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `"xai"` (default, cloud) or `"parakeet"` (local).
  The defaults here are the true experience; `parakeet` is a fallback for
  fully-local use (English-only, roughly 20 s of transcription per hour of
  audio, needs a ~600 MB one-time model download) — most people should leave
  it on `xai`.
- `transcription.language` — language hint (`en`, `fr`, …) for xAI's inverse
  text normalization (numbers/currency written out). Only the xai engine reads
  it.
- `transcription.key_terms` — names, jargon, and project codewords passed to
  the xAI STT as `keyterm` hints so they're spelled correctly. Limit: 100
  terms, 50 chars each (clamped with a warning). Parakeet ignores it.
- `transcription.streaming` — live WebSocket transcription while recording
  (default `true`, xai engine only). See Transcription → Streaming.
- `transcription` is skipped entirely when `xai` is selected and no key is
  present; recordings still happen.
- `summary.enabled` — set `false` to skip the LLM summary (default on).
- `summary.provider` — `"xai"` (default) or `"anthropic"`.
- `summary.model` — optional; defaults `grok-4.5` (xai) / `claude-sonnet-5`
  (anthropic).
- `summary.prompt` — optional system-prompt override for the summarizer
  (empty/unset = built-in default). The
  built-in safety clause (the transcript is untrusted data; output must not
  contain URLs/images/HTML) is always appended, and image/embed/link syntax
  is stripped from the model's output before it is written or mirrored to
  `notes_dir` — a custom prompt can't waive either.
- `api_keys` — provider keys. Read from the config file so the LaunchAgent
  works without hand-editing its plist; `XAI_API_KEY` / `ANTHROPIC_API_KEY`
  environment variables override for terminal runs. Keyless runs skip
  transcription/summaries and log why. Keep the file readable only by you:
  `chmod 600 ~/.config/quill/config.json`.
- `notes_dir` — optional folder (usually inside an Obsidian vault) where each
  session's `summary.md` is mirrored, flat, as `quill-summary-<session>.md`
  (the `<session>` name is the timestamp + name, e.g.
  `quill-summary-2026-08-06-1430-team-sync.md`) so time-based search works.
  Transcripts, audio, and JSON stay in the recordings root — the vault gets
  only the distilled note. Unset by default — notes then live next to their
  recordings.
- `meeting_detect` — blink a record dot when another app holds the mic for
  30s while quill is idle (default on). The menu then offers **Not a meeting
  — stop asking**, which silences the detector until the mic has been free
  for 5 continuous minutes.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `dictation.enabled` — push-to-talk anywhere on the Mac (default off). See
  **Dictation** below; needs Input Monitoring + Accessibility permissions.
- `dictation.hotkey` — only `"right_option"` for now; hold to talk, release
  to paste. The key is consumed (left option still types accents).
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript and summary are written** (or right after
  recording if transcription is disabled). Wire it to whatever comes next:
  filing, indexing.


## Install

Dictation needs a signed `.app` so Input Monitoring / Accessibility grants
survive rebuilds. `bin/package-app.sh` builds, copies to
`~/Applications/quill.app`, and signs with the local `quill-local` identity:

```sh
cd quill
bin/package-app.sh
~/Applications/quill.app/Contents/MacOS/quill install --launch-at-login
```

Then `launchctl kickstart -k gui/$(id -u)/com.swarajban.quill` after each
rebuild. `quill install` prefers the packaged app when it exists.

A bare `swift build -c release` binary still runs meetings from a terminal;
rebuilds of an unsigned binary reset TCC grants, so dictation will ask again.

(`quill-local` = a persistent code-signing certificate in your keychain —
Keychain Access → Certificate Assistant → Create a Certificate → Code
Signing, or a developer cert.)

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
   If you forget: when another app (Zoom, Meet in a browser, Teams…) holds
   the mic for 30s while quill is idle, the feather blinks a red record dot
   (and the menu item reads "Start recording — meeting detected?"). **Not a
   meeting — stop asking** silences that for the rest of this call; the
   detector rearms only after the mic has been free for 5 continuous minutes
   (mute/unmute gaps do not count as a new meeting). Blink also ends if you
   start recording or two minutes pass. No calendar access needed (quill
   watches CoreAudio's process-input list). Disable with
   `"meeting_detect": false`. Note: some apps release the mic while you're
   muted — if you join muted, the blink starts when you first unmute.
   The menu also has a **Microphone** picker and, while streaming, **Live
   Transcript**.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically — a **"…" badge** appears next to the feather while the
   transcript and summary generate (the menu shows progress detail), then
   disappears; a notification fires when the transcript is ready.

Each session lands in `~/Recordings/` under a 24-hour timestamp folder, with
your name appended when given — `2026-08-06-1430-team-sync` (shown here at
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

### Streaming (xai engine, default on)

With the `xai` engine, audio also streams live to xAI's WebSocket STT while
the meeting runs — one connection per track, pcm at the track's native rate.
Locked segments land in `transcript.streaming.jsonl` as they're finalized, so
at stop the pipeline mostly merges instead of uploading: the transcript,
summary, and notes appear seconds after you stop, not minutes.

- Accuracy is the same model and the same `keyterm`/`language` hints as batch
  (probed: identical output on identical audio).
- The local recordings stay the source of truth. If a connection drops, quill
  reconnects with backoff and batch-fills just the gap from the track file at
  stop; if streaming fails outright, the whole track falls back to batch.
- Set `"transcription": { "streaming": false }` to disable.

Idle watchdog (streaming sessions): after 15s of silence on both tracks the
menu-bar icon blinks; at 5 minutes the meeting auto-stops rather than holding
an open connection. A stopped meeting stays **resumable** for 30 minutes —
"Resume last meeting" in the menu appends new tracks to the same folder, and
the transcript/summary are rebuilt over the whole timeline.

## Summaries

When a transcript is written, quill asks an LLM to summarize it. xAI
(`grok-4.5`) is the default provider; Anthropic (`claude-sonnet-5`) is a
config switch. The summary is written as `summary.md` next to the transcript
and covers Summary / Key topics / Decisions / Action items / Open questions.
Summaries are best-effort — a failure only adds a line to `transcribe.log`,
and disabling them never affects recording or transcripts.

## Dictation

Push-to-talk anywhere on the Mac: **hold right option**, speak, **release** —
quill transcribes with the configured engine (`transcription.engine`, xAI
by default) and pastes the text wherever your cursor is. A tap is too short;
hold the key. No session folder, no transcript.json, no summary — dictation
is ephemeral by design, and it's refused while a meeting is recording or
being transcribed (the meeting pipeline always has priority).

While dictation is enabled, right option is **consumed** when Accessibility
is granted — left option still types accents. Two permissions, both checked
by `quill doctor`:

- **Input Monitoring** — to see the global hotkey (macOS lists the app as
  **quill**; there is no second row after a re-sign)
- **Accessibility** — to consume right option and post the synthetic ⌘V paste

On first launch quill requests Input Monitoring via `IOHIDRequestAccess`
(the API that actually shows the system prompt). If you grant it later from
System Settings, quill retries the tap every 10 seconds — no daemon restart
needed (and if macOS kills the process when you toggle the switch, the
LaunchAgent's KeepAlive starts it right back). Without Accessibility the
hotkey still works in listen-only mode (right option is not swallowed).
Paste preflights Accessibility and pops the system prompt the first time it
needs it instead of failing silently.

Paste is clipboard-mediated: your previous clipboard string is restored a
beat after the paste lands (rich content isn't preserved).

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
- **CGEvent tap** — global right-option PTT + synthetic ⌘V paste
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording. If the **selected** mic binds but delivers
  no tap frames (seen with some USB speakerphones), quill waits 3s then
  restarts capture on the system default input and notifies you.
- The xAI engine sends each track's audio to xAI (M4A, a few MB/hour). The
  parakeet engine keeps every byte local. Pick per meeting, or switch in
  config.
- Parakeet v2 is English-only; the xAI engine transcribes any supported
  language, with `language` only controlling number/currency formatting.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
