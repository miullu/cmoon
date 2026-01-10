import 'dart:typed_data';
import 'dart:convert';
import 'package:xml/xml.dart';
import 'package:html/parser.dart' as html_parser;
import 'loader.dart';

class TocNode {
  final String title;
  final String? href;
  final List<TocNode> children;

  TocNode({required this.title, this.href, List<TocNode>? children})
    : children = children ?? const [];
}

class EpubReader {
  final Loader loader;

  String? _opfPath;
  Map<String, String>? _metadata;
  List<String>? _spineIds;
  Map<String, String>? _manifestIdToHref;
  Map<String, String>? _manifestIdToMediaType;
  Map<String, String>? _manifestIdToProperties;
  List<TocNode>? _toc;
  String? _coverId;

  EpubReader(this.loader);

  void init() {
    _opfPath = _locateOpfPath();
    final opfXml = _loadXml(_opfPath!);
    final package = opfXml.findElements('package').first;

    _parseMetadata(package);
    _parseManifest(package);
    _parseSpine(package);

    _toc = _parseToc(package);
  }

  // --- Initialization Helpers ---

  String _locateOpfPath() {
    final bytes = loader.getFile('META-INF/container.xml');
    final xml = XmlDocument.parse(utf8.decode(bytes));
    final path = xml
        .findAllElements('rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    if (path == null)
      throw Exception("Could not find OPF path in container.xml");
    return path;
  }

  void _parseMetadata(XmlElement package) {
    final metadataBase = package.findElements('metadata').first;
    _metadata = {
      for (var node in metadataBase.children.whereType<XmlElement>())
        node.name.local: node.innerText,
    };

    _coverId = metadataBase
        .findElements('meta')
        .firstWhere(
          (m) => m.getAttribute('name')?.toLowerCase() == 'cover',
          orElse: () => XmlElement(XmlName('none')),
        )
        .getAttribute('content');
  }

  void _parseManifest(XmlElement package) {
    _manifestIdToHref = {};
    _manifestIdToMediaType = {};
    _manifestIdToProperties = {};

    final manifestBase = package.findElements('manifest').first;
    for (var item in manifestBase.findElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        _manifestIdToHref![id] = Uri.decodeFull(href);
        _manifestIdToMediaType![id] = item.getAttribute('media-type') ?? '';
        _manifestIdToProperties![id] = item.getAttribute('properties') ?? '';
      }
    }
  }

  void _parseSpine(XmlElement package) {
    final spineBase = package.findElements('spine').first;
    _spineIds = spineBase
        .findElements('itemref')
        .map((e) => e.getAttribute('idref'))
        .whereType<String>()
        .toList();
  }

  // --- Path & File Logic ---

  String _getAbsolutePath(String relativeHref) =>
      _resolvePath(_opfPath!, relativeHref);

  XmlDocument _loadXml(String path) =>
      XmlDocument.parse(utf8.decode(loader.getFile(path)));

