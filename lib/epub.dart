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
  List<TocNode>? _toc;

  EpubReader(this.loader);

  void init() {
    // 1. Find the OPF file path via container.xml
    final containerBytes = loader.getFile('META-INF/container.xml');
    final containerXml = XmlDocument.parse(utf8.decode(containerBytes));
    final rootfile = containerXml.findAllElements('rootfile').firstOrNull;
    _opfPath = rootfile?.getAttribute('full-path');

    if (_opfPath == null) throw Exception("Could not find OPF path");

    // 2. Parse the OPF file
    final opfBytes = loader.getFile(_opfPath!);
    final opfXml = XmlDocument.parse(utf8.decode(opfBytes));
    final package = opfXml.findElements('package').first;

    // Parse Metadata
    _metadata = {};
    final metadataBase = package.findElements('metadata').first;
    for (var node in metadataBase.children) {
      if (node is XmlElement) {
        _metadata![node.name.local] = node.innerText;
      }
    }

    // Parse Manifest (ID -> Href mapping)
    _manifestIdToHref = {};
    final manifestBase = package.findElements('manifest').first;
    for (var item in manifestBase.findElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        _manifestIdToHref![id] = Uri.decodeFull(href);
      }
    }

    // Parse Spine (Linear reading order)
    _spineIds = [];
    final spineBase = package.findElements('spine').first;
    for (var item in spineBase.findElements('itemref')) {
      final idref = item.getAttribute('idref');
      if (idref != null) _spineIds!.add(idref);
    }

    // 3. Resolve Table of Contents
    _toc = _parseToc(package, manifestBase);
  }

  /// Determines if the book uses EPUB 3 Nav or EPUB 2 NCX and parses accordingly
  List<TocNode> _parseToc(XmlElement package, XmlElement manifest) {
    // Try EPUB 3 Nav (XHTML)
    final navItem = manifest
        .findElements('item')
        .firstWhere(
          (node) => node.getAttribute('properties') == 'nav',
          orElse: () => XmlElement(XmlName('none')),
        );

    if (navItem.name.local != 'none') {
      final navHref = navItem.getAttribute('href')!;
      final navPath = _resolvePath(_opfPath!, navHref);
      try {
        final navXml = XmlDocument.parse(utf8.decode(loader.getFile(navPath)));
        return _parseNav(navXml);
      } catch (_) {}
    }

    // Fallback to EPUB 2 NCX
    final spine = package.findElements('spine').first;
    final tocId = spine.getAttribute('toc');
    if (tocId != null) {
      final ncxHref = _manifestIdToHref?[tocId];
      if (ncxHref != null) {
        final ncxPath = _resolvePath(_opfPath!, ncxHref);
        try {
          final ncxXml = XmlDocument.parse(
            utf8.decode(loader.getFile(ncxPath)),
          );
          return _parseNcx(ncxXml);
        } catch (_) {}
      }
    }

    return [];
  }

  /// Parses EPUB 3 <nav> structures
  List<TocNode> _parseNav(XmlDocument doc) {
    final nav = doc.findAllElements('nav').firstOrNull;
    final list = nav?.findElements('ol').firstOrNull;
    if (list == null) return [];

    List<TocNode> parseLi(XmlElement li) {
      final anchor = li.findElements('a').firstOrNull;
      final subList = li.findElements('ol').firstOrNull;

      return [
        TocNode(
          title: anchor?.innerText.trim() ?? "Untitled",
          href: anchor?.getAttribute('href'),
          children: subList != null
              ? subList.findElements('li').expand(parseLi).toList()
              : [],
        ),
      ];
    }

    return list.findElements('li').expand(parseLi).toList();
  }

  /// Parses EPUB 2 <navMap> structures
  List<TocNode> _parseNcx(XmlDocument doc) {
    final navMap = doc.findAllElements('navMap').firstOrNull;
    if (navMap == null) return [];

    TocNode parseNavPoint(XmlElement node) {
      final text = node
          .findAllElements('navLabel')
          .firstOrNull
          ?.innerText
          .trim();
      final src = node
          .findAllElements('content')
          .firstOrNull
          ?.getAttribute('src');
      final children = node
          .findElements('navPoint')
          .map(parseNavPoint)
          .toList();

      return TocNode(title: text ?? "Untitled", href: src, children: children);
    }

    return navMap.findElements('navPoint').map(parseNavPoint).toList();
  }

  /// Robustly resolves relative paths (e.g., handling ../../)
  String _resolvePath(String contextPath, String relativePath) {
    final parts = contextPath.split('/');
    parts.removeLast();

    final relParts = relativePath.split('/');
    for (var part in relParts) {
      if (part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  String getChapterHtml(int index) {
    if (_spineIds == null || index < 0 || index >= _spineIds!.length) {
      throw Exception("Invalid chapter index");
    }

    final id = _spineIds![index];
    final href = _manifestIdToHref?[id];
    if (href == null) throw Exception("ID $id not in manifest");

    final fullPath = _resolvePath(_opfPath!, href);
    try {
      final bytes = loader.getFile(fullPath);
      return utf8.decode(bytes);
    } catch (e) {
      return "<html><body><p>Error loading chapter: $fullPath</p></body></html>";
    }
  }

  String getCleanChapterHtml(int index) {
    try {
      final raw = getChapterHtml(index);
      final document = html_parser.parse(raw);
      document.getElementsByTagName('title').forEach((e) => e.remove());

      // Resolve the chapter base path so relative image src can be resolved
      final chapterHref = getChapterHref(index);
      String? chapterFullPath;
      if (chapterHref != null && _opfPath != null) {
        chapterFullPath = _resolvePath(_opfPath!, chapterHref);
      }

      // Inline <img> sources as data URIs (skip remote and already-inlined images)
      for (var img in document.getElementsByTagName('img')) {
        final src = img.attributes['src'];
        if (src == null) continue;
        final trimmed = src.trim();

        // Skip absolute http(s) or already data URIs
        if (trimmed.startsWith('data:') ||
            trimmed.startsWith('http://') ||
            trimmed.startsWith('https://')) {
          continue;
        }

        if (chapterFullPath == null) continue;
        final imgPath = _resolvePath(chapterFullPath, trimmed);
        try {
          final bytes = loader.getFile(imgPath);
          // Determine mime type from extension
          final cleaned = imgPath.split('?').first.split('#').first;
          final ext = cleaned.contains('.') ? cleaned.split('.').last.toLowerCase() : '';
          String mime;
          if (ext == 'svg' || ext == 'svgz') mime = 'image/svg+xml';
          else if (ext == 'jpg' || ext == 'jpeg') mime = 'image/jpeg';
          else if (ext == 'png') mime = 'image/png';
          else if (ext == 'gif') mime = 'image/gif';
          else if (ext == 'webp') mime = 'image/webp';
          else mime = 'application/octet-stream';

          final b64 = base64Encode(bytes);
          img.attributes['src'] = 'data:$mime;base64,$b64';
        } catch (_) {
          // If reading the image fails, leave the src as-is so renderer can attempt fallback.
          continue;
        }
      }

      return document.body?.innerHtml ?? document.outerHtml;
    } catch (_) {
      // If parsing fails for any reason, fall back to raw HTML
      return getChapterHtml(index);
    }
  }

  String? getChapterHref(int index) {
    if (_spineIds == null || index < 0 || index >= _spineIds!.length)
      return null;
    final id = _spineIds![index];
    return _manifestIdToHref?[id];
  }

  Uint8List getImage(String hrefFromHtml, String currentChapterPath) {
    final fullPath = _resolvePath(currentChapterPath, hrefFromHtml);
    return loader.getFile(fullPath);
  }

  Map<String, String> getMetadata() => _metadata ?? {};
  List<TocNode> get toc => _toc ?? [];
  int get chapterCount => _spineIds?.length ?? 0;
}
