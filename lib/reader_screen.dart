import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import 'models.dart';
import 'epub_service.dart';

class ReaderHome extends StatefulWidget {
  final String? bookPath;
  final bool isTemp;

  const ReaderHome({super.key, this.bookPath, this.isTemp = false});

  @override
  State<ReaderHome> createState() => _ReaderHomeState();
}

class _ReaderHomeState extends State<ReaderHome> {
  final Map<String, ArchiveFile> _fileMap = {};
  List<Chapter> _chapters = [];
  
  List<String> _chapterSegments = [];
  
  int _currentChapterIndex = -1;
  bool _loading = false;

  final ScrollController _scrollController = ScrollController();
  bool _isNavBarVisible = true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);

    if (widget.bookPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadBook(widget.bookPath!);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    if (maxScroll - currentScroll <= 50) {
      if (!_isNavBarVisible) setState(() => _isNavBarVisible = true);
      return;
    }

    if (_scrollController.position.userScrollDirection == ScrollDirection.forward) {
      if (!_isNavBarVisible) setState(() => _isNavBarVisible = true);
    } else if (_scrollController.position.userScrollDirection == ScrollDirection.reverse) {
      if (_isNavBarVisible) setState(() => _isNavBarVisible = false);
    }
  }

  Future<void> _loadBook(String path) async {
    try {
      setState(() => _loading = true);
      _fileMap.clear();

      Archive? archive;

      final file = File(path);
      if (await file.exists()) {
        // Load file into RAM
        final bytes = await file.readAsBytes();
        archive = ZipDecoder().decodeBytes(bytes);
      } else {
        _showError("File not found: $path");
        return;
      }

      if (archive != null) {
        for (final f in archive) {
          _fileMap[EpubService.normalizePath(f.name)] = f;
        }

        final parsed = EpubService.parsePackage(_fileMap);
        if (parsed != null && parsed.chapters.isNotEmpty) {
          setState(() => _chapters = parsed.chapters);
          _loadChapterByIndex(0);
        }
      }
    } catch (e) {
      _showError("Error loading book: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      _loadBook(result.files.single.path!);
    }
  }

  void _loadChapterByIndex(int index) {
    if (index < 0 || index >= _chapters.length) return;
    final chapter = _chapters[index];
    try {
      final cleanPath = chapter.path.split('#').first;
      final file = _fileMap[EpubService.normalizePath(cleanPath)];
      if (file == null) return;

      final rawHtml = utf8.decode(file.content as List<int>);
      
      setState(() {
        _chapterSegments = [rawHtml];
        _currentChapterIndex = index;
        _isNavBarVisible = true;
      });
      
    } catch (e) {
      debugPrint("Error loading chapter: $e");
      _showError('Failed to load chapter');
    }
  }

  Uint8List? _getImageBytes(String src) {
    if (_currentChapterIndex < 0 || _currentChapterIndex >= _chapters.length) return null;
    
    if (src.startsWith('http')) return null;

    try {
      final chapter = _chapters[_currentChapterIndex];
      final chapterPath = chapter.path.split('#').first;
      
      final baseUri = Uri.parse(chapterPath);
      final resolvedUri = baseUri.resolve(src);
      
      final resolvedPath = Uri.decodeFull(resolvedUri.path);

      final file = _fileMap[EpubService.normalizePath(resolvedPath)];
      if (file == null) return null;

      final content = file.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
    } catch (e) {
      debugPrint("Error resolving image $src: $e");
    }
    return null;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 40,
        title: _currentChapterIndex == -1 ? null : _buildProgressHeader(),
      ),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          _buildContent(),
          if (_chapters.isNotEmpty) _buildFloatingActions(colorScheme),
        ],
      ),
    );
  }

  Widget _buildProgressHeader() {
    return Column(
      children: [
        Text(
          _chapters[_currentChapterIndex].title.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            color: Colors.grey,
            letterSpacing: 1.1,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: (_currentChapterIndex + 1) / _chapters.length,
          minHeight: 2,
          backgroundColor: Colors.grey.withOpacity(0.1),
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView.builder(
        itemCount: _chapters.length,
        itemBuilder: (context, index) {
          final c = _chapters[index];
          return ListTile(
            title: Text(
              c.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: index == _currentChapterIndex
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
            onTap: () {
              Navigator.pop(context);
              _loadChapterByIndex(index);
            },
          );
        },
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    
    if (_chapterSegments.isEmpty) {
      return Center(
        child: TextButton.icon(
          onPressed: _openFile,
          icon: const Icon(Icons.file_open),
          label: const Text("Select an EPUB"),
        ),
      );
    }

    return ListView.builder(
      key: ValueKey(_currentChapterIndex),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 100),
      cacheExtent: 500,
      itemCount: _chapterSegments.length,
      itemBuilder: (context, index) {
        return HtmlWidget(
          _chapterSegments[index],
          textStyle: const TextStyle(fontSize: 16),
          renderMode: RenderMode.column, 
          customWidgetBuilder: (element) {
            if (element.localName == 'img' && element.attributes.containsKey('src')) {
              final src = element.attributes['src']!;
              final bytes = _getImageBytes(src);
              if (bytes != null) {
                return Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                );
              }
            }
            return null;
          },
        );
      },
    );
  }

  Widget _buildFloatingActions(ColorScheme colorScheme) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      bottom: _isNavBarVisible ? 20 : -80,
      left: 20,
      right: 20,
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: _currentChapterIndex > 0
                  ? () => _loadChapterByIndex(_currentChapterIndex - 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined),
              onPressed: () => Navigator.pop(context),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
              onPressed: _currentChapterIndex < _chapters.length - 1
                  ? () => _loadChapterByIndex(_currentChapterIndex + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
