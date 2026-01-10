import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';

/// Loader abstracts file access for EpubReader.
/// It hides whether the EPUB is in RAM, disk, or elsewhere.
class Loader {
  late Archive _archive;
  late String _epubFilePath;

  Loader._(this._archive, this._epubFilePath);

  /// Opens a system file picker to select an EPUB file.
  /// Returns a Loader instance ready to serve files.
  static Future<Loader?> pickEpub() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result == null || result.files.isEmpty) {
      return null; // user cancelled
    }

    final filePath = result.files.single.path;
    if (filePath == null) return null;

    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    return Loader._(archive, filePath);
  }

  factory Loader.fromBytes(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    return Loader._(archive, "<memory>");
  }

  /// Retrieve a file from the EPUB archive by relative path.
  Uint8List getFile(String path) {
    final normalized = path.replaceAll('\\', '/');
    final file = _archive.findFile(normalized);
    if (file == null) {
      throw Exception("File not found in EPUB: $normalized");
    }
    return Uint8List.fromList(file.content as List<int>);
  }

  /// Convenience: get raw text file as string
  String getTextFile(String path, {Encoding encoding = utf8}) {
    return encoding.decode(getFile(path));
  }

  /// Returns the original EPUB file path (on disk).
  String get epubFilePath => _epubFilePath;
}
