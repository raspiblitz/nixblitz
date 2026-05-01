import 'package:jaspr_content/jaspr_content.dart';

List<RouteLoader> getLoadersWeb() {
  return [
    MemoryLoader(
      pages: [
        MemoryPage(path: 'docs/installation.md', content: ''),
        MemoryPage(path: 'docs/architecture.md', content: ''),
        MemoryPage(path: 'docs/plugins.md', content: ''),
      ],
    ),
  ];
}
