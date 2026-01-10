# cmoon — Lightweight EPUB Reader (updated)

This repo contains a small EPUB reader implemented in Flutter/Dart. I refactored the codebase and some parts of the original README were out of date. The sections below reflect the current implementation in `lib/loader.dart`, `lib/epub.dart`, and `lib/main.dart` (as of commit f5451c1).

High level summary
- The app reads an EPUB (ZIP) file into memory and exposes a small API to:
  - Read meta information (from OPF metadata),
  - Build a manifest and spine (reading order),
  - Parse a Table of Contents (EPUB 3 nav or EPUB 2 NCX),
  - Load chapter HTML/XHTML content on demand,
  - Return raw bytes for images or other resources inside the EPUB.
- Main libraries used:
  - `archive` — decode EPUB ZIP,
  - `xml` — parse `container.xml`, OPF, NCX, and nav XHTML,
  - `file_picker` — pick EPUB files from device,
  - `flutter_widget_from_html` — render chapter HTML in the UI.

---

## Modules

### lib/loader.dart
Responsibilities
- Provide a minimal abstraction over an in-memory EPUB (ZIP) archive.
- Decode ZIP bytes into an `Archive` and allow lookups of entries by internal path.
- Provide simple helpers to return file bytes or decoded text.

Public API (current)
- `static Future<Loader?> pickEpub()` — Opens a system file picker and, if the user selects a file, decodes it into a `Loader` backed by an `Archive` and returns it. Returns `null` if the user cancels.
- `factory Loader.fromBytes(Uint8List bytes)` — Decode ZIP bytes (useful when you already have the EPUB bytes, e.g., from `FilePicker` with `withData: true`).
- `Uint8List getFile(String path)` — Return raw bytes for an internal EPUB path (normalizes backslashes to forward slashes). Throws if the file is not found.
- `String getTextFile(String path, {Encoding encoding = utf8})` — Convenience method that decodes `getFile` bytes to a `String` with the provided encoding.
- `String get epubFilePath` — Returns the original file path if the loader was created from disk, or `"<memory>"` when created from bytes.

Notes / caveats
- The loader does not build a case-insensitive index or modify paths beyond replacing `\` with `/` — it relies on `Archive.findFile` with the normalized path.
- `getFile` will throw when the path cannot be found inside the archive; callers should handle exceptions.
- The `Archive` and full EPUB bytes are held in memory for the life of the `Loader`.

---

### lib/epub.dart
Responsibilities
- Interpret EPUB structure using the `Loader` API.
- Locate OPF via `META-INF/container.xml`.
- Parse OPF to extract metadata, manifest (id -> href), and spine (ordered `idref`s).
- Resolve and parse the table of contents:
  - Prefer EPUB 3 `<nav>` (manifest item with `properties="nav"`) — parses `<nav>` / `<ol>` / `<li>` / `<a>` structures.
  - Fall back to EPUB 2 NCX when `spine` has a `toc` attribute that references an NCX manifest item.
- Provide methods to request chapter HTML and raw embedded resources (images).

Key types & methods
- `class TocNode` — simple tree node with `title`, optional `href`, and `children` (`List<TocNode>`).
- `class EpubReader`
  - Constructor: `EpubReader(Loader loader)`
  - `void init()` — synchronous parsing routine:
    - Reads `META-INF/container.xml` to get the OPF full-path.
    - Parses the OPF package: metadata, manifest (id -> href), and spine order (list of `idref`s).
    - Attempts to parse a TOC (nav or NCX) and stores the result.
    - Throws if OPF path cannot be found.
  - `String getChapterHtml(int index)` — Return decoded HTML/XHTML bytes for a spine item by index. Throws on invalid index. On file read failure returns an error HTML string.
  - `String? getChapterHref(int index)` — Returns the manifest href for the given spine index (useful to map TOC hrefs to spine entries).
  - `Uint8List getImage(String hrefFromHtml, String currentChapterPath)` — Resolves a relative resource path against `currentChapterPath` (using `_resolvePath`) and returns raw bytes via `Loader.getFile`.
  - `Map<String, String> getMetadata()` — Returns parsed metadata entries (element local name -> innerText).
  - `List<TocNode> get toc` — Parsed TOC tree (may be empty).
  - `int get chapterCount` — Number of items in the spine.

Implementation notes / caveats
- `init()` runs synchronously and expects the `Loader` to already contain the EPUB archive; for large EPUBs this could block the UI thread — consider moving parsing off the main thread if needed.
- TOC detection:
  - EPUB 3 nav detection checks for manifest items with `properties="nav"` (exact equality). EPUBs that use multiple properties or namespaces may not be detected.
  - NCX fallback uses the `spine` `toc` attribute to find a manifest entry by id.
- `_resolvePath(contextPath, relativePath)` resolves relative URIs against the directory of `contextPath` (handles `.` and `..` segments).
- Metadata parsing uses element local names (`node.name.local`) and stores element innerText directly — namespaces are not preserved in keys.
- The XML parsing uses the `xml` package and simple element name matching; EPUBs with unexpected namespaces or structure may require more robust parsing.

---

### lib/main.dart
Responsibilities
- Flutter UI that wires together `Loader` and `EpubReader`.
- File selection, bootstrapping the reader, rendering chapter HTML, and simple chapter navigation.
- Builds a drawer-based Table of Contents and a small floating control bar to move between spine entries.

Key behavior
- File selection:
  - `_pickBook()` uses `FilePicker` with `withData: true` to obtain the EPUB bytes in memory, creates `Loader.fromBytes`, constructs `EpubReader(loader)` and calls `init()` to parse the book.
- UI rendering:
  - `_buildChapterView()` gets chapter HTML via `_reader!.getChapterHtml(_currentChapter)`, removes any `<title>` tags using `html` package parsing, and renders the cleaned content with `HtmlWidget` from `flutter_widget_from_html`.
- TOC drawer:
  - `_buildTocDrawer()` shows parsed metadata (e.g., `metadata['title']`) and flattens `EpubReader.toc` into nested `ListTile`s using `_buildFlatTocList`.
  - Current selection determination compares the TOC node `href` (split by `#`) with the reader's `getChapterHref(currentChapter)`.
  - Tapping a TOC entry calls `_navigateToHref(href)` which finds the first spine index whose `getChapterHref(i)` equals the TOC entry href (anchor stripped), and opens that chapter.
- Other:
  - `_clearCache()` calls `FilePicker.platform.clearTemporaryFiles()` and shows a `SnackBar` with the result (this only affects file picker temporary files, not the in-memory loader).

Notes / caveats
- The UI currently parses and decodes the EPUB on the main thread; large EPUBs could cause jank.
- TOC <-> spine matching is simple string equality on hrefs (anchor removed). Relative differences or path normalization mismatches will prevent matching.
- Image loading from EPUB is supported via `EpubReader.getImage`, but the example UI does not yet hook a custom image loader into `flutter_widget_from_html`. You can implement a custom `WidgetFactory` or an `ImageSourceMatcher`/`customImageBuilder` to fetch bytes from the EPUB and render them inline.
- The app expects `withData: true` when picking files if you want to load from bytes; `Loader.pickEpub()` also exists and uses the file path and reads bytes from disk.
