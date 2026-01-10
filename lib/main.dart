import 'package:flutter/material.dart';
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
      title: 'EPUB Reader',
      debugShowCheckedModeBanner: false,
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
  Loader? _loader;
  EpubReader? _reader;
  int _currentChapter = 0;

  bool _isLoading = false;
  bool _isBookLoaded = false;

  final ScrollController _scrollController = ScrollController();
  bool _showFloatingBar = true;
  double _lastOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    
    final currentOffset = _scrollController.offset;

    if (currentOffset < _lastOffset || 
        currentOffset <= 0 ||
        currentOffset >= _scrollController.position.maxScrollExtent - 50) {
      if (!_showFloatingBar) setState(() => _showFloatingBar = true);
    } 
    else if (currentOffset > _lastOffset && currentOffset > 100) {
      if (_showFloatingBar) setState(() => _showFloatingBar = false);
    }
    _lastOffset = currentOffset;
  }

  Future<void> _pickBook() async {
    setState(() => _isLoading = true);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: true,
    );
    if (result != null && result.files.single.bytes != null) {
      _loader = Loader.fromBytes(result.files.single.bytes!);
      _reader = EpubReader(_loader!);
      _reader!.init(); 
      setState(() {
        _isBookLoaded = true;
        _currentChapter = 0;
        _isLoading = false;
        _showFloatingBar = true;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _clearCache() async {
    setState(() => _isLoading = true);
    try {
      final bool? cleared = await FilePicker.platform.clearTemporaryFiles();
      // FilePicker returns `true` if cleared, `false` if nothing to clear, or null on some platforms
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

  void _openChapter(int index) {
    if (_reader == null) return;
    setState(() {
      _currentChapter = index;
      _showFloatingBar = true;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (innerContext) => Stack(
          children: [
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : !_isBookLoaded
                    ? _buildEmptyState()
                    : _buildChapterView(),

            if (_isBookLoaded && !_isLoading)
              _buildAnimatedFloatingBar(innerContext),
          ],
        ),
      ),
      drawer: _isBookLoaded ? _buildTocDrawer() : null,
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
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.file_open),
            label: const Text("Select EPUB File"),
            onPressed: _isLoading ? null : _pickBook,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text("Clear cache"),
            onPressed: _isLoading ? null : _clearCache,
          ),
        ],
      ),
    );
  }

  Widget _buildChapterView() {
    final rawHtml = _reader!.getChapterHtml(_currentChapter) ?? "<p>Empty chapter</p>";

    // Parse and remove any <title> elements so flutter_widget_from_html doesn't render them.
    String cleanHtml;
    try {
      final document = html_parser.parse(rawHtml);
      // Remove all <title> tags (commonly inside <head>)
      document.getElementsByTagName('title').forEach((e) => e.remove());
      // Use body innerHtml if available (avoids including <html> / <head>)
      cleanHtml = document.body?.innerHtml ?? document.outerHtml;
    } catch (e) {
      // If parsing fails for any reason, fall back to original HTML
      cleanHtml = rawHtml;
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 120),
      children: [
        HtmlWidget(
          cleanHtml, 
          textStyle: const TextStyle(
            fontSize: 18, 
            height: 1.6,
            fontFamily: 'Georgia',
          )
        ),
      ],
    );
  }

  Widget _buildAnimatedFloatingBar(BuildContext context) {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedSlide(
          offset: _showFloatingBar ? Offset.zero : const Offset(0, 2),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          child: AnimatedOpacity(
            opacity: _showFloatingBar ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: _buildFloatingBarContent(context),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingBarContent(BuildContext context) {
    return Card(
      elevation: 4,
      shadowColor: Colors.black26,
      color: Theme.of(context).colorScheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _currentChapter > 0
                  ? () => _openChapter(_currentChapter - 1)
                  : null,
              tooltip: "Previous Chapter",
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              constraints: const BoxConstraints(minWidth: 80),
              child: Text(
                "${_currentChapter + 1} / ${_reader!.chapterCount}",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _currentChapter < _reader!.chapterCount - 1
                  ? () => _openChapter(_currentChapter + 1)
                  : null,
              tooltip: "Next Chapter",
            ),
            const SizedBox(width: 4),
            SizedBox(
              height: 24,
              child: VerticalDivider(
                color: Theme.of(context).colorScheme.onSecondaryContainer.withOpacity(0.3),
                thickness: 1,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.menu_open_rounded),
              onPressed: () => Scaffold.of(context).openDrawer(),
              tooltip: "Table of Contents",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTocDrawer() {
    final metadata = _reader!.getMetadata();
    final currentHref = _reader!.getChapterHref(_currentChapter);

    return Drawer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
            color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "CONTENTS",
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  metadata['title'] ?? 'Book Contents',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: _buildFlatTocList(_reader!.toc, currentHref),
            ),
          ),
        ],
      ),
    );
  }

  /// Flattens the TOC tree into a list of tiles with indentation
  List<Widget> _buildFlatTocList(List<dynamic> nodes, String? currentHref, {int depth = 0}) {
    List<Widget> tiles = [];
    for (var node in nodes) {
      final isSelected = node.href != null && node.href.split('#').first == currentHref;
      
      tiles.add(
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: isSelected,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
          contentPadding: EdgeInsets.only(left: 24.0 + (depth * 16.0), right: 16.0),
          title: Text(
            node.title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : (depth == 0 ? FontWeight.w600 : FontWeight.normal),
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          onTap: () => _navigateToHref(node.href),
        ),
      );

      if (node.children != null && node.children.isNotEmpty) {
        tiles.addAll(_buildFlatTocList(node.children, currentHref, depth: depth + 1));
      }
    }
    return tiles;
  }

  void _navigateToHref(String? href) {
    if (href == null) return;
    final baseHref = href.split('#').first;
    for (int i = 0; i < _reader!.chapterCount; i++) {
      if (_reader!.getChapterHref(i) == baseHref) {
        _openChapter(i);
        break;
      }
    }
  }
}
