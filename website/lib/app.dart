import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr_router/jaspr_router.dart' hide RouteLoader;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_content/jaspr_content.dart';
import 'package:jaspr_content/theme.dart';

import 'pages/home_page.dart';
import 'pages/changelog_page.dart';
import 'components/layout.dart' as layout;
import 'components/sidebar.dart' as sidebar;

@Import.onWeb('loaders_web.dart', show: [#getLoadersWeb])
@Import.onServer('loaders_server.dart', show: [#getLoadersServer])
@Import.onWeb('app_sync_web.dart', show: [#getDocsStateWeb])
@Import.onServer('app_sync_server.dart', show: [#getDocsStateServer])
import 'app.imports.dart';

class App extends StatelessComponent {
  const App({super.key});

  @override
  Component build(BuildContext context) {
    return ProviderScope(child: _AppContent());
  }
}

class _AppContent extends StatefulComponent {
  @override
  State<_AppContent> createState() => _AppContentState();
}

class _AppContentState extends State<_AppContent>
    with SyncStateMixin<_AppContent, Map<String, String>> {
  Map<String, String> _syncedDocs = {};

  @override
  Map<String, String> getState() {
    if (kIsWeb) return getDocsStateWeb();
    return getDocsStateServer();
  }

  @override
  void updateState(Map<String, String> state) {
    _syncedDocs = state;
  }

  @override
  Component build(BuildContext context) {
    List<RouteLoader> loaders;
    if (kIsWeb) {
      loaders = [
        MemoryLoader(
          pages: _syncedDocs.entries
              .map((e) => MemoryPage(path: e.key, content: e.value))
              .toList(),
        ),
      ];
    } else {
      loaders = getLoadersServer();
    }

    return ContentApp.custom(
      loaders: loaders,
      configResolver: (PageSource source) => PageConfig(
        parsers: [const MarkdownParser()],
        layouts: [
          DocsLayout(
            header: div([]),
            footer: div([]),
            sidebar: const sidebar.Sidebar(),
          ),
        ],
        theme: const ContentTheme.none(),
      ),
      routerBuilder: (contentRoutes) {
        return Router(
          routes: [
            ShellRoute(
              builder: (context, state, child) {
                return div(classes: 'min-h-screen flex flex-col relative', [
                  const layout.NavBar(),
                  main_([child], classes: 'flex-1'),
                  const layout.Footer(),
                ]);
              },
              routes: [
                Route(path: '/', builder: (context, state) => const HomePage()),
                Route(
                  path: '/changelog',
                  builder: (context, state) => const ChangelogPage(),
                ),
                ...contentRoutes.expand((r) => r),
              ],
            ),
          ],
        );
      },
    );
  }
}
