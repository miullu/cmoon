//library_entry.dart
import 'dart:convert';
import 'dart:typed_data';

// --- IMPORTS FROM YOUR ORIGINAL FILE ---
// I have included all three to ensure EpubReader is found,
// regardless of which file explicitly defines it.
import 'loader.dart';
import 'epub.dart'; // <--- Added this back
import 'reader.dart';

/// Represents an item in the user's library.
class LibraryEntry {
  final String id;
  final String title;
  final String pathOnDisk;
  final Uint8List? thumbnail;

  // Lazily loaded to save memory in the main list
  Loader? _loader;
  EpubReader? _reader;

  LibraryEntry({
    required this.id,
    required this.title,
    required this.pathOnDisk,
    this.thumbnail,
  });

  Future<Loader> getLoader() async =>
      _loader ??= await Loader.fromPath(pathOnDisk);

  Future<EpubReader> getReader() async {
    if (_reader != null) return _reader!;

    final loader = await getLoader();

    // This constructor calls the class from your local imports
    _reader = EpubReader(loader);
    _reader!.init();

    return _reader!;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'pathOnDisk': pathOnDisk,
    'thumbnail': thumbnail != null ? base64Encode(thumbnail!) : null,
  };

  factory LibraryEntry.fromJson(Map<String, dynamic> map) {
    return LibraryEntry(
      id: map['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: map['title'] ?? 'Unknown Title',
      pathOnDisk: map['pathOnDisk'] ?? '',
      thumbnail: map['thumbnail'] != null
          ? base64Decode(map['thumbnail'])
          : null,
    );
  }
}
