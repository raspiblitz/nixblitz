import 'package:jaspr/server.dart';
import 'package:jaspr/dom.dart';
import 'app.dart';

void main() {
  Jaspr.initializeApp();
  runApp(
    Document(
      title: 'NixBlitz — Bitcoin/Lightning node on NixOS',
      head: [
        link(rel: 'stylesheet', href: 'styles.css'),
        // Unregister stale ServiceWorkers from earlier PWA experiments to
        // avoid origin pollution on localhost:8080.
        RawText('''
        <script>
        if ('serviceWorker' in navigator) {
          navigator.serviceWorker.getRegistrations().then(function(registrations) {
            for(let registration of registrations) {
              registration.unregister();
            }
          });
        }
        </script>
      '''),
      ],
      body: const App(),
    ),
  );
}
