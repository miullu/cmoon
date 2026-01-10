import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'loader.dart';
import 'epub.dart';
import 'reader.dart';

void main() {
  runApp(const EpubReaderApp());
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EPUB Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      home: const HomeScreen(),
    );
  }
}

class LibraryEntry {
  final String id;
  final String title;
  final Loader loader;
  final EpubReader reader;
  final Uint8List? thumbnail;
  final String pathOnDisk;

  LibraryEntry({
    required this.id,
    required this.title,
    required this.loader,
    required this.reader,
    this.thumbnail,
    required this.pathOnDisk,
  });

  // For persistence: store only serializable pieces
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'pathOnDisk': pathOnDisk,
      'thumbnail': thumbnail != null ? base64Encode(thumbnail!) : null,
    };
  }

  static Map<String, dynamic> schemaFromJson(Map<String, dynamic> map) {
    // helper if needed externally
    return map;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<LibraryEntry> _library = [];
  bool _isLoading = false;
  static const _prefsKey = 'library';

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) {
        setState(() => _isLoading = false);
        return;
      }

      final List<dynamic> list = jsonDecode(raw);
      final List<LibraryEntry> restored = [];

      for (var item in list) {
        try {
          final map = Map<String, dynamic>.from(item as Map);
          final path = map['pathOnDisk'] as String? ?? '';
          if (path.isEmpty) continue;

          // If the physical file no longer exists, skip (prune)
          if (!File(path).existsSync()) continue;

          // Recreate loader/reader for the saved copy
          final loader = await Loader.fromPath(path);
          final reader = EpubReader(loader);
          reader.init();

          // thumbnail from storage if present; otherwise try to extract
          Uint8List? thumbBytes;
          final thumbBase64 = map['thumbnail'] as String?;
          if (thumbBase64 != null && thumbBase64.isNotEmpty) {
            try {
              thumbBytes = base64Decode(thumbBase64);
            } catch (_) {
              thumbBytes = null;
            }
          }
          thumbBytes ??= reader.getThumbnailBytes();

          restored.add(LibraryEntry(
            id: map['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
            title: map['title'] as String? ?? p.basename(path),
            loader: loader,
            reader: reader,
            thumbnail: thumbBytes,
            pathOnDisk: path,
          ));
        } catch (_) {
          // skip a broken entry but continue restoring others
        }
      }

      // Save pruned list back (so missing files are removed from storage)
      _library.clear();
      _library.addAll(restored);
      await _saveLibrary();
    } catch (e) {
      // ignore load errors; start with empty library
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _library.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  Future<void> _pickBook() async {
    setState(() => _isLoading = true);
    try {
      // Use Loader.pickEpub so loader.epubFilePath points to the picked file (copy on disk)
      final loader = await Loader.pickEpub();
      if (loader == null) {
        setState(() => _isLoading = false);
        return;
      }

      final reader = EpubReader(loader);
      reader.init();

      final title = reader.getMetadata()['title'] ?? p.basename(loader.epubFilePath);
      final thumb = reader.getThumbnailBytes();
      final entry = LibraryEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: title,
        loader: loader,
        reader: reader,
        thumbnail: thumb,
        pathOnDisk: loader.epubFilePath,
      );

      setState(() {
        _library.insert(0, entry); // newest first
      });

      await _saveLibrary();

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open EPUB: $e")));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _clearCache() async {
    setState(() => _isLoading = true);
    try {
      final bool? cleared = await FilePicker.platform.clearTemporaryFiles();
      final message = (cleared == true)
          ? 'Temporary files cleared.'
          : (cleared == false)
              ? 'No temporary files to clear.'
              : 'Clear temporary files: operation completed.';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to clear cache: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openLibraryEntry(LibraryEntry entry) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(loader: entry.loader, reader: entry.reader),
    ));
  }

  Future<void> _removeEntry(LibraryEntry entry) async {
    setState(() {
      _library.removeWhere((e) => e.id == entry.id);
    });
    await _saveLibrary();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Library'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Expanded(
                    child: _library.isEmpty ? _buildEmptyState() : _buildLibraryList(),
                  ),

                  // Buttons: placed below the library; as library grows the buttons move downward.
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.file_open),
                          label: const Text("Select EPUB File"),
                          onPressed: _isLoading ? null : _pickBook,
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.delete_outline),
                          label: const Text("Clear cache"),
                          onPressed: _isLoading ? null : _clearCache,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_stories,
            size: 80,
            color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
          ),
          const SizedBox(height: 24),
          Text(
            "Your library is empty",
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryList() {
    return ListView.separated(
      itemCount: _library.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, idx) {
        final item = _library[idx];
        return Card(
          child: ListTile(
            leading: item.thumbnail != null
                ? Image.memory(item.thumbnail!, width: 48, height: 64, fit: BoxFit.cover)
                : Container(
                    width: 48,
                    height: 64,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.book, size: 28, color: Colors.grey),
                  ),
            title: Text(item.title),
            subtitle: Text(item.pathOnDisk, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _openLibraryEntry(item),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _removeEntry(item),
            ),
          ),
        );
      },
    );
  }
}
