import 'dart:typed_data';
import 'dart:convert';
import 'package:xml/xml.dart';
import 'loader.dart';

class EpubReader {
  final Loader loader;

  String? _opfPath;
  Map<String, String>? _metadata;
  List<String>? _spineIds;
  List<String>? _toc;

  EpubReader(this.loader);

  /// Initialize by loading container.xml and parsing OPF
  Future<void> init() async {
    final containerBytes = loader.getFile('META-INF/container.xml');
    final containerXml = XmlDocument.parse(utf8.decode(containerBytes));

    final rootfile = containerXml
        .findAllElements('rootfile')
        .map((e) => e.getAttribute('full-path'))
        .firstWhere((p) => p != null, orElse: () => null);

    if (rootfile == null) {
      throw Exception("OPF file not found in container.xml");
    }

    _opfPath = rootfile;

    final opfBytes = loader.getFile(_opfPath!);
    final opfDoc = XmlDocument.parse(utf8.decode(opfBytes));

    // Extract metadata immediately, then discard opfDoc later
    _metadata = _extractMetadata(opfDoc);
    _spineIds = _extractSpine(opfDoc);
    _toc = _extractTOC(opfDoc);

    // Drop heavy XML tree
    // (we keep only lightweight maps/lists)
  }

  Map<String, String> _extractMetadata(XmlDocument doc) {
    final metadata = <String, String>{};
    final metaElement = doc.findAllElements('metadata').first;

    String _getText(String name, {String? namespace}) {
      final elems = namespace != null
          ? metaElement.findElements(name, namespace: namespace)
          : metaElement.findElements(name);
      return elems.map((e) => e.text.trim()).join(',');
    }

    metadata['title'] = _getText('title', namespace: 'dc');
    metadata['author'] = _getText('creator', namespace: 'dc');
    metadata['language'] = _getText('language', namespace: 'dc');
    metadata['publisher'] = _getText('publisher', namespace: 'dc');
    metadata['identifier'] = _getText('identifier', namespace: 'dc');

    return metadata;
  }

  List<String> _extractSpine(XmlDocument doc) {
    final spine = doc.findAllElements('spine').first;
    return spine.findElements('itemref')
        .map((e) => e.getAttribute('idref') ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  List<String> _extractTOC(XmlDocument doc) {
    // Try EPUB 3 nav
    try {
      final navItem = doc
          .findAllElements('item')
          .firstWhere((e) =>
              e.getAttribute('properties')?.contains('nav') ?? false);
      final href = navItem.getAttribute('href');
      final basePath = _opfPath!.substring(0, _opfPath!.lastIndexOf('/') + 1);
      final navPath = basePath + href!;
      final navBytes = loader.getFile(navPath);
      final navDoc = XmlDocument.parse(utf8.decode(navBytes));

      final navElement = navDoc
          .findAllElements('nav')
          .firstWhere((e) => e.getAttribute('epub:type') == 'toc',
              orElse: () => navDoc.findAllElements('nav').first);

      final toc = navElement
          .findAllElements('a')
          .map((e) => e.text.trim())
          .toList();

      return toc;
    } catch (_) {
      // Fallback: EPUB 2 NCX
      try {
        final ncxItem = doc
            .findAllElements('item')
            .firstWhere((e) =>
                e.getAttribute('media-type') == 'application/x-dtbncx+xml');
        final href = ncxItem.getAttribute('href');
        final basePath = _opfPath!.substring(0, _opfPath!.lastIndexOf('/') + 1);
        final ncxPath = basePath + href!;
        final ncxBytes = loader.getFile(ncxPath);
        final ncxDoc = XmlDocument.parse(utf8.decode(ncxBytes));

        final toc = ncxDoc
            .findAllElements('navPoint')
            .map((e) =>
                e.findElements('text').map((t) => t.text.trim()).join())
            .toList();

        return toc;
      } catch (_) {
        return _extractSpine(doc);
      }
    }
  }

  /// Public getters (lightweight structures only)
  Map<String, String> getMetadata() => _metadata ?? {};
  List<String> getSpineIds() => _spineIds ?? [];
  List<String> getTOC() => _toc ?? [];

  /// Return chapter HTML as string
  String getChapterHtml(int index) {
    if (_spineIds == null) throw Exception("EPUB not initialized");
    if (index < 0 || index >= _spineIds!.length) {
      throw Exception("Chapter index out of range");
    }

    final id = _spineIds![index];
    // Resolve manifest item again (we don’t keep full manifest in memory)
    final opfBytes = loader.getFile(_opfPath!);
    final opfDoc = XmlDocument.parse(utf8.decode(opfBytes));
    final manifestItem = opfDoc
        .findAllElements('item')
        .firstWhere((e) => e.getAttribute('id') == id);

    final href = manifestItem.getAttribute('href');
    final basePath = _opfPath!.substring(0, _opfPath!.lastIndexOf('/') + 1);
    final chapterPath = basePath + href!;

    final chapterBytes = loader.getFile(chapterPath);
    return utf8.decode(chapterBytes);
  }

  Uint8List getImage(String id) {
    final opfBytes = loader.getFile(_opfPath!);
    final opfDoc = XmlDocument.parse(utf8.decode(opfBytes));
    final manifestItem = opfDoc
        .findAllElements('item')
        .firstWhere((e) => e.getAttribute('id') == id);

    final href = manifestItem.getAttribute('href');
    final basePath = _opfPath!.substring(0, _opfPath!.lastIndexOf('/') + 1);
    final imagePath = basePath + href!;
    return loader.getFile(imagePath);
  }
}
