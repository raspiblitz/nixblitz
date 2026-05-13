import 'dart:io';

Map<String, String> getDocsStateServer() {
  try {
    return {
      'docs/installation.md': File(
        'content/docs/installation.md',
      ).readAsStringSync(),
      'docs/updates.md': File('content/docs/updates.md').readAsStringSync(),
      'docs/architecture.md': File(
        'content/docs/architecture.md',
      ).readAsStringSync(),
      'docs/plugins.md': File('content/docs/plugins.md').readAsStringSync(),
    };
  } catch (e) {
    print('Error syncing docs: $e');
    return {};
  }
}
