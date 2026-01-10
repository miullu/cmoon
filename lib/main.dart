import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// Assuming these are your existing local files
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
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<LibraryEntry> _library = [];
  bool _isLoading = true;
  static const _prefsKey = 'epub_library_v2';

  @override
  void initState() {
    super.initState();
    _initLibrary();
  }

  Future<void> _initLibrary() async {
    await _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;

      final List<dynamic> decoded = jsonDecode(raw);
      final List<LibraryEntry> validEntries = [];

      for (var item in decoded) {
        final entry = LibraryEntry.fromJson(Map<String, dynamic>.from(item));
        if (File(entry.pathOnDisk).existsSync()) {
          validEntries.add(entry);
        }
      }

      setState(() {
        _library.clear();
        _library.addAll(validEntries);
      });
    } catch (e) {
      _showError("Failed to load library: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_library.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, json);
  }

  Future<void> _pickBook() async {
    try {
      final loader = await Loader.pickEpub();
      if (loader == null) return;

      setState(() => _isLoading = true);

      final reader = EpubReader(loader);
      reader.init();

      final metadata = reader.getMetadata();
      final entry = LibraryEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: metadata['title'] ?? p.basename(loader.epubFilePath),
        pathOnDisk: loader.epubFilePath,
        thumbnail: reader.getThumbnailBytes(),
      );

      setState(() {
        _library.insert(0, entry);
      });
      await _saveLibrary();
    } catch (e) {
      _showError("Could not add book: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ),
    );
  }

  Future<void> _removeEntry(LibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Remove Book?"),
        content: Text(
          "Do you want to remove '${entry.title}'? This will also delete the cached file from your device.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              "Delete Forever",
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Physical file deletion
        final file = File(entry.pathOnDisk);
        if (await file.exists()) {
          await file.delete();
        }

        setState(() {
          _library.removeWhere((e) => e.id == entry.id);
        });
        await _saveLibrary();
        _showError("Book and cached file removed.");
      } catch (e) {
        _showError("Database updated, but file could not be deleted: $e");
        // We still remove it from the UI library so the user doesn't see a broken entry
        setState(() {
          _library.removeWhere((e) => e.id == entry.id);
        });
        await _saveLibrary();
      }
    }
  }

  Future<void> _openBook(LibraryEntry entry) async {
    try {
      final loader = await entry.getLoader();
      final reader = await entry.getReader();
      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(loader: loader, reader: reader),
        ),
      );
    } catch (e) {
      _showError("Failed to open book: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('My Library'),
            actions: [
              IconButton(
                icon: const Icon(Icons.cleaning_services_outlined),
                onPressed: () async {
                  await FilePicker.platform.clearTemporaryFiles();
                  _showError("Cache cleared");
                },
                tooltip: "Clear Cache",
              ),
            ],
          ),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_library.isEmpty)
            SliverFillRemaining(child: _buildEmptyState())
          else
            SliverPadding(
              padding: const EdgeInsets.all(16.0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.65,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _BookCard(
                    entry: _library[index],
                    onTap: () => _openBook(_library[index]),
                    onDelete: () => _removeEntry(_library[index]),
                  ),
                  childCount: _library.length,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoading ? null : _pickBook,
        icon: const Icon(Icons.add),
        label: const Text("Add Book"),
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
            size: 64,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            "No books yet",
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  final LibraryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BookCard({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  entry.thumbnail != null
                      ? Image.memory(entry.thumbnail!, fit: BoxFit.cover)
                      : Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.book,
                            size: 48,
                            color: theme.colorScheme.primary.withOpacity(0.5),
                          ),
                        ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filledTonal(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: onDelete,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
