import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

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
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  void _openChapter(int index) {
    if (_reader == null) return;
    setState(() => _currentChapter = index);
    Navigator.pop(context); // close drawer if open
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_reader?.getMetadata()['title'] ?? 'EPUB Reader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            onPressed: _pickBook,
          ),
        ],
      ),
      drawer: _isBookLoaded ? _buildTocDrawer() : null,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !_isBookLoaded
              ? _buildEmptyState()
              : _buildChapterView(),
      bottomNavigationBar: _isBookLoaded ? _buildNavBar() : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: ElevatedButton.icon(
        icon: const Icon(Icons.file_open),
        label: const Text("Select EPUB File"),
        onPressed: _pickBook,
      ),
    );
  }

  Widget _buildChapterView() {
    final html = _reader!.getChapterHtml(_currentChapter);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        HtmlWidget(
          html,
          textStyle: const TextStyle(fontSize: 18, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildNavBar() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _currentChapter > 0
                ? () => _openChapter(_currentChapter - 1)
                : null,
          ),
          Text("Chapter ${_currentChapter + 1}/${_reader!.chapterCount}"),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: _currentChapter < _reader!.chapterCount - 1
                ? () => _openChapter(_currentChapter + 1)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildTocDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Colors.indigo.shade100),
            child: Text(
              _reader!.getMetadata()['title'] ?? 'Table of Contents',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          ..._reader!.toc.map((node) => ListTile(
                title: Text(node.title),
                onTap: () => _navigateToHref(node.href),
              )),
        ],
      ),
    );
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
