import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import 'loader.dart';
import 'epub.dart';

class ReaderScreen extends StatefulWidget {
  final Loader loader;
  final EpubReader reader;
  final int initialChapter;

  const ReaderScreen({
    super.key,
    required this.loader,
    required this.reader,
    this.initialChapter = 0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late EpubReader _reader;
  int _currentChapter = 0;
  final ScrollController _scrollController = ScrollController();
  bool _showFloatingBar = true;
  double _lastOffset = 0;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader;
    _currentChapter = widget.initialChapter;
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
    } else if (currentOffset > _lastOffset && currentOffset > 100) {
      if (_showFloatingBar) setState(() => _showFloatingBar = false);
    }
    _lastOffset = currentOffset;
  }

  void _openChapter(int index) {
    setState(() {
      _currentChapter = index;
      _showFloatingBar = true;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _navigateToHref(String? href) {
    if (href == null) return;
    final baseHref = href.split('#').first;
    for (int i = 0; i < _reader.chapterCount; i++) {
      if (_reader.getChapterHref(i) == baseHref) {
        _openChapter(i);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cleanHtml = _reader.getCleanChapterHtml(_currentChapter);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      key: _scaffoldKey,
      body: SafeArea(
        top: true,
        bottom: false,
        child: Stack(
          children: [
            ListView(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(20, 20, 20, 120 + bottomInset),
              children: [
                HtmlWidget(
                  cleanHtml,
                  customWidgetBuilder: (element) {
                    try {
                      if (element.localName != 'img') return null;
                      final src = element.attributes['src'] ?? '';
                      if (_reader == null || src.isEmpty) return null;

                      final bytes = _reader.getImageBytesForChapter(
                        _currentChapter,
                        src,
                      );
                      if (bytes != null) {
                        return Image.memory(bytes, fit: BoxFit.contain);
                      }
                    } catch (_) {}
                    return null;
                  },
                  textStyle: const TextStyle(
                    fontSize: 18,
                    height: 1.6,
                    fontFamily: 'Georgia',
                  ),
                ),
              ],
            ),

            // Floating bar
            Positioned(
              bottom: bottomInset + 24,
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
            ),
          ],
        ),
      ),
      drawer: _buildTocDrawer(),
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
                "${_currentChapter + 1} / ${_reader.chapterCount}",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _currentChapter < _reader.chapterCount - 1
                  ? () => _openChapter(_currentChapter + 1)
                  : null,
              tooltip: "Next Chapter",
            ),
            const SizedBox(width: 4),
            SizedBox(
              height: 24,
              child: VerticalDivider(
                color: Theme.of(
                  context,
                ).colorScheme.onSecondaryContainer.withOpacity(0.3),
                thickness: 1,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.menu_open_rounded),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              tooltip: "Table of Contents",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTocDrawer() {
    final metadata = _reader.getMetadata();
    final currentHref = _reader.getChapterHref(_currentChapter);

    return Drawer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
            color: Theme.of(
              context,
            ).colorScheme.surfaceVariant.withOpacity(0.5),
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
              children: _buildFlatTocList(_reader.toc, currentHref),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFlatTocList(
    List<dynamic> nodes,
    String? currentHref, {
    int depth = 0,
  }) {
    List<Widget> tiles = [];
    for (var node in nodes) {
      final isSelected =
          node.href != null && node.href.split('#').first == currentHref;

      tiles.add(
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: isSelected,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.primaryContainer.withOpacity(0.3),
          contentPadding: EdgeInsets.only(
            left: 24.0 + (depth * 16.0),
            right: 16.0,
          ),
          title: Text(
            node.title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected
                  ? FontWeight.bold
                  : (depth == 0 ? FontWeight.w600 : FontWeight.normal),
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          onTap: () => _navigateToHref(node.href),
        ),
      );

      if (node.children != null && node.children.isNotEmpty) {
        tiles.addAll(
          _buildFlatTocList(node.children, currentHref, depth: depth + 1),
        );
      }
    }
    return tiles;
  }
}
