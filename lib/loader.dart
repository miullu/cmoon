// loader.dart
import 'dart:typed_data';
import 'package:archive/archive.dart';

class ArchiveEntry {
  final String name;
  final int compressedSize;
  final int uncompressedSize;
  final bool isCompressed;

  ArchiveEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.isCompressed,
  });
}

class Loader {
  Uint8List? _rawBytes;
  Archive? _archive;
  final Map<String, ArchiveEntry> _index = {};

  /// Load EPUB/ZIP from raw bytes
  void loadFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw Exception("Invalid file: empty");
    }
    _rawBytes = bytes;
    _buildIndex();
  }

  void _buildIndex() {
    _archive = ZipDecoder().decodeBytes(_rawBytes!);
    for (final file in _archive!.files) {
      _index[file.name] = ArchiveEntry(
        name: file.name,
        compressedSize: file.compressedSize,
        uncompressedSize: file.size,
        isCompressed: file.isCompressed,
      );
    }
  }

  Uint8List get rawBytes => _rawBytes!;
  List<ArchiveEntry> listFiles() => _index.values.toList();

  Uint8List getFile(String name) {
    final file = _archive!.files.firstWhere(
      (f) => f.name == name,
      orElse: () => throw Exception("File not found: $name"),
    );
    final content = file.content;
    if (content is Uint8List) return content;
    if (content is List<int>) return Uint8List.fromList(content);
    throw Exception("Unsupported content type for: $name");
  }

  void dispose() {
    _rawBytes = null;
    _archive = null;
    _index.clear();
  }
}
