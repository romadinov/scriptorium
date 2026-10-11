# Scriptorium

An iPad reader for **PDF, DjVu, EPUB, FB2, CHM and Safari web archives**, with an AI reading companion, on-device text recognition,
a dictionary, highlights that sync through iCloud, a folder library and Wi-Fi upload from a browser.

## Features

- **Formats**
  - PDF uses PDFKit, with native selection.
  - DjVu uses a vendored DjVuLibre, keeping the hidden text layer and the table of contents.
  - EPUB 2/3 and FB2 / FB2.zip are converted into one continuous book.
  - CHM (Microsoft Compiled HTML Help) uses a vendored CHMLib. Legacy encodings are converted to UTF-8 and the
    table of contents comes from the `.hhc` file.
  - Safari `.webarchive` files are unpacked to local files, with scripts removed, and shown as one continuous page.
- **Reading PDF/DjVu**: **pages left to right** (swipe, pinch to zoom each page) or vertical scrolling. Switch with
  the page-layout button.
- **Page navigation**: tap the page counter for a slider and a "go to page" field. For EPUB/FB2/CHM, real page
  numbers for the whole book are counted in the background for the current text size and screen; until then they
  are estimates, marked "≈".
- **Reading EPUB/FB2/CHM**: book-like **pages you swipe horizontally** (two-page spread in landscape, tap the edges
  to turn) or **continuous vertical scrolling**. Chapters flow into each other without reloading.
  Text size and layout are in the **Aa** menu.
- **Text recognition**: Vision OCR for scanned PDFs and DjVu; results are cached on the device.
  Scanned pages use VisionKit Live Text for selection.
- **Select text** → Highlight · Dictionary (system dictionaries) · Define · Explain · Translate (LLM) ·
  Apple Translate (on-device) · Ask….
- **Assistant** (✨ in the reader): chat about the current page or selection. The app sends the visible text along
  with your question. Models:
  - **On-device**: Apple Intelligence (FoundationModels). Offline and private.
  - **Local server**: Ollama, LM Studio or any OpenAI-compatible endpoint on your Mac or PC over Wi-Fi.
  - **Claude**: the Anthropic API, using your own key, stored in the Keychain.
- **Back after jumps**: after following an internal link (EPUB/FB2/CHM/web archive links and footnotes, PDF
  links), the contents list or "go to page", a **← Back to p. N** button returns to where you were, one step
  per tap.
- **Read Later**: long-press any web link in a book and choose **Add to Read Later**. Links are collected in
  *iCloud Drive › Scriptorium › Read Later.md* (TaskPaper format: `- title @url(…) @from(book, p. N) @added(date)`),
  and the list is also in the library. The app only appends to that file, so you can mark items `@done` or
  rearrange them in TaskPaper.
- **Highlights**: four colours, a list per book, and tap a highlight to recolour, remove or ask about it.
  They are stored in iCloud Drive as readable TaskPaper-style text, in *iCloud Drive › Scriptorium › Highlights › <Book>.md*:
  the book is a project, and each highlight is a `- text @location(…) @date(…) @color(…)` item.
  The data used to place them goes in a JSON file per book, keyed by a content fingerprint, so highlights follow
  the book across renames, moves and devices.
- **Library**: a list by default (or a grid); folders with rename / move / delete; reading position is remembered. Supported files can be
  opened from other apps ("Open in Scriptorium").
- **iCloud Inbox** (iPad): *iCloud Drive › Scriptorium › Inbox* mirrors the library's folders. Drop books into any
  folder from your Mac or another device:
  - while the app is open, new books are downloaded and imported automatically;
  - in the background, iPadOS runs the import when it chooses, typically while the iPad is idle or charging;
  - **Sync iCloud Inbox** (or pull to refresh) runs it by hand.

  Imported books are removed from the Inbox, and the library itself stays local. Tip: in Files or Finder,
  choose **Keep Downloaded** on the Inbox folder so books are already on the device when the import runs.
- **Wi-Fi Transfer**: tap the wifi icon in the library and open the address it shows in a browser on the
  same network. You can upload, create folders, download and delete. It runs only while that screen is open,
  and has no password, so use it on networks you trust.

## Layout

| Path | What |
|---|---|
| `Packages/ReaderCore` | Platform-neutral core; builds and tests on macOS with `swift test` |
| `…/Sources/CDjVuLibre` | DjVuLibre 3.5.28 (GPL-2.0-or-later), vendored; hand-trimmed `config.h` |
| `…/Sources/CCHMLib` | CHMLib 0.40 (LGPL-2.1), vendored |
| `…/Sources/ReaderCore/Documents` | `PageSource` protocol, `DjVuPageSource`, `PDFPageSource` |
| `…/Sources/ReaderCore/Reflowable` | `EPUBSource`, `FB2Source`, `CHMSource`, `WebArchiveSource`, `MiniXML` |
| `…/Sources/ReaderCore/Text` | Vision OCR and `TextProvider` (embedded text → OCR cache → fresh OCR) |
| `…/Sources/ReaderCore/Highlights` | `Highlight` model, `HighlightStore` (iCloud Drive, coordinated, merging) |
| `…/Sources/ReaderCore/LLM` | Apple on-device, OpenAI-compatible, Anthropic providers; prompts |
| `…/Sources/ReaderCore/Library` | `InboxSync` (iCloud Inbox import + folder mirroring) |
| `…/Sources/ReaderCore/Transfer` | `TransferServer` (Network.framework HTTP) + its web page |
| `App/` | SwiftUI iPad app; `App/Reader/ReflowEngine.js` is the EPUB/FB2 page engine |
| `UITests/` | End-to-end flows on the simulator |
| `project.yml` | XcodeGen spec → `Reader.xcodeproj` |

## Build & run

Requires Xcode 26+ (iPadOS 26 SDK).

```sh
brew install xcodegen
xcodegen generate            # after adding/removing files or editing project.yml
open Reader.xcodeproj        # pick your iPad and Run
```

`project.yml` sets the signing team. Change `DEVELOPMENT_TEAM` (and the bundle / iCloud container IDs) to your own
before building.

### Tests

```sh
cd Packages/ReaderCore && swift test               # core: formats, OCR, highlights, transfer server
READER_LIVE_LLM=1 swift test                        # + live Ollama / Apple on-device tests
READER_REAL_BOOK=/path/book.epub swift test --filter realBook

scripts/seed-simulator.sh <sim-id> <dir-with-books> # sample library in folders
xcodebuild test -scheme Reader -destination "id=<sim-id>"   # UI flows; TEST_RUNNER_SCREENSHOT_DIR=… saves PNGs
scripts/transfer-smoke.sh some.epub                 # while Wi-Fi Transfer is open
```

With Command Line Tools only (no Xcode), `scripts/typecheck.sh` type-checks the app against Mac Catalyst UIKit.

### Local LLM over Wi-Fi

- Ollama: run `OLLAMA_HOST=0.0.0.0 ollama serve`, then use URL `http://<mac-ip>:11434/v1` and tap **Fetch models**.
- LM Studio: enable "Serve on local network", then use URL `http://<mac-ip>:1234/v1`.

## Licence

GPL-3.0-or-later (see `LICENSE`), because Scriptorium bundles DjVuLibre (GPL-2.0-or-later,
`Packages/ReaderCore/Sources/CDjVuLibre/COPYING`). CHMLib is LGPL-2.1 (`Sources/CCHMLib/COPYING`);
ZIPFoundation (MIT) unpacks EPUB / FB2.zip.
