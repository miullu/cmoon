import 'dart:typed_data';
import 'package:archive/archive.dart';

class Loader {
  Archive? _archive;
  // Use a case-insensitive index to prevent crashes on mismatched casing
  final Map<String, ArchiveFile> _index = {};

  /// Load EPUB/ZIP using standard decoding
  void loadFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw Exception("Invalid file: empty");
    }
    
    // Fix: Use decodeBytes instead of decodeBuffer to resolve the 4.0.7 compilation error
    _archive = ZipDecoder().decodeBytes(bytes);
    
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

    // Ensure the content is returned specifically as Uint8List
    return file.content as Uint8List;
  }
}
