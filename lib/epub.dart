// epub.dart
import 'dart:typed_data';
import 'dart:convert';
import 'package:xml/xml.dart';
import 'loader.dart';

class TocNode {
  final String title;
  final String? href;
  final List<TocNode> children;

  TocNode({
    required this.title,
    this.href,
    List<TocNode>? children,
  }) : children = children ?? const [];

  TocNode copyWith({String? title, String? href, List<TocNode>? children}) {
    return TocNode(
      title: title ?? this.title,
      href: href ?? this.href,
      children: children ?? this.children,
    );
  }
}

class EpubReader {
  final Loader loader;

  String? _opfPath;

  // Lightweight caches
  Map<String, String>? _metadata;
  List<String>? _spineIds;

  // Manifest caches
  Map<String, String>? _manifestIdToHref; // id -> href
  Map<String, String>? _manifestHrefToMediaType; // href -> media-type

  // Hierarchical TOC
  List<TocNode>? _tocTree;

  EpubReader(this.loader);

  /// Initialize by loading container.xml and parsing OPF
  void init() {
    final containerBytes = loader.getFile('META-INF/container.xml');
    final containerXml = _parseXml(containerBytes, "container.xml");

    final rootfile = containerXml
        .findAllElements('rootfile')
        .map((e) => e.getAttribute('full-path'))
        .whereType<String>()
        .firstWhere(
          (p) => p.isNotEmpty,
          orElse: () => throw Exception("OPF file not found in container.xml"),
        );

    _opfPath = rootfile;

    final opfBytes = loader.getFile(_opfPath!);
    final opfDoc = _parseXml(opfBytes, _opfPath!);

    // Extract and cache lightweight structures
    _metadata = _extractMetadata(opfDoc);
    _spineIds = _extractSpine(opfDoc);

    // Build manifest caches
    final manifestCaches = _buildManifestCaches(opfDoc);
    _manifestIdToHref = manifestCaches.$1;
    _manifestHrefToMediaType = manifestCaches.$2;

    // Build hierarchical TOC
    _tocTree = _extractTocTree(opfDoc);
  }

  // --- XML helpers ---

  XmlDocument _parseXml(Uint8List bytes, String context) {
    // Assuming UTF-8 for now; encoding detection omitted per request
    final text = utf8.decode(bytes);
    try {
      return XmlDocument.parse(text);
    } catch (e) {
      throw Exception("Failed to parse XML ($context): $e");
    }
  }

  XmlElement? _firstElement(XmlDocument doc, String name,
      {String? namespace}) {
    final it = namespace == null
        ? doc.findAllElements(name)
        : doc.findAllElements(name, namespace: namespace);
    return it.isNotEmpty ? it.first : null;
  }

  Iterable<XmlElement> _elements(XmlElement parent, String name,
      {String? namespace}) {
    return namespace == null
        ? parent.findElements(name)
        : parent.findElements(name, namespace: namespace);
  }

  // --- Metadata ---

  Map<String, String> _extractMetadata(XmlDocument doc) {
    final metadata = <String, String>{};
    final metaElement = _firstElement(doc, 'metadata');
    if (metaElement == null) return metadata;

    String _getText(String name, {String? namespace}) {
      final elems = _elements(metaElement, name, namespace: namespace);
      final texts = elems.map((e) => e.text.trim()).where((t) => t.isNotEmpty);
      return texts.join(',');
    }

    metadata['title'] = _getText('title', namespace: 'dc');
    metadata['author'] = _getText('creator', namespace: 'dc');
    metadata['language'] = _getText('language', namespace: 'dc');
    metadata['publisher'] = _getText('publisher', namespace: 'dc');
    metadata['identifier'] = _getText('identifier', namespace: 'dc');

    return metadata;
  }

  // --- Spine ---

  List<String> _extractSpine(XmlDocument doc) {
    final spine = _firstElement(doc, 'spine');
    if (spine == null) return const [];
    return spine
        .findElements('itemref')
        .map((e) => e.getAttribute('idref'))
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();
  }

  // --- Manifest caches ---

  (Map<String, String>, Map<String, String>) _buildManifestCaches(
      XmlDocument doc) {
    final idToHref = <String, String>{};
    final hrefToMedia = <String, String>{};

    final manifest = _firstElement(doc, 'manifest');
    if (manifest == null) return (idToHref, hrefToMedia);

    for (final item in manifest.findElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final mediaType = item.getAttribute('media-type') ?? '';
      if (id != null && href != null) {
        idToHref[id] = href;
        hrefToMedia[href] = mediaType;
      }
    }
    return (idToHref, hrefToMedia);
  }

  // --- TOC (hierarchical) ---

