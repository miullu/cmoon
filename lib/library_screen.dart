import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'database_helper.dart';
import 'reader_screen.dart';
import 'epub_service.dart';
import 'package:archive/archive_io.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Book> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshLibrary();
  }

  Future<void> _refreshLibrary() async {
    setState(() => _isLoading = true);
    final data = await DatabaseHelper.instance.fetchAllBooks();
    setState(() {
      _books = data;
      _isLoading = false;
    });
  }

  Future<void> _importFolder() async {
    // CHANGE: Use pickFiles with allowMultiple instead of getDirectoryPath.
    // This avoids SAF permission issues because the OS grants access to specific selected files.
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      allowMultiple: true,
    );

    if (result != null) {
      // Show loading while processing
      setState(() => _isLoading = true);

      // result.paths contains the paths to the selected files
      for (var path in result.paths) {
        if (path != null) {
          await _processAndSaveBook(path);
        }
      }

      // Refresh the library after importing
      await _refreshLibrary();
    }
  }

  Future<void> _processAndSaveBook(String path) async {
    try {
      final inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(inputStream);

      // Extract metadata using the service
      final meta = EpubService.extractMetadata(archive);

      final book = Book(
        title: meta['title'] ?? path.split('/').last,
        author: meta['author'] ?? 'Unknown Author',
        path: path,
        thumbnail: meta['thumbnail'], // Uint8List from EPUB
      );

      await DatabaseHelper.instance.insertBook(book);
    } catch (e) {
      debugPrint("Error importing $path: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_to_photos),
            onPressed: _importFolder,
            tooltip: 'Import SAF Folder',
          ),
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () {
              // Open temporary file without saving to library
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ReaderHome(isTemp: true),
                ),
              );
            },
            tooltip: 'Quick Open (Temp)',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
          ? const Center(
              child: Text('No books found. Import a folder to start.'),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.7,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final book = _books[index];
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ReaderHome(bookPath: book.path),
                      ),
                    );
                  },
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: book.thumbnail != null
                              ? Image.memory(
                                  book.thumbnail!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                )
                              : Container(
                                  color: Colors.grey[300],
                                  child: const Icon(
                                    Icons.book,
                                    size: 50,
                                    color: Colors.grey,
                                  ),
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
