# Scriptorium

A reader for **iPad, iPhone and Mac**. It opens **PDF, DjVu, EPUB, FB2, Kindle AZW3, Word (DOCX and DOC), CHM and
Safari web archives** and has an AI reading companion, on-device text recognition, read-aloud, and highlights
and notes (typed or drawn with Apple Pencil). Reading positions sync through iCloud, and books can be sent from one
device to another.

Each device keeps its own local library. iCloud carries only small things: highlights, notes, bookmarks, positions,
Read Later, and books while they are on their way to another device.

## Formats

| Format | How it's read |
|---|---|
| **PDF** | PDFKit, with native selection and links. Scanned PDFs can switch to Live Text mode. |
| **DjVu** | A vendored DjVuLibre. Keeps the hidden text layer and the table of contents. It is patched so a damaged foreground palette doesn't blank the page. |
| **EPUB 2/3** | Unpacked and shown as one continuous book. |
| **FB2 / FB2.zip** | Converted to HTML chapters, with footnotes, images and the cover. |
| **Kindle AZW3** (KF8) | A native reader that rebuilds the book's parts, styles, images, internal links and contents. It handles standalone and combined MOBI+KF8 files. DRM-protected books and old MOBI files get a clear message. |
| **Word .docx** | Converted to HTML. The top-level headings become chapters, and the conversion keeps lists, tables, links, bookmarks, footnotes and images. If a document has no heading styles, headings are recognised from big or bold text. |
| **Word .doc** | Converted once: iOS uses WebKit's Word rendering and the Mac uses AppKit. Headings are recovered from text size, and Word's hidden hyphen marks become real hyphens. |
| **CHM** | A vendored CHMLib. Legacy encodings are converted to UTF-8, and the table of contents comes from `.hhc`. |
| **Safari .webarchive** | Unpacked to local files with scripts removed, and shown as one continuous page. |

## Features (all devices)

### Reading

- **Layouts.** PDF and DjVu turn **pages left to right** or scroll vertically. EPUB-style books (EPUB, FB2,
  AZW3, Word, CHM) use book-like **pages** (two-page spreads on wide screens) or **continuous scrolling**, with
  chapters flowing into each other.
- **Navigation.** The page counter opens a slider and a "go to page" field. Whole-book page numbers are counted in
  the background; until then they are estimates, marked "≈". **Contents | Bookmarks | Highlights** live in one
  panel. After a jump (link, footnote, contents or "go to page"), **← Back to p. N** returns to where you were.
- **Reopens the last book.** On launch, the book you were reading opens again inside its folder (iPad and iPhone);
  on the Mac, windows are restored.
- **Text recognition.** Vision OCR for scans, cached on the device. Scanned pages use Live Text for selection.

### Selection, highlights and notes

- **Select text** to get Highlight, Note, Dictionary, Define, Explain, Translate (assistant), Apple Translate
  and Ask…. On the Mac these are in the right-click menu, the Book menu and the toolbar.
- **Highlights** come in four colours.
- **Notes** can be attached to a selection, a highlight or a whole page ("Page Note"). A note can be typed
  text, an **Apple Pencil drawing** (made on iPad or iPhone), or both.
- **Storage.** Highlights, notes and bookmarks are kept in iCloud Drive as readable TaskPaper text in
  *Scriptorium › Highlights › <Book>.md*, with drawings saved alongside as PNG. The data that places them is a JSON
  file per book, keyed by a content fingerprint, so they follow the book across renames, moves and devices.
  Edits from different devices are merged, and the newest edit wins.

### Assistant (✨)

Chat about the current page or the selection. The visible text is sent along with the question, and the
"Page text sent" item under each question shows exactly what was sent. Available models:

- **On-device:** Apple Intelligence (FoundationModels). Private and offline. If it doesn't support the book's
  language, the assistant says so instead of guessing.
- **Local server:** Ollama, LM Studio or any OpenAI-compatible endpoint, running on this Mac or on another
  computer over Wi-Fi.
- **Claude:** the Anthropic API with your own key, stored in the Keychain.

The prompts stick to the page text, keep formulas in plain text, and cut off answers that start looping.

### Read aloud

Uses the best installed voice for each paragraph's language, highlights the sentence being read, and has controls
on the lock screen. **Tap (or click) a word while it's reading to continue from there.** Running headers, footers and
page numbers are skipped.

