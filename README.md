# Screenshelf

A native macOS app that organizes and searches your screenshots with Apple's on-device models, similar to
Pixel Screenshots. Nothing leaves your Mac.

## What it does

- **Watches your screenshot folder** (the Desktop, or wherever `screencapture` saves) and indexes new
  screenshots as they appear. Renamed screenshots like `call trace diam.png` are still found, via the
  `kMDItemIsScreenCapture` tag macOS adds, and a renamed file keeps its notes and collections.
- **Reads the text on screen** with Vision OCR, labels what's in the image, and computes a visual
  fingerprint for "similar screenshots".
- **Describes each screenshot** with Apple Intelligence (the Foundation Models framework): a title, a
  summary, a category, and tags. Categories show up in the sidebar automatically.
- **Hybrid search**: exact matches on text in the screenshot come first (`IMSI`, `iperf`, an error code),
  then matches by meaning from NaturalLanguage sentence embeddings (`stock market` finds a Google Finance
  screenshot, `phone privacy settings` finds Android privacy settings).
- **Ask**: ask a question ("what bandwidth did the iperf test get?") and the on-device model answers from
  the best-matching screenshots, with citations.
- **Organize**: favorites, collections (drag screenshots onto one in the sidebar), notes, editable titles,
  "Move to Folder…" to get them off your Desktop, Move to Trash.
- **Inspector**: Live Text on the image (select and copy text, click links), search hits highlighted on the
  image, the full recognized text, and similar screenshots.

Keys: arrow keys move the selection, Space opens Quick Look, ⌘A selects all, ⌘⌫ moves to Trash,
double-click opens the file, ⌘R rescans.

## Requirements

- macOS 26 on Apple silicon
- Apple Intelligence turned on, for titles, summaries, categories and Ask. OCR, semantic search and
  similarity work without it.
- Command Line Tools with Swift 6.2 or newer. Xcode isn't needed.

## Build and run

```sh
scripts/bundle.sh                 # builds build/Screenshelf.app (release, ad-hoc signed)
open build/Screenshelf.app
cp -R build/Screenshelf.app /Applications   # optional
```

On first launch macOS asks for access to your Desktop. The first pass over existing screenshots takes a few
seconds each; text search works as soon as OCR finishes, and descriptions fill in after that.

The library is stored in `~/Library/Application Support/Screenshelf/library.sqlite`.

## Command line

`shelf` uses the same library and indexing pipeline as the app:

```sh
.build/release/shelf index                       # index everything pending
.build/release/shelf search "bandwidth speed test"
.build/release/shelf ask "who was discussing spam alerts in slack?"
.build/release/shelf similar 31
.build/release/shelf --folder ~/Pictures/Screenshots watch
```

## Layout

- `Sources/ShelfCore`: the library, SQLite store, Vision analyzer, Foundation Models enricher, embeddings,
  and search. Shared by the app and the CLI.
- `Sources/Screenshelf`: the SwiftUI app.
- `Sources/shelf`: the CLI.
- `scripts/`: build, bundle, and icon generation.