  List<TocNode> _extractTocTree(XmlDocument opfDoc) {
    // Try EPUB 3 nav
    final navItem = opfDoc
        .findAllElements('item')
        .firstWhere(
          (e) => (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
          orElse: () => XmlElement(XmlName('')),
        );

    if (navItem.name.local.isNotEmpty) {
      final href = navItem.getAttribute('href');
      if (href != null && _opfPath != null) {
        final basePath = _opfBasePath(_opfPath!);
        final navPath = basePath + href;
        final navBytes = loader.getFile(navPath);
        final navDoc = _parseXml(navBytes, navPath);
        final navElement = navDoc
            .findAllElements('nav')
            .firstWhere(
              (e) => e.getAttribute('epub:type') == 'toc',
              orElse: () => navDoc.findAllElements('nav').isNotEmpty
                  ? navDoc.findAllElements('nav').first
                  : XmlElement(XmlName('')),
            );
        if (navElement.name.local.isNotEmpty) {
          final ol = navElement.findElements('ol').isNotEmpty
              ? navElement.findElements('ol').first
              : null;
          if (ol != null) {
            return _parseNavOl(ol, _opfBasePath(_opfPath!));
          }
        }
      }
    }

    // Fallback: EPUB 2 NCX
    final ncxItem = opfDoc
        .findAllElements('item')
        .firstWhere(
          (e) => e.getAttribute('media-type') == 'application/x-dtbncx+xml',
          orElse: () => XmlElement(XmlName('')),
        );

    if (ncxItem.name.local.isNotEmpty) {
      final href = ncxItem.getAttribute('href');
      if (href != null && _opfPath != null) {
        final basePath = _opfBasePath(_opfPath!);
        final ncxPath = basePath + href;
        final ncxBytes = loader.getFile(ncxPath);
        final ncxDoc = _parseXml(ncxBytes, ncxPath);
        final navMap = ncxDoc.findAllElements('navMap').isNotEmpty
            ? ncxDoc.findAllElements('navMap').first
            : null;
        if (navMap != null) {
          return _parseNcxNavMap(navMap, basePath);
        }
      }
    }

    // Final fallback: build TOC from spine (flat)
    final spineIds = _spineIds ?? const [];
    final nodes = <TocNode>[];
    for (final id in spineIds) {
      final href = _manifestIdToHref?[id];
      nodes.add(TocNode(title: href ?? id, href: href));
    }
    return nodes;
  }

  List<TocNode> _parseNavOl(XmlElement ol, String basePath) {
    final nodes = <TocNode>[];
    for (final li in ol.findElements('li')) {
      final a = li.findElements('a').isNotEmpty ? li.findElements('a').first : null;
      final title = a?.text.trim() ?? '';
      final href = a?.getAttribute('href');
      final resolvedHref = href != null ? _resolveHref(basePath, href) : null;

      // Children
      final childOl = li.findElements('ol').isNotEmpty ? li.findElements('ol').first : null;
      final children = childOl != null ? _parseNavOl(childOl, basePath) : <TocNode>[];

      nodes.add(TocNode(title: title.isNotEmpty ? title : (resolvedHref ?? ''), href: resolvedHref, children: children));
    }
    return nodes;
  }

  List<TocNode> _parseNcxNavMap(XmlElement navMap, String basePath) {
    List<TocNode> parseNavPoint(XmlElement np) {
      final label = np.findAllElements('navLabel').isNotEmpty
          ? np.findAllElements('navLabel').first
          : null;
      final text = label?.findAllElements('text').isNotEmpty == true
          ? label!.findAllElements('text').first.text.trim()
          : '';
      final content = np.findAllElements('content').isNotEmpty
          ? np.findAllElements('content').first
          : null;
      final src = content?.getAttribute('src');
      final resolvedHref = src != null ? _resolveHref(basePath, src) : null;

      final children = <TocNode>[];
      for (final child in np.findElements('navPoint')) {
        children.addAll(parseNavPoint(child));
      }

      return [
        TocNode(
          title: text.isNotEmpty ? text : (resolvedHref ?? ''),
          href: resolvedHref,
          children: children,
        )
      ];
    }

    final nodes = <TocNode>[];
    for (final np in navMap.findElements('navPoint')) {
      nodes.addAll(parseNavPoint(np));
    }
    return nodes;
  }

  String _opfBasePath(String opfPath) {
    final idx = opfPath.lastIndexOf('/');
    return idx >= 0 ? opfPath.substring(0, idx + 1) : '';
  }

  String _resolveHref(String basePath, String href) {
    // Handle fragment-only or relative paths
    if (href.startsWith('#')) return basePath + href;
    return basePath + href;
  }

  // --- Public getters (lightweight structures only) ---

  Map<String, String> getMetadata() => _metadata ?? {};
  List<String> getSpineIds() => _spineIds ?? [];
  List<TocNode> getTocTree() => _tocTree ?? const [];

  /// Return chapter HTML as string (uses manifest cache, no OPF reparse)
  String getChapterHtml(int index) {
    final spine = _spineIds;
    if (spine == null) throw Exception("EPUB not initialized");
    if (index < 0 || index >= spine.length) {
      throw Exception("Chapter index out of range");
    }

    final id = spine[index];
    final href = _manifestIdToHref?[id];
    if (href == null) {
      throw Exception("Manifest href not found for id: $id");
    }

    final chapterPath = _opfBasePath(_opfPath!) + href;
    final chapterBytes = loader.getFile(chapterPath);
    return utf8.decode(chapterBytes);
  }

  /// Return image bytes by manifest id (uses manifest cache)
  Uint8List getImage(String id) {
    final href = _manifestIdToHref?[id];
    if (href == null) {
      throw Exception("Manifest href not found for id: $id");
    }
    final imagePath = _opfBasePath(_opfPath!) + href;
    return loader.getFile(imagePath);
  }
}
