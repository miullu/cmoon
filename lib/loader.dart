import 'dart:typed_data';
import 'package:archive/archive.dart';

class Loader {
  Archive? _archive;
  // Use a case-insensitive index to prevent crashes on mismatched casing
  final Map<String, ArchiveFile> _index = {};

  /// Load EPUB/ZIP using a buffer to avoid extracting everything into memory at once
  void loadFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw Exception("Invalid file: empty");
    }
    
    // decodeBuffer is more memory efficient than decodeBytes
    final input = InputStream(bytes);
    _archive = ZipDecoder().decodeBuffer(input);
    
    _index.clear();
    for (final file in _archive!.files) {
      // Store reference using lowercase key for robust searching
      _index[file.name.toLowerCase()] = file;
    }
  }

  /// Lists all files in the archive (for debugging/listing)
  List<String> listFiles() => _index.keys.toList();

  /// Extracts and returns the bytes of a specific file
  Uint8List getFile(String path) {
    if (_archive == null) throw Exception("Loader not initialized");
    
    // Normalize path: handle backslashes and casing
    final normalizedPath = path.replaceAll('\\', '/').toLowerCase();
    
    final file = _index[normalizedPath];
    if (file == null) {
      throw Exception("File not found in archive: $path");
    }

    // Only now are the bytes for this specific file decompressed
    return file.content as Uint8List;
  }
}