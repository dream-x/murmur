# Murmur

**Murmur** is a tiny macOS menu bar app that quietly records every meeting and turns it into a transcript, locally.

- 🎙 **Auto-records meetings.** When any app starts using the microphone (Zoom, Google Meet, Telegram, Яндекс Телемост, SaluteJazz, …), Murmur starts recording. When the mic is released, it stops.
- 🎧 **Two clean tracks.** It records your microphone and the system audio (the other participants) separately via a Core Audio process tap. You don't need BlackHole or other virtual devices, and volume control keeps working.
- 📝 **Local transcription** via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`large-v3-turbo` on the Apple GPU), or optionally [Handy](https://github.com/cjpais/Handy). The transcript is labelled **Я** (you) / **Собеседники** (others) with timestamps.
- 🧠 **Meeting notes.** After transcription an LLM agent from your existing subscription ([GitHub Copilot CLI](https://github.com/github/copilot-cli) or [Claude Code](https://www.anthropic.com/claude-code)) writes `summary.md`: summary, participants, decisions, *who owes what to whom*, your own tasks and open questions.
- 🔁 **Echo removal.** Without headphones the mic hears the speakers. Murmur drops mic phrases that repeat what the remote side said at the same moment.
- ⌨️ **Global hotkey** (default `⌃⌥R`) to start or stop a recording manually.

> The UI is in Russian.

## How it works

```
mic in use? ──► record mic.aac + system.aac ──► mic released ──► transcribe
                                                                  │
   16 kHz mono ◄── each track ◄───────────────────────────────────┘
        │
   energy VAD ──► speech only ──► whisper-cli (one pass per track) ──► echo removal ──► transcript.md
                                                                                          │
                                         copilot -p / claude -p (no tools) ──► summary.md ◄┘
```

Each meeting is a folder in `~/Recordings/Meetings/<date>_<app>/`:

| file | contents |
|---|---|
| `mic.aac` | your microphone (mono, 48 kHz AAC) |
| `system.aac` | system output: the other participants (stereo AAC) |
| `meta.json` | start and end time, apps that used the mic |
| `transcript.md` | readable transcript with timestamps and speakers |
| `transcript.json` | phrase-level segments |
| `summary.md` | summary, decisions, action items (who owes what), your tasks |

Silence is cut out before transcription: Whisper only sees speech (so it doesn't hallucinate on quiet parts), and timestamps are mapped back to the original recording. A 13-minute meeting takes about 45 s on an M4 Max.

Audio is written as ADTS AAC, so a recording stays playable even if the app crashes or the Mac loses power mid-meeting.

## Requirements

- macOS 14.2+ (Core Audio process taps), Apple Silicon recommended
- Xcode 15.2+ / Swift 5.9+ to build
- For transcription: `brew install whisper-cpp`. On first use Murmur downloads the `ggml-large-v3-turbo-q5_0` model (~550 MB) to `~/Library/Application Support/Murmur/models/`. Any other ggml Whisper model can be picked in Settings.
- For meeting notes (optional): `copilot` (logged in, default model `claude-sonnet-5.5`; `claude-haiku-5.5` is cheaper) or `claude` (Claude Code, models `sonnet` / `haiku`). The transcript is sent to that provider; the agent runs with all tools disabled.
- Alternatively, [Handy](https://github.com/cjpais/Handy) **0.10+** with a downloaded model (e.g. `parakeet-tdt-0.6b-v3`). Handy is started once per phrase, so its icon flickers in the Dock while transcribing.

## Install

### Download

Grab `Murmur-<version>.zip` from [Releases](https://github.com/dream-x/murmur/releases), unzip, and move `Murmur.app` to `/Applications`.
The app is not notarized, so on first launch macOS Gatekeeper will block it. Run once:

```bash
xattr -dr com.apple.quarantine /Applications/Murmur.app
```

### Build from source

```bash
git clone https://github.com/dream-x/murmur.git
cd murmur
make install        # builds, installs ~/Applications/Murmur.app and launches it
```

On the first recording macOS asks for **Microphone** and **System Audio Recording** access. Allow both.
Murmur adds itself to login items on first launch. You can turn this off in Settings.

Other commands: `make test`, `make uninstall`. Logs: `tail -f ~/Library/Logs/Murmur.log`.

## Menu bar

| icon | state |
|---|---|
| 🎙 | waiting for a meeting |
| 🎙 crossed out | auto-recording is off |
| 🔴 `12:34` | recording |
| 💬 `42%` | transcribing |

From the menu you can start or stop recording, toggle auto-recording, open the recordings folder, and browse recent recordings. For each recording you can open the notes or the transcript, rebuild the notes, reveal it in Finder, or transcribe it again.

**Settings:** recordings folder, hotkey, start and stop delays, minimum duration (shorter recordings are discarded), ignored apps (bundle IDs), sounds, auto-transcription, engine (whisper.cpp / Handy), model, language, meeting notes agent and model, launch at login.

## CLI

The same binary works as a CLI:

```bash
murmur record [--out DIR]   # record now until Ctrl-C
murmur list                 # processes currently using audio input
murmur transcribe DIR       # transcribe a recording folder
murmur summarize DIR        # summary.md from transcript.md
```

(`~/Applications/Murmur.app/Contents/MacOS/murmur`)

## Notes and limitations

- The other participants are not split per person yet (no diarization). Everyone remote is labelled **Собеседники**.
- The app is ad-hoc signed. After rebuilding, macOS may ask for permissions again.
- Murmur ignores Siri / dictation daemons and Handy itself, so dictation does not trigger a recording.

## License

[MIT](LICENSE)
