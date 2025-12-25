class Chapter {
  final String title;
  final String path;
  final int level;

  Chapter({required this.title, required this.path, this.level = 0});
}

class ParsedPackage {
  final List<Chapter> chapters;
  ParsedPackage({required this.chapters});
}
