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
        // Lightbox close handlers. The CSS uses `:target` for
        // open/close (see `.lightbox` in input.css). Opening the
        // lightbox is just a navigation to `#lb-<id>` which pushes
        // a history entry. Closing via `history.back()` undoes that
        // navigation — the browser restores the scroll position
        // automatically, the URL fragment clears, and `:target`
        // unmatches. Way simpler than manually mutating history.
        function closeLightbox(e) {
          if (!document.querySelector('.lightbox:target')) return false;
          if (e) e.preventDefault();
          history.back();
          return true;
        }
        document.addEventListener('click', function(e) {
          var target = e.target;
          if (!(target instanceof Element)) return;
          if (target.closest('.lightbox-close, .lightbox-backdrop')) {
            closeLightbox(e);
          }
        });
        document.addEventListener('keydown', function(e) {
          if (e.key === 'Escape') closeLightbox();
        });
        </script>
      '''),
      ],
      body: const App(),
    ),
  );
}
