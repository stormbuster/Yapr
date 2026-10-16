# Yapr

A tiny macOS menu bar app that transcribes what you say, live and on-device, with
[Phonon 2](https://www.fermionresearch.com/models/phonon-2/) on the Neural Engine.

- **Click** the menu bar icon: a round panel opens with a big microphone.
- **Click the microphone**: Yapr listens; recognised words drift into the circle (grey while still
  being revised, ink once settled) and rings pulse with your voice.
- **Click again**: recording stops, the transcript opens in a borderless page set in EB Garamond, and
  the circle returns to the microphone.
- **Drag the circle** away from the menu bar to keep it floating; drop it back near the icon to re-attach.
- **Right-click** the icon for Settings and Quit. Settings: input device, output device, pass-through
  (hear yourself, use headphones) and the transcripts folder (default `~/Documents/Yapr`).

Transcripts are plain UTF-8 text files, `Yapr <date> at <time>.txt`, written as you speak, so nothing is
lost if the app quits mid-sentence. Paragraphs break at pauses longer than 3.5 s.

## Build

Requires an Apple silicon Mac, macOS 15 or later, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Yapr.xcodeproj -scheme Yapr -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Yapr.app
```

On first launch Yapr downloads the Phonon-2 Core ML model (330 MB, pinned revision, SHA-256 checked) from
[FermionResearch/Phonon-2-CoreML](https://huggingface.co/FermionResearch/Phonon-2-CoreML) into
`~/Library/Application Support/Yapr/`, and the first load prepares it for the Neural Engine (a minute or
two, once). macOS asks for microphone access the first time you record.

## How the live transcription works

Phonon 2's Swift package ([phonon-coreml](https://github.com/fermionresearch/phonon-coreml)) transcribes
whole buffers. Yapr keeps the audio since the last committed phrase and re-transcribes it every 0.3 s (a
few milliseconds of Neural Engine time), which gives the live words. After 0.7 s of silence, or 12 s of
continuous speech, the phrase is committed: appended to the file and never revised again. See
`Yapr/LiveTranscriber.swift`.

## Testing without a microphone

Debug builds include a harness that "records" an audio file in real time and snapshots each stage:

```bash
say -o /tmp/speech.aiff "Hello from Yapr." && afconvert -f WAVE -d LEF32@16000 -c 1 /tmp/speech.aiff /tmp/speech.wav
YAPR_SNAPSHOTS=/tmp/snaps YAPR_FEED=/tmp/speech.wav build/Build/Products/Debug/Yapr.app/Contents/MacOS/Yapr -transcriptsFolder /tmp/transcripts
```

## Credits

- Phonon 2 by Fermion Research, weights CC-BY-4.0 (derived from NVIDIA Parakeet TDT 0.6B v3);
  phonon-coreml under Apache 2.0.
- EB Garamond by Georg Duffner and Octavio Pardo, SIL Open Font License (`Yapr/Fonts/OFL.txt`).
- The borderless transcript window follows [stormbuster/borderless](https://github.com/stormbuster/borderless).
