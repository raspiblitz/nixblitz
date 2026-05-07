import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/signature_label.dart';

GitSignature _sig({
  required String status,
  String fingerprint = '',
  String signer = '',
  String primaryKeyFingerprint = '',
}) => GitSignature(
  status: status,
  fingerprint: fingerprint,
  signer: signer,
  primaryKeyFingerprint: primaryKeyFingerprint,
);

void main() {
  group('describeSignature', () {
    test('unsigned commit ("N") renders as (unsigned)', () {
      expect(describeSignature(_sig(status: 'N')), '(unsigned)');
    });

    test('verification-failed ("E") also renders as (unsigned)', () {
      // E covers "verification failed for some other reason" — git
      // can't tell us anything useful, treat it like unsigned for
      // display purposes.
      expect(describeSignature(_sig(status: 'E')), '(unsigned)');
    });

    test('good signature ("G") with signer identity', () {
      expect(
        describeSignature(
          _sig(
            status: 'G',
            fingerprint: 'SHA256:abc123',
            signer: 'alice@example.com',
          ),
        ),
        'signed by SHA256:abc123   (alice@example.com)',
      );
    });

    test('good signature without signer identity (typical SSH commit)', () {
      expect(
        describeSignature(_sig(status: 'G', fingerprint: 'SHA256:abc123')),
        'signed by SHA256:abc123',
      );
    });

    test('good signature with empty fingerprint falls back to placeholder', () {
      expect(
        describeSignature(_sig(status: 'G')),
        'signed by (no fingerprint)',
      );
    });

    test('unverified-key ("U") tagged for the operator', () {
      expect(
        describeSignature(_sig(status: 'U', fingerprint: 'SHA256:abc')),
        'signed by SHA256:abc [unverified key]',
      );
    });

    test('expired signature ("X") tagged', () {
      expect(
        describeSignature(_sig(status: 'X', fingerprint: 'SHA256:abc')),
        'signed by SHA256:abc [signature expired]',
      );
    });

    test('expired-key ("Y") tagged', () {
      expect(
        describeSignature(_sig(status: 'Y', fingerprint: 'SHA256:abc')),
        'signed by SHA256:abc [signing key expired]',
      );
    });

    test('revoked-key ("R") tagged', () {
      expect(
        describeSignature(_sig(status: 'R', fingerprint: 'SHA256:abc')),
        'signed by SHA256:abc [signing key revoked]',
      );
    });

    test('bad signature ("B") flagged loudly', () {
      expect(
        describeSignature(_sig(status: 'B', fingerprint: 'SHA256:abc')),
        'BAD signature (SHA256:abc)',
      );
    });

    test('unknown status falls through with diagnostic', () {
      expect(
        describeSignature(_sig(status: 'Z', fingerprint: 'SHA256:abc')),
        'signed (status=Z, fp=SHA256:abc)',
      );
    });
  });
}
