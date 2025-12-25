import 'package:flutter/material.dart';
import 'library_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      // Now starting with the Library instead of the Reader directly
      home: const LibraryScreen(),
    );
  }
}
