import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

// Importing your base modules
import 'loader.dart';
import 'epub.dart';

void main() {
  runApp(const EpubReaderApp());
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter EPUB Reader',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      home: const ReaderScreen(),
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final Loader _loader = Loader();
  late EpubReader _reader;

  bool _isLoaded = false;
  int _currentChapterIndex = 0;
  String _chapterHtml = "";
  String _bookTitle = "EPUB Reader";

  @override
  void initState() {
    super.initState();
    _reader = EpubReader(_loader);
  }

  Future<void> _pickAndLoadFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
        withData: true, // Crucial to get bytes for the Loader
      );

      if (result != null && result.files.single.bytes != null) {
        final bytes = result.files.single.bytes!;

        // 1. Load the bytes into our memory-optimized loader
        _loader.loadFromBytes(bytes);

        // 2. Initialize the EPUB structure
        _reader.init();

        // 3. Update UI state
        setState(() {
          _isLoaded = true;
          _currentChapterIndex = 0;
          _bookTitle =
              _reader.getMetadata()['title'] ?? result.files.single.name;
          _loadChapter(0);
        });
      }
    } catch (e) {
      _showError("Failed to load EPUB: $e");
    }
  }

  void _loadChapter(int index) {
    setState(() {
      _currentChapterIndex = index;
      _chapterHtml = _reader.getChapterHtml(index);
    });
    // Close drawer if open
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  void _navigateToHref(String? href) {
    if (href == null) return;

    // EPUB hrefs often include anchors (e.g., chapter1.xhtml#section1)
    // We need the base filename to match our manifest
    final baseHref = href.split('#').first;

    // Find the index in the spine that matches this href
    int targetIndex = -1;
    for (int i = 0; i < _reader.chapterCount; i++) {
      // This assumes your EpubReader can expose the href for a specific index
      // Let's add a helper for this or check the manifest
      if (_reader.getChapterHref(i) == baseHref) {
        targetIndex = i;
        break;
      }
    }

    if (targetIndex != -1) {
      _loadChapter(targetIndex);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_bookTitle, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: _pickAndLoadFile,
            tooltip: "Open EPUB",
          ),
        ],
      ),
      // Only show the drawer if a book is loaded
      drawer: _isLoaded ? _buildChapterDrawer() : null,
      body: _isLoaded ? _buildReaderView() : _buildEmptyState(),
      bottomNavigationBar: _isLoaded ? _buildNavigation() : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book, size: 100, color: Colors.grey),
          const SizedBox(height: 20),
          const Text("No book loaded"),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _pickAndLoadFile,
            icon: const Icon(Icons.add),
            label: const Text("Select EPUB File"),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: HtmlWidget(
        _chapterHtml,
        // This handles images within the EPUB
        factoryBuilder: () => _EpubWidgetFactory(_reader, _currentChapterIndex),
        textStyle: const TextStyle(fontSize: 18, height: 1.5),
      ),
    );
  }

  Widget _buildChapterDrawer() {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Theme.of(context).primaryColor),
            child: Center(
              child: Text(
                _bookTitle,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              // We call a helper to build the list from the TOC tree
              children: _buildTocTiles(_reader.toc),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTocTiles(List<TocNode> nodes, {int depth = 0}) {
    List<Widget> tiles = [];
    for (var node in nodes) {
      tiles.add(
        ListTile(
          // Add indentation for nested chapters
          contentPadding: EdgeInsets.only(
            left: 16.0 + (depth * 20.0),
            right: 16.0,
          ),
          title: Text(
            node.title,
            style: TextStyle(
              fontWeight: depth == 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          onTap: () {
            _navigateToHref(node.href);
          },
        ),
      );
      // Recursively add children
      if (node.children.isNotEmpty) {
        tiles.addAll(_buildTocTiles(node.children, depth: depth + 1));
      }
    }
    return tiles;
  }

  Widget _buildNavigation() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _currentChapterIndex > 0
                ? () => _loadChapter(_currentChapterIndex - 1)
                : null,
          ),
          Text("Page ${_currentChapterIndex + 1} of ${_reader.chapterCount}"),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: _currentChapterIndex < _reader.chapterCount - 1
                ? () => _loadChapter(_currentChapterIndex + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

/// Custom Factory to handle images from the EPUB archive
class _EpubWidgetFactory extends WidgetFactory {
  final EpubReader reader;
  final int chapterIndex;

  _EpubWidgetFactory(this.reader, this.chapterIndex);

  @override
  Widget? buildImage(BuildTree tree, ImageMetadata data) {
    try {
      // In version 0.17.x+, the signature changed from ImageSource to ImageMetadata.
      // We check if the image source is a relative path to extract it from the EPUB loader.
      final src = data.sources.firstOrNull;
      if (src != null && !src.url.startsWith('http')) {
        // Logic for extracting local EPUB image bytes would go here
        // For now, we call super to maintain default behavior or fallback
        return super.buildImage(tree, data);
      }
      return super.buildImage(tree, data);
    } catch (e) {
      return const Icon(Icons.broken_image);
    }
  }
}