### Sync and devices

- **Reading positions.** Each device saves where you are. If another device read further, the reader offers:
  "Continue on p. 120? From MacBook, 2 hours ago · Go · Stay".
- **Send to a device.** The paper-plane button in the reader, or a book's menu in the library, sends the book to
  your iPad, iPhone or Mac, and you pick the folder it lands in:
  - to an **iPad**, the book goes into a folder of its **iCloud Inbox** (which mirrors its library);
  - to an **iPhone or Mac**, it goes into a hidden drop folder, using the folder list that device reported.

  The receiving device imports the book when Scriptorium opens (iPad and iPhone also check in the background) and
  then removes it from iCloud.
- **Read Later.** Long-press (or right-click) a web link in a book and choose **Add to Read Later**. Links are
  collected in *iCloud Drive › Scriptorium › Read Later.md* (TaskPaper), which the app only appends to.

### Library

- A list or a grid, with folders you can rename, move or delete (with confirmation), search across all books,
  and a library-wide view of bookmarks, highlights and notes.
- Supported files can be opened from other apps ("Open in Scriptorium").
- **iCloud Inbox (iPad).** *iCloud Drive › Scriptorium › Inbox* mirrors the library's folders. Books dropped there
  from any device are imported automatically, also in the background, and then removed from the Inbox.
- **Wi-Fi Transfer (iPad and iPhone).** Upload, download and organise books from a browser on the same network.
  It runs only while its screen is open.

### Feedback and diagnostics

- **Suggest an Improvement…** (iPad and iPhone) appends a note to *iCloud Drive › Scriptorium › Improvement
  notes.md*. Each note is tagged with the screen, book file, build and device, and can include a screenshot.
  Notes that have been dealt with are listed in *Improvement notes status.md*, which is written only by the
  development Mac, so the two files never conflict.
- **Crash reports.** MetricKit crash, hang and resource reports are saved to *iCloud Drive › Scriptorium › Crash
  reports*, one file per report, for symbolication on the development Mac. Nothing is sent anywhere else.

## Scriptorium for Mac

A native macOS app that shares the reading engine with the iPad app.

- **Library window.**
  - Folders in the sidebar; a book table with thumbnails, sortable by title, format, folder, size and date;
    search across all books.
  - Import with **File › Import Books…** (⌘O), by dropping files on the window, or with Finder's "Open With".
  - Rename, move, Move to Trash and Show in Finder, plus Bookmarks & Notes and Read Later.
