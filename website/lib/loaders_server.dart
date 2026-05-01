import 'package:jaspr_content/jaspr_content.dart';

List<RouteLoader> getLoadersServer() {
  return [FilesystemLoader('content')];
}
