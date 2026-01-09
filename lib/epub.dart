import 'dart:typed_data';
import 'dart:convert';
import 'package:xml/xml.dart';
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

    // Parse Metadata
    _metadata = {};
    final metadataBase = opfXml.findElements('package').first.findElements('metadata').first;
    for (var node in metadataBase.children) {
      if (node is XmlElement) {
        _metadata![node.name.local] = node.innerText;
      }
    }

    // Parse Manifest (ID -> Href mapping)
    _manifestIdToHref = {};
    final manifestBase = opfXml.findElements('package').first.findElements('manifest').first;
    for (var item in manifestBase.findElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        _manifestIdToHref![id] = Uri.decodeFull(href);
      }
    }

    // Parse Spine (Linear reading order)
    _spineIds = [];
    final spineBase = opfXml.findElements('package').first.findElements('spine').first;
    for (var item in spineBase.findElements('itemref')) {
      final idref = item.getAttribute('idref');
      if (idref != null) _spineIds!.add(idref);
    }
  }

  /// Robustly resolves relative paths (e.g., handling ../../)
  String _resolvePath(String contextPath, String relativePath) {
    // Extract folder from contextPath (e.g., "OEBPS/content.opf" -> "OEBPS/")
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

  Uint8List getImage(String hrefFromHtml, String currentChapterPath) {
    final fullPath = _resolvePath(currentChapterPath, hrefFromHtml);
    return loader.getFile(fullPath);
  }

  Map<String, String> getMetadata() => _metadata ?? {};
  int get chapterCount => _spineIds?.length ?? 0;
}