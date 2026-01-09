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
    _rawBytes = bytes;
    _validate();
    _buildIndex();
  }

  void _validate() {
    if (_rawBytes == null || _rawBytes!.length < 4) {
      throw Exception("Invalid file: empty or too small");
    }
    if (!(_rawBytes![0] == 0x50 && _rawBytes![1] == 0x4B)) {
      throw Exception("File is not a valid ZIP/EPUB");
    }
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
    return file.content is Uint8List
        ? file.content as Uint8List
        : Uint8List.fromList(file.content as List<int>);
  }

  void dispose() {
    _rawBytes = null;
    _archive = null;
    _index.clear();
  }
}
