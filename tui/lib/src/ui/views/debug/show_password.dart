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
        return false;
      },
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
              Text(
                'Password: $_password',
                style: const TextStyle(color: Color.fromRGB(220, 220, 220)),
              )
            else if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: Color.fromRGB(255, 120, 120)),
              )
            else
              const Text('Loading…'),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