- **Book windows (one per book).**
  - Contents | Bookmarks | Highlights sidebar (⌃⌘S).
  - Page navigation with ⌘← / ⌘→ and Go to Page (⌥⌘G); Back (⌘[).
  - Highlight the selection (⌃⌘H); Bookmark (⌘D); Page Note (⌥⌘N).
  - Read Aloud (⌥⌘R); the Assistant in an inspector (⌥⌘A); Send To.
  - Two-page PDF view; scroll or paged text layout; text size with ⌘+ / ⌘−.
- **DjVu and scans** use the Mac version of Live Text. Drawings made with Apple Pencil on the iPad are shown in
  notes, and can be removed but not drawn on the Mac.
- **Sync.** Highlights, notes, bookmarks, Read Later and positions sync with the iPad and iPhone. The iCloud Inbox
  stays iPad-only.

## Layout

| Path | What |
|---|---|
| `Packages/ReaderCore` | Platform-neutral core; builds and tests on macOS with `swift test` |
| `…/Sources/CDjVuLibre` | DjVuLibre 3.5.28 (GPL-2.0-or-later), vendored; trimmed `config.h`, FGbz patch |
| `…/Sources/CCHMLib` | CHMLib 0.40 (LGPL-2.1), vendored |
| `…/Sources/ReaderCore/Documents` | `PageSource` protocol, `DocumentOpener`, `PDFPageSource`, `DjVuPageSource` |
| `…/Sources/ReaderCore/Reflowable` | `EPUBSource`, `FB2Source`, `AZW3Source` (KF8), `DOCXSource`, `DOCSource`, `CHMSource`, `WebArchiveSource`, `MiniXML` |
| `…/Sources/ReaderCore/Text` | Vision OCR, `TextProvider`, running-header filter, repetition guard |
| `…/Sources/ReaderCore/Highlights` | Highlights, bookmarks and annotations; `HighlightStore`; TaskPaper files (Read Later, improvement notes) |
| `…/Sources/ReaderCore/Library` | `InboxSync`, `PositionStore` (synced positions), `DeviceDirectory` (send to device) |
| `…/Sources/ReaderCore/LLM` | Apple on-device, OpenAI-compatible and Anthropic providers; prompts |
| `…/Sources/ReaderCore/Speech` | `SpeechPlanner` (chunks, language detection, voices) |
| `…/Sources/ReaderCore/Transfer` | `TransferServer` (Network.framework HTTP) and its web page |
| `App/` | SwiftUI app for iPad and iPhone; `App/Reader/ReflowEngine.js` is the page engine for EPUB-style books |
| `App/Shared/` | Shared with the Mac: device identity, transfers, Send To, crash reporter, platform shims |
| `Mac/` | macOS app: library window, book windows, Mac Live Text viewer, settings |
| `UITests/`, `MacUITests/` | End-to-end flows (iPad/iPhone simulators; Mac) |
| `scripts/` | Seeding, building, installing, crash reports, improvement-note status |
| `project.yml` | XcodeGen spec → `Reader.xcodeproj` (schemes `Reader` and `ScriptoriumMac`) |

## Build & run

Requires Xcode 27+ (iOS/iPadOS/macOS 26 SDKs).

```sh
brew install xcodegen
xcodegen generate            # after adding/removing files or editing project.yml
open Reader.xcodeproj        # scheme "Reader" → iPad/iPhone, "ScriptoriumMac" → My Mac; Run
```

`project.yml` sets the signing team. Change `DEVELOPMENT_TEAM`, and the bundle and iCloud container IDs, to your own.
The first signed run of each app has to happen in Xcode, so that it can create the provisioning profile; after that
the command-line scripts work.

```sh
scripts/bump-build.sh        # raise the build number (needed for iCloud to pick up Info.plist changes)
scripts/install-release.sh   # Release builds for the iPad and the Mac; installs both; keeps dSYMs per build
```

### Tests

```sh
cd Packages/ReaderCore && swift test                # core: formats, sync, transfers, OCR, LLM prompts…
READER_LIVE_LLM=1 swift test                        # + live Ollama / Apple on-device tests
AZW3_PROBE=book.azw3 swift test --filter probeRealAZW3     # also DOCX_PROBE, DJVU_PROBE_DIR

scripts/seed-simulator.sh <sim-id> <dir-with-books> # sample library, Inbox, transfers, a remote position
xcodebuild test -scheme Reader -destination "id=<sim-id>"  # UI flows; TEST_RUNNER_SCREENSHOT_DIR=… saves PNGs

scripts/mac-snapshot.sh <out-dir> "Physics/Book.pdf" 8     # Mac windows to PNG, without touching mouse or keyboard
scripts/test-mac.sh <dir-with-books>                # Mac UI tests (these drive the real mouse — only on an idle Mac)
```

### Feedback loop

```sh
swift scripts/mark-improvement-done.swift                         # open improvement notes
swift scripts/mark-improvement-done.swift "<note text>" "<fix>"   # record one as handled
swift scripts/crash-reports.swift                                 # new crash reports, symbolicated
swift scripts/crash-reports.swift --mark "<file name>"            # mark one as handled
```

### Local LLM

- **On the same Mac:** `http://localhost:11434/v1` (Ollama) or `http://localhost:1234/v1` (LM Studio).
- **From an iPad or iPhone:**
  - Ollama: run `OLLAMA_HOST=0.0.0.0 ollama serve` and use `http://<mac-ip>:11434/v1`.
  - LM Studio: enable "Serve on local network" and use `http://<mac-ip>:1234/v1`.

## Licence

GPL-3.0-or-later (see `LICENSE`), because Scriptorium bundles DjVuLibre (GPL-2.0-or-later,
`Packages/ReaderCore/Sources/CDjVuLibre/COPYING`). CHMLib is LGPL-2.1 (`Sources/CCHMLib/COPYING`).
ZIPFoundation (MIT) unpacks EPUB, FB2.zip and DOCX.
