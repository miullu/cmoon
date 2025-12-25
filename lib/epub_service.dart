import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'; // Required for debugPrint
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'models.dart';

class EpubService {
  /// Normalizes file paths for cross-platform and internal consistency
  static String normalizePath(String path) {
    return path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\/'), '');
  }

  /// Gets the directory part of a path
  static String getDirectory(String path) {
    final idx = path.lastIndexOf('/');
    return idx == -1 ? '' : path.substring(0, idx + 1);
  }

  /// Extracts Title, Author, and Cover Image from an EPUB archive
  static Map<String, dynamic> extractMetadata(Archive archive) {
    String? title;
    String? author;
    Uint8List? thumbnail;

    try {
      final containerFile = archive.findFile('META-INF/container.xml');
      if (containerFile == null) return {};

      final containerXml = XmlDocument.parse(
        utf8.decode(containerFile.content as List<int>),
      );
      final rootfile = containerXml.findAllElements('rootfile').firstOrNull;
      final opfPath = rootfile?.getAttribute('full-path');
      if (opfPath == null) return {};

      final opfFile = archive.findFile(normalizePath(opfPath));
      if (opfFile == null) return {};

      final opfXml = XmlDocument.parse(
        utf8.decode(opfFile.content as List<int>),
      );

      title = opfXml.findAllElements('dc:title').firstOrNull?.innerText;
      author = opfXml.findAllElements('dc:creator').firstOrNull?.innerText;

      // Find cover image ID from metadata
      final coverMeta = opfXml
          .findAllElements('meta')
          .firstWhere(
            (e) => e.getAttribute('name') == 'cover',
            orElse: () => XmlElement(XmlName('none')),
          );
      String? coverId = coverMeta.getAttribute('content');

      if (coverId != null) {
        final item = opfXml
            .findAllElements('item')
            .firstWhere(
              (e) => e.getAttribute('id') == coverId,
              orElse: () => XmlElement(XmlName('none')),
            );
        String? href = item.getAttribute('href');
        if (href != null) {
          final fullCoverPath = normalizePath(getDirectory(opfPath) + href);
          final coverFile = archive.findFile(fullCoverPath);
          if (coverFile != null) {
            thumbnail = coverFile.content as Uint8List;
          }
        }
      }
    } catch (e) {
      debugPrint("Metadata extraction failed: $e");
    }

    return {'title': title, 'author': author, 'thumbnail': thumbnail};
  }

  /// Parses the EPUB container and OPF to extract chapters for the reader
  static ParsedPackage? parsePackage(Map<String, ArchiveFile> fileMap) {
    try {
      final containerFile = fileMap['META-INF/container.xml'];
      if (containerFile == null) return null;

      final containerXml = XmlDocument.parse(
        utf8.decode(containerFile.content as List<int>),
      );
      final rootfile = containerXml.findAllElements('rootfile').firstOrNull;
      final opfPath = rootfile?.getAttribute('full-path');
      if (opfPath == null) return null;

      final opfFile = fileMap[normalizePath(opfPath)];
      if (opfFile == null) return null;

      final opfXml = XmlDocument.parse(
        utf8.decode(opfFile.content as List<int>),
      );
      final manifest = <String, String>{};
      String? ncxId;

      for (final item in opfXml.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        final mediaType = item.getAttribute('media-type');
        if (id != null && href != null) {
          manifest[id] = href;
          if (mediaType == 'application/x-dtbncx+xml') ncxId = id;
        }
      }

      final basePath = getDirectory(opfPath);
      final List<Chapter> chapters = [];

      // Try parsing NCX (Table of Contents)
      if (ncxId != null && manifest.containsKey(ncxId)) {
        final ncxPath = normalizePath(basePath + manifest[ncxId]!);
        final ncxFile = fileMap[ncxPath];
        if (ncxFile != null) {
          final ncxXml = XmlDocument.parse(
            utf8.decode(ncxFile.content as List<int>),
          );
          final navMap = ncxXml.findAllElements('navMap').firstOrNull;
          if (navMap != null) {
            void parseNavPoints(Iterable<XmlElement> points, int level) {
              for (final point in points) {
                final text = point
                    .findElements('navLabel')
                    .firstOrNull
                    ?.findElements('text')
                    .firstOrNull
                    ?.innerText;
                final src = point
                    .findElements('content')
                    .firstOrNull
                    ?.getAttribute('src');
                if (text != null && src != null) {
                  chapters.add(
                    Chapter(
                      title: text,
                      path: normalizePath(basePath + src),
                      level: level,
                    ),
                  );
                }
                final subPoints = point.findElements('navPoint');
                if (subPoints.isNotEmpty) {
                  parseNavPoints(subPoints, level + 1);
                }
              }
            }

            parseNavPoints(navMap.findElements('navPoint'), 0);
          }
        }
      }

      // Fallback to spine order if no NCX/TOC found
      if (chapters.isEmpty) {
        for (final itemref in opfXml.findAllElements('itemref')) {
          final idref = itemref.getAttribute('idref');
          final href = manifest[idref];
          if (href != null) {
            chapters.add(
              Chapter(
                title: href.split('/').last,
                path: normalizePath(basePath + href),
                level: 0,
              ),
            );
          }
        }
      }

      return ParsedPackage(chapters: chapters);
    } catch (e) {
      debugPrint("Package parsing failed: $e");
      return null;
    }
  }
}