  /// Resolves relative paths like "../../image.png" against a context directory
  String _resolvePath(String contextPath, String relativePath) {
    final parts = contextPath.split('/')..removeLast();
    for (var part in relativePath.split('/')) {
      if (part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  // --- Table of Contents ---

  List<TocNode> _parseToc(XmlElement package) {
    // 1. Try EPUB 3 <nav>
    final navId = _manifestIdToProperties?.entries
        .firstWhere(
          (e) => e.value.contains('nav'),
          orElse: () => const MapEntry('', ''),
        )
        .key;

    if (navId != null && navId.isNotEmpty) {
      final href = _manifestIdToHref![navId];
      if (href != null) {
        try {
          return _parseNav(_loadXml(_getAbsolutePath(href)));
        } catch (_) {}
      }
    }

    // 2. Try EPUB 2 NCX
    final ncxId = package.findElements('spine').first.getAttribute('toc');
    final ncxHref = _manifestIdToHref?[ncxId];
    if (ncxHref != null) {
      try {
        return _parseNcx(_loadXml(_getAbsolutePath(ncxHref)));
      } catch (_) {}
    }

    return [];
  }

  List<TocNode> _parseNav(XmlDocument doc) {
    final list = doc
        .findAllElements('nav')
        .firstOrNull
        ?.findElements('ol')
        .firstOrNull;
    if (list == null) return [];

    List<TocNode> parseLi(XmlElement li) {
      final anchor = li.findElements('a').firstOrNull;
      final subList = li.findElements('ol').firstOrNull;
      return [
        TocNode(
          title: anchor?.innerText.trim() ?? "Untitled",
          href: anchor?.getAttribute('href'),
          children: subList?.findElements('li').expand(parseLi).toList() ?? [],
        ),
      ];
    }

    return list.findElements('li').expand(parseLi).toList();
  }

  List<TocNode> _parseNcx(XmlDocument doc) {
    TocNode parsePoint(XmlElement node) => TocNode(
      title:
          node.findElements('navLabel').firstOrNull?.innerText.trim() ??
          "Untitled",
      href: node.findElements('content').firstOrNull?.getAttribute('src'),
      children: node.findElements('navPoint').map(parsePoint).toList(),
    );

    return doc
            .findAllElements('navMap')
            .firstOrNull
            ?.findElements('navPoint')
            .map(parsePoint)
            .toList() ??
        [];
  }

  // --- Public API ---

  String getChapterHtml(int index) {
    final href = getChapterHref(index);
    if (href == null) throw Exception("Invalid chapter index");
    return utf8.decode(loader.getFile(_getAbsolutePath(href)));
  }

  String getCleanChapterHtml(int index) {
    try {
      final document = html_parser.parse(getChapterHtml(index));
      document.getElementsByTagName('title').forEach((e) => e.remove());
      return document.body?.innerHtml ?? document.outerHtml;
    } catch (_) {
      return getChapterHtml(index);
    }
  }

  String? getChapterHref(int index) {
    if (_spineIds == null || index < 0 || index >= _spineIds!.length)
      return null;
    return _manifestIdToHref?[_spineIds![index]];
  }

  Uint8List? getImageBytesForChapter(int chapterIndex, String hrefFromHtml) {
    final chapterHref = getChapterHref(chapterIndex);
    if (chapterHref == null) return null;

    final chapterAbsPath = _getAbsolutePath(chapterHref);
    final imgPath = _resolvePath(chapterAbsPath, hrefFromHtml);
    return loader.getFile(imgPath);
  }

  Uint8List? getThumbnailBytes() {
    if (_manifestIdToHref == null) return null;

    bool isImg(String id) =>
        _manifestIdToMediaType?[id]?.startsWith('image/') ?? false;

    // Ordered strategies for finding the cover
    final coverHrefs = [
      if (_coverId != null) _manifestIdToHref![_coverId],
      ..._manifestIdToHref!.entries
          .where(
            (e) =>
                _manifestIdToProperties?[e.key]?.contains('cover-image') ??
                false,
          )
          .map((e) => e.value),
      ..._manifestIdToHref!.entries
          .where(
            (e) =>
                (e.key.contains('cover') || e.value.contains('cover')) &&
                isImg(e.key),
          )
          .map((e) => e.value),
    ];

    for (final href in coverHrefs) {
      if (href != null) return loader.getFile(_getAbsolutePath(href));
    }

    // Ultimate fallback: First image
    final firstImg = _manifestIdToHref!.entries
        .firstWhere((e) => isImg(e.key), orElse: () => const MapEntry('', ''))
        .value;
    return firstImg.isNotEmpty
        ? loader.getFile(_getAbsolutePath(firstImg))
        : null;
  }

  Map<String, String> getMetadata() => _metadata ?? {};
  int get chapterCount => _spineIds?.length ?? 0;
  List<TocNode> get toc => _toc ?? [];
}
