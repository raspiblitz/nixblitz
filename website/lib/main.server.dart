// Deliberately zero client-side Dart: the site is fully static and
// every interaction (keyboard nav, lightbox, service-worker cleanup)
// is hand-rolled inline JS injected below. There is NO main.client.dart
// on purpose — do not "fix" jaspr's missing-client-script warning by
// adding one; compiled-dart hydration would ship hundreds of KB of JS
// for functionality these few inline snippets already provide.
import 'package:jaspr/server.dart';
import 'package:jaspr/dom.dart';
import 'app.dart';
import 'build_info.dart';

void main() {
  Jaspr.initializeApp();
  runApp(
    Document(
      title: 'NixBlitz — Bitcoin/Lightning node on NixOS',
      // Every head link below uses an ABSOLUTE path via href() so it
      // resolves identically at any route depth. A relative `styles.css`
      // does NOT work here: on a nested docs route (`/docs/installation`)
      // the browser resolves it against `/docs/`, and the `<base href="/">`
      // that would fix it — injected by jaspr_content's docs layout — is
      // appended to the END of <head>, after this link, so per the HTML
      // spec it can't affect it. Absolute paths ignore <base> entirely.
      // `<base href>` is kept only as a fallback for any relative URL
      // elsewhere in the page; omitted when kBasePath is empty so the
      // canonical root build doesn't render a noisy `<base href="/">`.
      base: kBasePath.isEmpty ? null : '$kBasePath/',
      head: [
        link(rel: 'icon', type: 'image/svg+xml', href: href('/favicon.svg')),
        link(rel: 'stylesheet', href: href('/styles.css')),
        link(
          rel: 'stylesheet',
          href: href('/vendor/asciinema-player/asciinema-player.css'),
        ),
        // Synchronous load — the per-cast init walker below runs on
        // DOMContentLoaded and needs `AsciinemaPlayer` to already
        // exist in the global scope by then.
        script(src: href('/vendor/asciinema-player/asciinema-player.min.js')),
        // Unregister stale ServiceWorkers from earlier PWA experiments to
        // avoid origin pollution on the dev server (localhost:8383, or
        // whatever port jaspr serve is bound to).
        RawText('''
        <script>
        // Base path threaded from the build-time --dart-define=BASE_PATH.
        // Inline JS routes need this because <base href> only affects
        // relative-URL resolution by the browser; explicit JS string
        // literals like `window.location.href = '/'` ignore <base>.
        var __basePath = ${kBasePath.isEmpty ? "''" : "'$kBasePath'"};
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
        // Keyboard nav. The bracketed letters in the header
        // (`[h] Home`, `[d] Docs`, `[c] Changelog`, `[r] Repo`) are
        // visual-only out of the box; this handler turns them into
        // real shortcuts.
        //
        // Suppressed when the user is typing in an input / textarea
        // / contenteditable so it doesn't steal letters from forms,
        // and when a modifier key is held so it doesn't fight
        // browser shortcuts (Ctrl+R reload, Cmd+H hide, etc.).
        //
        // Browser extensions like Vimium / qutebrowser bind these
        // letters at a higher priority and will intercept before
        // this handler runs (Vimium's `r` reloads the page, etc.).
        // Operators who use those extensions can add this site to
        // their exclude list to get our shortcuts back.
        document.addEventListener('keydown', function(e) {
          if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
          var t = e.target;
          if (t instanceof HTMLElement && (
              t.tagName === 'INPUT' ||
              t.tagName === 'TEXTAREA' ||
              t.tagName === 'SELECT' ||
              t.isContentEditable)) {
            return;
          }
          // Don't fire while a lightbox is open — the operator may
          // hit `r` etc. while looking at a screenshot.
          if (document.querySelector('.lightbox:target')) return;
          var routes = {
            'h': __basePath + '/',
            'd': __basePath + '/docs/installation',
            'c': __basePath + '/changelog'
          };
          var path = routes[e.key];
          if (path) {
            e.preventDefault();
            window.location.href = path;
            return;
          }
          if (e.key === 'r') {
            // Some browsers block `window.open` from a key-event
            // context and fall back to same-tab navigation; the
            // programmatic anchor-click form is more reliable.
            // stopPropagation + stopImmediatePropagation also
            // shut down Firefox's type-ahead-find which would
            // otherwise match the visible "[r]: Repo" link text.
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();
            var a = document.createElement('a');
            a.href = 'https://github.com/raspiblitz/nixblitz';
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            document.body.appendChild(a);
            a.click();
            a.remove();
          }
        });
        // asciinema-player init. Each `<div data-asciinema-cast=...>`
        // emitted by the AsciinemaCast Jaspr component gets converted
        // into a player instance here. Centralising the init avoids
        // emitting one inline `<script>` per cast and keeps the
        // markup the component produces a single attribute-only div.
        document.addEventListener('DOMContentLoaded', function() {
          if (typeof AsciinemaPlayer === 'undefined') return;
          var nodes = document.querySelectorAll('[data-asciinema-cast]');
          nodes.forEach(function(el) {
            if (el.dataset.acInit) return;
            el.dataset.acInit = '1';
            var opts = {
              cols: parseInt(el.dataset.cols || '80', 10),
              rows: parseInt(el.dataset.rows || '24', 10),
              idleTimeLimit: parseFloat(el.dataset.idleTimeLimit || '2'),
              theme: 'asciinema',
              fit: 'width',
            };
            if (el.dataset.poster) opts.poster = el.dataset.poster;
            AsciinemaPlayer.create(el.dataset.asciinemaCast, el, opts);
          });
        });
        </script>
      '''),
      ],
      body: const App(),
    ),
  );
}
