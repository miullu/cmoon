some reminder for self notification

📂 Loader Module (one file)
Responsibilities

Accepts a source (file path, file:// URI, content:// URI, or network stream).

Reads the entire file into RAM as a Uint8List.

Validates file type (ZIP/EPUB).

Exposes:

Raw bytes (for consumers that want direct access).

Archive index (list of contained files, metadata).

Lookup API to fetch a specific file’s bytes on demand.

Flow

Input resolution

Normalize URI → obtain byte stream.

Collect into memory buffer.

Archive parsing

Use ZIP decoder to read central directory (at end of file).

Build in‑memory index of entries (filename, offset, size).

Expose API

listFiles() → returns file names and metadata.

getFile(name) → returns bytes for that entry.

dispose() → clears RAM if needed.

📖 EPUB Reader Module (separate file)
Responsibilities

Consumes Loader’s API, not raw filesystem.

Interprets EPUB structure (META‑INF, OPF, XHTML, images).

Provides higher‑level access:

Metadata (title, author, manifest).

Navigation (TOC, spine).

Content retrieval (chapter text, images).

Flow

Initialize with Loader

Pass Loader instance into Reader.

Parse EPUB manifest

Read META-INF/container.xml → locate OPF.

Parse OPF → build spine, manifest, metadata.

On‑demand extraction

When a chapter/image is requested, call Loader’s getFile(name).

Decode bytes into text/image as needed.

Provide Reader API

getMetadata()

getChapter(index)

getImage(id)
