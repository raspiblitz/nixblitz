import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

/// A reusable password input with optional confirmation.
///
/// Shows masked input (****), validates minimum length,
/// and optionally requires typing the password twice.
///
/// Usage:
/// ```dart
/// PasswordInput(
///   title: 'Set admin password',
///   subtitle: 'This password is used for SSH access.',
///   minLength: 8,
///   requireConfirmation: true,
///   onSubmit: (password) { ... },
///   onCancel: () { ... },
/// )
/// ```
class PasswordInput extends StatefulComponent {
  final String title;
  final String? subtitle;
  final int minLength;
  final bool requireConfirmation;
  final void Function(String password) onSubmit;
  final VoidCallback? onCancel;

  const PasswordInput({
    super.key,
    required this.title,
    this.subtitle,
    this.minLength = 8,
    this.requireConfirmation = true,
    required this.onSubmit,
    this.onCancel,
  });

  @override
  State<PasswordInput> createState() => _PasswordInputState();
}

class _PasswordInputState extends State<PasswordInput> {
  String _password = '';
  String _confirm = '';
  bool _confirming = false;
  bool _mismatch = false;
  bool _showPassword = false;

  @override
  Component build(BuildContext context) {
    final comp = component;
    final title = comp.title;
    final subtitle = comp.subtitle;
    final minLength = comp.minLength;
    final requireConfirmation = comp.requireConfirmation;

    final displayPassword = _showPassword ? _password : '*' * _password.length;
    final displayConfirm = _showPassword ? _confirm : '*' * _confirm.length;

    String hint;
    Color hintColor;

    if (_mismatch) {
      hint = 'Passwords do not match. Try again.';
      hintColor = const Color.fromRGB(255, 80, 80);
    } else if (_confirming) {
      hint = 'Type the password again to confirm. Esc to re-enter.';
      hintColor = const Color.fromRGB(150, 150, 180);
    } else if (_password.length < minLength) {
      hint = 'Minimum $minLength characters';
      hintColor = const Color.fromRGB(255, 80, 80);
    } else if (requireConfirmation) {
      hint = 'Press Enter to confirm password';
      hintColor = const Color.fromRGB(110, 220, 110);
    } else {
      hint = 'Press Enter to submit';
      hintColor = const Color.fromRGB(110, 220, 110);
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          // Tab to peek password
          if (event.logicalKey == LogicalKey.tab) {
            setState(() => _showPassword = !_showPassword);
            return true;
          }

          if (event.logicalKey == LogicalKey.enter) {
            if (!_confirming) {
              if (_password.length >= minLength) {
                if (requireConfirmation) {
                  setState(() {
                    _confirming = true;
                    _mismatch = false;
                  });
                } else {
                  comp.onSubmit(_password);
                }
              }
            } else {
              if (_confirm == _password) {
                comp.onSubmit(_password);
              } else {
                setState(() {
                  _mismatch = true;
                  _confirming = false;
                  _password = '';
                  _confirm = '';
                });
              }
            }
            return true;
          }

          if (event.logicalKey == LogicalKey.escape) {
            if (_confirming) {
              setState(() {
                _confirming = false;
                _confirm = '';
              });
            } else {
              comp.onCancel?.call();
            }
            return true;
          }

          if (event.logicalKey == LogicalKey.backspace) {
            setState(() {
              if (_confirming) {
                if (_confirm.isNotEmpty) {
                  _confirm = _confirm.substring(0, _confirm.length - 1);
                }
              } else {
                if (_password.isNotEmpty) {
                  _password = _password.substring(0, _password.length - 1);
                }
                _mismatch = false;
              }
            });
            return true;
          }

          final char = event.character;
          if (char != null && char.isNotEmpty) {
            setState(() {
              if (_confirming) {
                _confirm += char;
              } else {
                _password += char;
                _mismatch = false;
              }
            });
            return true;
          }

          return false;
        } catch (e, st) {
          LogService.error('Password input key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 1),
              Text(subtitle, style: const TextStyle(color: Color.fromRGB(200, 200, 200))),
            ],
            const SizedBox(height: 1),
            Text('Password: $displayPassword'),
            if (_confirming)
              Text('Confirm:  $displayConfirm'),
            const SizedBox(height: 1),
            Text(hint, style: TextStyle(color: hintColor)),
            const SizedBox(height: 1),
            Text(
              _showPassword ? '[Tab]: Hide password' : '[Tab]: Show password',
              style: const TextStyle(color: Color.fromRGB(100, 100, 120)),
            ),
          ],
        ),
      ),
    );
  }
}
