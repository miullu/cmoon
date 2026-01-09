# cmoon — Lightweight EPUB Reader (notes)

This repository contains a small EPUB reader implementation in Flutter/Dart. The project is split into a small set of focused modules. This README summarizes each module and documents the high-level responsibilities and public API to help you understand and extend the code.

## Overview

- The app reads an EPUB (ZIP) file into memory, builds an index of contained files, and exposes an API to:
  - Retrieve metadata (title, author, etc.),
  - Browse a table of contents (TOC),
  - Load chapter XHTML/HTML content on demand,
  - Extract embedded images.

- Key libraries used:
  - `archive` for ZIP decoding,
  - `xml` for parsing `container.xml`, OPF and NCX / XHTML nav,
  - `file_picker` for selecting EPUB files in the Flutter UI,
  - `flutter_widget_from_html` to render chapter HTML content.

## Module summaries

### lib/loader.dart
Responsibilities
- Load an EPUB (ZIP) archive into memory and build an in-memory index of files.
- Provide fast lookups and raw bytes for entries inside the archive.

Public API
- `void loadFromBytes(Uint8List bytes)`
  - Decode an EPUB/ZIP buffer into an `Archive`.
  - Populate a case-insensitive file index for robust lookups.
  - Throws if `bytes` is empty.
- `List<String> listFiles()`
  - Returns a list of normalized file names present in the archive (lowercase).
- `Uint8List getFile(String path)`
  - Returns the bytes for a given internal path (case-insensitive and normalizes slashes).
  - Throws if the archive is not initialized or the file is missing.

Notes / Caveats
- The loader builds the entire ZIP entry index in memory. File content is taken from `ArchiveFile.content` (cast to `Uint8List`), so ensure compressed/uncompressed handling matches `archive` package behavior.
- Paths are stored lowercased to avoid casing mismatches across OSes or EPUB generators. This improves robustness but means callers should expect normalized names.

### lib/epub.dart
Responsibilities
- Interpret EPUB structure using the `Loader` API (not filesystem).
- Locate OPF via `META-INF/container.xml`.
- Parse OPF to build metadata, manifest, and spine.
- Resolve and parse the Table of Contents (EPUB 3 `<nav>` or EPUB 2 NCX).
- Provide chapter content and images on demand.

Key types
- `class TocNode`
  - Represents a node in the TOC with `title`, optional `href`, and `children`.
- `class EpubReader`
  - Constructed with a `Loader` instance: `EpubReader(loader)`.
  - Important methods / getters:
    - `void init()` — Parses container.xml and OPF, builds manifest and spine, and resolves TOC.
      - Throws if OPF path can't be found.
    - `String getChapterHtml(int index)` — Returns decoded chapter XHTML/HTML for a spine item by index.
    - `String? getChapterHref(int index)` — Returns the manifest href for a spine index (can be used to map hrefs to spine indexes).
    - `Uint8List getImage(String hrefFromHtml, String currentChapterPath)` — Resolves a relative image href (relative to the current chapter path) and returns its raw bytes from the loader.
    - `Map<String, String> getMetadata()` — Returns parsed metadata (titles, authors, etc.).
    - `List<TocNode> get toc` — Returns the parsed TOC tree (may be empty if not present).
    - `int get chapterCount` — Number of spine items (chapters).
  - Internal behavior:
    - Handles EPUB 3 nav items (items in the manifest with `properties="nav"`).
    - Falls back to EPUB 2 NCX via the spine `toc` attribute if present.
    - Resolves relative paths robustly (handles `..` and `.` segments) relative to the OPF path.
    - Uses the `xml` package to parse XML/HTML content.

Notes / Caveats
- `init()` is synchronous and expects the `Loader` to be already populated. Long parsing on the main thread can cause jank in UI—consider moving heavy parsing to an isolate if necessary.
- Parsing looks for element names without full namespace resolution; some EPUBs with unexpected namespaces or tag casing may require more robust handling.
- The TOC parsing extracts textual titles and the raw hrefs; anchors are preserved in hrefs and can be split later by the UI.

### lib/main.dart
Responsibilities
- Flutter UI that wires together `Loader` and `EpubReader`, picks EPUB files, renders chapters, and provides navigation.

Key widgets + behavior
- `EpubReaderApp` — top-level MaterialApp.
- `ReaderScreen` (StatefulWidget) — main reading UI:
  - File selection via `FilePicker` (expects `withData: true` to obtain bytes).
  - On file picked:
    - Loads bytes into `Loader`.
    - Calls `EpubReader.init()` to parse the EPUB.
    - Shows the first chapter and updates title from metadata.
  - Drawer with TOC:
    - Built from `EpubReader.toc` using `TocNode` to create nested ListTiles.
    - Tapping a TOC entry uses `_navigateToHref` to map the TOC `href` to a spine index and load the chapter.
  - Page navigation:
    - Bottom navigation bar with previous/next chapter controls and a text counter "Page X of Y".
  - Content rendering:
    - Uses `HtmlWidget` from `flutter_widget_from_html` to render chapter HTML.
    - Provides `_EpubWidgetFactory` (extends `WidgetFactory`) to intercept image rendering; currently falls back to default behavior but is designed to load images from the EPUB archive if `src` is a relative path.

Public interactions / Helpers
- `_pickAndLoadFile()` — Opens file picker and bootstraps Loader and EpubReader.
- `_loadChapter(int index)` — Loads and displays a chapter by index.
- `_navigateToHref(String? href)` — Resolves a href (removes anchor, finds matching manifest entry via `EpubReader.getChapterHref`) and navigates to that chapter.

Notes / Caveats
- Image handling in `_EpubWidgetFactory` currently defers to the default `HtmlWidget` image builder; to fully support EPUB-embedded images, implement a custom `buildImage` that reads bytes via `EpubReader.getImage(...)` and constructs an `Image.memory(...)`.
- UI code runs parsing and decoding on the main thread; consider moving heavy tasks to a background isolate for large EPUBs.

## Special considerations: memory, disk caching, extraction strategy

Important behavior
- The current design intentionally does not persist or cache EPUB contents on disk. The Loader reads the entire EPUB (ZIP) into a Uint8List and decodes the archive in memory, building an in-memory index and returning file bytes on demand.
- Extraction is demand-driven: the Loader and EpubReader return raw bytes for a requested entry when a consumer calls `getFile(...)` or `getImage(...)`. Files are not extracted to temporary files or cached on disk by the code in this repository.

Implications
- Memory usage: Because the archive bytes are kept in memory (and `ArchiveFile.content` may also be held in memory), this approach is not suitable for very large EPUB files (for example, ~100 MB or larger). On mobile devices this can cause high memory pressure and runtime failures.
- No persistent caching: Re-opening the app, reloading a file, or navigating away does not persist extracted content to disk. Every run relies on reloading the EPUB bytes (unless the embedding app adds its own persistence).
- On-demand extraction: The implementation avoids extracting all files upfront — this reduces upfront CPU cost and avoids creating many temporary files, but it still requires the initial full-file read to memory. After that, individual files are returned when requested.

## How to use
1. Add dependencies in `pubspec.yaml`:
   - archive
   - xml
   - file_picker
   - flutter_widget_from_html
2. Run the app on a device/emulator.
3. Tap the file icon in the AppBar to select an `.epub` file.
4. Use the drawer to access the table of contents and the bottom bar to move between spine entries.
