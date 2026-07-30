# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --language pt                   # dictate in Portuguese (needs a multilingual model)
parrot transcribe audio.wav            # transcribe a file instead of the mic (debug)
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Dictating in another language

Two things have to line up: a multilingual model, and the language itself.

```sh
parrot models download whisper-large-v3-turbo     # 1.6 GB, one time
parrot --model whisper-large-v3-turbo --language pt
```

**The model is the part that matters.** The default `whisper-base.en` is
English-only, and feeding it another language doesn't produce broken text — it
produces confident, fluent, *invented* English. Measured on 7 seconds of
Portuguese:

| spoken | `whisper-base.en` returns |
|---|---|
| "Fecha o escopo do presskit da imersão de cana na Itália e me manda o orçamento revisado até quarta-feira." | "The first thing is to make the world a better place." |

Nothing in that output is a mistranscription — it's a hallucination, and parrot
types it straight into whatever field has your cursor. Hence `Resolve.language`
refusing a non-English language on an `.en` model outright.

**Why `--language` exists anyway, honestly:** less than you'd think. WhisperKit's
defaults *look* English-forcing on paper (`language` nil + `usePrefillPrompt`
true → `detectLanguage` false → decoder primed with `<|en|>`), but on
large-v3-turbo that priming barely bites: forcing `en`, `pt`, `es` and even `ja`
on the same Portuguese clip returned byte-identical correct Portuguese, with the
decoder confirming it ran as `ja`. The turbo checkpoint effectively ignores the
language token when the audio is unambiguous. So treat `--language` as an
explicit control for ambiguous or noisy input, not as the thing that makes
Portuguese work. Use `--language auto` to ask for detection when the config file
names a language.

Because the LaunchAgent runs `parrot run --skip-doctor` with no other arguments,
put the persistent choice in `~/.config/parrot/config.json` instead of the flags:

```json
{
  "model": "whisper-large-v3-turbo",
  "language": "pt"
}
```

Resolution order is flag > config > default, for both keys.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
