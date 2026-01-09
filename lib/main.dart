import 'dart:typed_data';
import 'dart:ui'; // Required for ImageFilter (blur)
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:html/parser.dart' as html_parser;

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
      debugShowCheckedModeBanner: false,
      title: 'EPUB Reader Pro',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
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
  // Key to control the Scaffold (opening drawer) from anywhere
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final Loader _loader = Loader();
  late EpubReader _reader;
  final ScrollController _scrollController = ScrollController();

  bool _isLoaded = false;
  bool _isProcessing = false;
  bool _showControls = true;
  int _currentChapterIndex = 0;
  List<String> _chapterChunks = [];
  String _bookTitle = "EPUB Reader";

  @override
  void initState() {
    super.initState();
    _reader = EpubReader(_loader);
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.userScrollDirection == ScrollDirection.forward) {
      if (!_showControls) setState(() => _showControls = true);
    } else if (_scrollController.position.userScrollDirection == ScrollDirection.reverse) {
      if (_showControls) setState(() => _showControls = false);
    }
    // Auto-show when reaching bottom
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 80) {
      if (!_showControls) setState(() => _showControls = true);
    }
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

  Future<void> _loadChapter(int index) async {
    setState(() {
      _isProcessing = true;
      _currentChapterIndex = index;
    });

    try {
      final rawHtml = _reader.getChapterHtml(index);
      final chunks = await compute(_chunkHtmlContent, rawHtml);

      setState(() {
        _chapterChunks = chunks;
        _isProcessing = false;
      });
      
      if (_scrollController.hasClients) {
        _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    } catch (e) {
      _showError("Error processing chapter: $e");
      setState(() => _isProcessing = false);
    }
  }

  static List<String> _chunkHtmlContent(String html) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) return [html];

    List<String> chunks = [];
    StringBuffer currentChunk = StringBuffer();
    int charCount = 0;
    const int targetChunkSize = 1800;

    for (var node in body.children) {
      String nodeHtml = node.outerHtml;
      currentChunk.write(nodeHtml);
      charCount += nodeHtml.length;
      if (charCount > targetChunkSize) {
        chunks.add(currentChunk.toString());
        currentChunk = StringBuffer();
        charCount = 0;
      }
    }
    if (currentChunk.isNotEmpty) chunks.add(currentChunk.toString());
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
    if (targetIndex != -1) {
      _loadChapter(targetIndex);
      _scaffoldKey.currentState?.closeDrawer();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey, // Attach the GlobalKey here
      drawer: _isLoaded ? _buildChapterDrawer() : null,
      body: Stack(
        children: [
          _buildBody(),
          if (_isLoaded) _buildFloatingControls(),
          if (!_isLoaded && !_isProcessing) _buildEmptyState(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isProcessing) return const Center(child: CircularProgressIndicator());
    if (!_isLoaded) return const SizedBox.shrink();
    return _buildReaderView();
  }

  Widget _buildEmptyState() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_stories, size: 100, color: Colors.indigo.withOpacity(0.2)),
          const SizedBox(height: 30),
          const Text("No Book Loaded", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _pickAndLoadFile,
            icon: const Icon(Icons.file_open),
            label: const Text("Select EPUB File"),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderView() {
    return SafeArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 120),
        itemCount: _chapterChunks.length,
        itemBuilder: (context, index) {
          return HtmlWidget(
            _chapterChunks[index],
            factoryBuilder: () => _EpubWidgetFactory(_reader, _currentChapterIndex),
            textStyle: const TextStyle(fontSize: 20, height: 1.6, color: Colors.black87),
          );
        },
      ),
    );
  }

  Widget _buildFloatingControls() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 400),
      curve: Curves.fastOutSlowIn,
      bottom: _showControls ? 40 : -100,
      left: 20,
      right: 20,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: Colors.indigo),
                    tooltip: "Open New Book",
                    onPressed: _pickAndLoadFile,
                  ),
                  const VerticalDivider(width: 20, indent: 20, endIndent: 20),
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                    onPressed: _currentChapterIndex > 0 
                        ? () => _loadChapter(_currentChapterIndex - 1) 
                        : null,
                  ),
                  GestureDetector(
                    onTap: () => _scaffoldKey.currentState?.openDrawer(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        "Chapter ${_currentChapterIndex + 1} / ${_reader.chapterCount}",
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, size: 18),
                    onPressed: _currentChapterIndex < _reader.chapterCount - 1 
                        ? () => _loadChapter(_currentChapterIndex + 1) 
                        : null,
                  ),
                  const VerticalDivider(width: 20, indent: 20, endIndent: 20),
                  IconButton(
                    icon: const Icon(Icons.format_list_bulleted, color: Colors.indigo),
                    tooltip: "Table of Contents",
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChapterDrawer() {
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: Colors.indigo.shade50,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("TABLE OF CONTENTS", 
                  style: TextStyle(letterSpacing: 1.5, fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo)),
                const SizedBox(height: 8),
                Text(_bookTitle, 
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
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
      bool isCurrent = false; // logic for highlighting current chapter could go here
      tiles.add(
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 20.0 + (depth * 20.0), right: 20.0),
          title: Text(node.title, 
            style: TextStyle(
              fontSize: 15, 
              color: Colors.black87,
              fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.w400
            )
          ),
          onTap: () => _navigateToHref(node.href),
        ),
      );
      if (node.children.isNotEmpty) {
        tiles.addAll(_buildTocTiles(node.children, depth: depth + 1));
      }
    }
    return tiles;
  }
}

class _EpubWidgetFactory extends WidgetFactory {
  final EpubReader reader;
  final int chapterIndex;
  _EpubWidgetFactory(this.reader, this.chapterIndex);
}
