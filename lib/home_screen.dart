import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// Your local imports
import 'loader.dart';
import 'epub.dart';
import 'reader.dart';
import 'library_entry.dart';
import 'book_card.dart';

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
                  (context, index) => BookCard(
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
