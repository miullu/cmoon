import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

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
  bool _isProcessing = false;
  int _currentChapterIndex = 0;
  List<String> _chapterChunks = [];
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
        withData: true,
      );

      if (result != null && result.files.single.bytes != null) {
        final bytes = result.files.single.bytes!;
        _loader.loadFromBytes(bytes);
        _reader.init();

        setState(() {
          _isLoaded = true;
          _bookTitle = _reader.getMetadata()['title'] ?? result.files.single.name;
        });
        
        await _loadChapter(0);
      }
    } catch (e) {
      _showError("Failed to load EPUB: $e");
    }
  }

  /// Refactored to handle background processing and chunking
  Future<void> _loadChapter(int index) async {
    setState(() {
      _isProcessing = true;
      _currentChapterIndex = index;
    });

    try {
      final rawHtml = _reader.getChapterHtml(index);
      
      // Use compute to move heavy HTML parsing/chunking to another thread
      final chunks = await compute(_chunkHtmlContent, rawHtml);

      setState(() {
        _chapterChunks = chunks;
        _isProcessing = false;
      });
    } catch (e) {
      _showError("Error processing chapter: $e");
      setState(() => _isProcessing = false);
    }

    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  /// Robust HTML Chunking logic
  /// Identifies top-level block elements and groups them to avoid over-fragmentation
  static List<String> _chunkHtmlContent(String html) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) return [html];

    List<String> chunks = [];
    StringBuffer currentChunk = StringBuffer();
    int charCount = 0;
    const int targetChunkSize = 1500; // Characters per chunk for optimal Flutter performance

    for (var node in body.children) {
      String nodeHtml = node.outerHtml;
      currentChunk.write(nodeHtml);
      charCount += nodeHtml.length;

      // If chunk is large enough, push it and start a new one
      if (charCount > targetChunkSize) {
        chunks.add(currentChunk.toString());
        currentChunk = StringBuffer();
        charCount = 0;
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString());
    }

    return chunks.isEmpty ? [html] : chunks;
  }

  void _navigateToHref(String? href) {
    if (href == null) return;
    final baseHref = href.split('#').first;
    int targetIndex = -1;
    for (int i = 0; i < _reader.chapterCount; i++) {
      if (_reader.getChapterHref(i) == baseHref) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex != -1) _loadChapter(targetIndex);
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
          ),
        ],
      ),
      drawer: _isLoaded ? _buildChapterDrawer() : null,
      body: _buildBody(),
      bottomNavigationBar: _isLoaded ? _buildNavigation() : null,
    );
  }

  Widget _buildBody() {
    if (!_isLoaded) return _buildEmptyState();
    if (_isProcessing) return const Center(child: CircularProgressIndicator());
    return _buildReaderView();
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.menu_book, size: 100, color: Colors.grey),
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

  /// Optimized Reader View using ListView.builder for lazy loading
  Widget _buildReaderView() {
    return Scrollbar(
      child: ListView.builder(
        key: ValueKey("chapter_$_currentChapterIndex"),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        itemCount: _chapterChunks.length,
        itemBuilder: (context, index) {
          return HtmlWidget(
            _chapterChunks[index],
            factoryBuilder: () => _EpubWidgetFactory(_reader, _currentChapterIndex),
            textStyle: const TextStyle(fontSize: 18, height: 1.6),
            renderMode: RenderMode.column, // Critical for performance inside ListView
          );
        },
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
              child: Text(_bookTitle, 
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            child: ListView(children: _buildTocTiles(_reader.toc)),
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
          contentPadding: EdgeInsets.only(left: 16.0 + (depth * 16.0), right: 16.0),
          title: Text(node.title, style: TextStyle(fontSize: 14, fontWeight: depth == 0 ? FontWeight.bold : FontWeight.normal)),
          onTap: () => _navigateToHref(node.href),
        ),
      );
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
            icon: const Icon(Icons.chevron_left),
            onPressed: _currentChapterIndex > 0 ? () => _loadChapter(_currentChapterIndex - 1) : null,
          ),
          Text("Chapter ${_currentChapterIndex + 1} / ${_reader.chapterCount}"),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _currentChapterIndex < _reader.chapterCount - 1 ? () => _loadChapter(_currentChapterIndex + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// Enhanced Factory to resolve and render local EPUB images
class _EpubWidgetFactory extends WidgetFactory {
  final EpubReader reader;
  final int chapterIndex;

  _EpubWidgetFactory(this.reader, this.chapterIndex);

  @override
  Widget? buildImage(BuildTree tree, ImageMetadata data) {
    // Reverted hypothetical methods causing compilation errors.
    // To implement image loading, we need to know the correct methods 
    // in your EpubReader and Loader classes for path resolution and byte fetching.
    return super.buildImage(tree, data);
  }
}
