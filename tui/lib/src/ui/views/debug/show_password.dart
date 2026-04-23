import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

class ShowPasswordView extends StatefulComponent {
  final VoidCallback onExit;
  const ShowPasswordView({super.key, required this.onExit});

  @override
  State<ShowPasswordView> createState() => _ShowPasswordViewState();
}

class _ShowPasswordViewState extends State<ShowPasswordView> {
  String? _password;
  String? _error;
  bool _started = false;
  bool _copied = false;

  /// Write an OSC 52 escape sequence that most modern terminals
  /// interpret as "put this on the system clipboard". Works over SSH
  /// if the outer terminal supports it (xterm, alacritty, kitty,
  /// iTerm2, gnome-terminal with opt-in). No clipboard tool needed on
  /// the VM itself.
  void _copyToClipboard(String text) {
    try {
      final b64 = base64.encode(utf8.encode(text));
      stdout.write('\x1b]52;c;$b64\x07');
      setState(() => _copied = true);
    } catch (e, st) {
      LogService.error('OSC 52 clipboard write failed', e, st);
    }
  }

  void _load() {
    if (_started) return;
    _started = true;
    try {
      final r = Process.runSync('sudo', [
        '-n',
        'cat',
        '/var/lib/blitz_api/.login-password',
      ]);
      if (r.exitCode != 0) {
        setState(() {
          _error =
              'Could not read password file (exit ${r.exitCode}). '
              'Is blitz-api enabled and have you run Apply since?';
        });
      } else {
        setState(() {
          _password = (r.stdout as String).trim();
        });
      }
    } catch (e, st) {
      LogService.error('Read password failed', e, st);
      setState(() {
        _error = '$e';
      });
    }
  }

  @override
  Component build(BuildContext context) {
    if (!_started) Future.microtask(_load);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          component.onExit();
          return true;
        }
        if (event.logicalKey == LogicalKey.keyC && _password != null) {
          _copyToClipboard(_password!);
          return true;
        }
        return false;
      },
      child: SelectionArea(
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Blitz-API login password',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              const Text(
                'Username: admin',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const SizedBox(height: 1),
              if (_password != null)
                // Password alone on its own line, no prefix, so
                // triple-click / shift-drag in the terminal grabs
                // exactly the password string.
                Text(
                  _password!,
                  style: const TextStyle(
                    color: Color.fromRGB(220, 220, 220),
                    fontWeight: FontWeight.bold,
                  ),
                )
              else if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(color: Color.fromRGB(255, 120, 120)),
                )
              else
                const Text('Loading…'),
              const SizedBox(height: 1),
              if (_copied)
                const Text(
                  'Copied to clipboard (OSC 52).',
                  style: TextStyle(color: Color.fromRGB(110, 220, 110)),
                ),
              const SizedBox(height: 1),
              const Text(
                '[c] Copy to clipboard   [Esc] back',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const Text(
                'Tip: use [c]. OSC 52 travels over SSH and works on '
                'most modern terminals (xterm, alacritty, kitty, '
                'iTerm2, WezTerm). Mouse selection is unreliable '
                'through the TUI; don\'t bother with it.',
                style: TextStyle(color: Color.fromRGB(120, 120, 140)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
