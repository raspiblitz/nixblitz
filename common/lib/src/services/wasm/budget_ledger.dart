import 'dart:convert';
import 'dart:io';

/// Raised when the ledger cannot be persisted. Callers MUST treat this
/// as a spend refusal (fail-closed) — never let a spend proceed whose
/// accounting could not be written.
class BudgetLedgerException implements Exception {
  BudgetLedgerException(this.message);
  final String message;
  @override
  String toString() => 'BudgetLedgerException: $message';
}

class _Entry {
  _Entry(this.id, this.ts, this.method, this.sats, this.settled);
  final String id;
  final DateTime ts;
  final String method;
  int sats;
  bool settled;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toIso8601String(),
    'method': method,
    'sats': sats,
    'settled': settled,
  };

  factory _Entry.fromJson(Map<String, dynamic> j) => _Entry(
    j['id'] as String,
    DateTime.parse(j['ts'] as String),
    j['method'] as String,
    j['sats'] as int,
    j['settled'] as bool? ?? true,
  );
}

/// Per-plugin spend ledger with a trailing-24h window and
/// reserve-then-settle accounting. Synchronous, atomic JSON persistence
/// (matches the codebase's sync-IO discipline). One instance ≈ one
/// plugin id; construct fresh per invocation (it reloads from disk).
///
/// NOT safe for concurrent instances on the same [path] — each instance
/// loads the full entry list once at construction and `_persist()`
/// overwrites the whole file on every mutation, so a second concurrent
/// writer's in-memory view doesn't see the first's reservation and its
/// next write clobbers it (fail-open: the dropped reservation's sats
/// vanish from the tracked total). v1 is safe because the TUI only ever
/// runs one plugin action at a time; real file locking (e.g. an flock on
/// [path]) is required before any concurrent action runner is
/// introduced.
class BudgetLedger {
  BudgetLedger(this.path) {
    _load();
  }

  final String path;
  final List<_Entry> _entries = [];
  var _counter = 0;

  void _load() {
    final f = File(path);
    if (!f.existsSync()) return;
    try {
      final data = jsonDecode(f.readAsStringSync()) as List;
      for (final e in data) {
        _entries.add(_Entry.fromJson(e as Map<String, dynamic>));
      }
    } catch (_) {
      // A corrupt ledger is treated as empty; the atomic writer below
      // replaces it on the next reserve. (Fail-closed still holds: a
      // missing history can only reduce apparent spend for THIS process,
      // and the file is rewritten cleanly.)
    }
  }

  void _persist() {
    try {
      final tmp = File('$path.tmp');
      tmp.parent.createSync(recursive: true);
      tmp.writeAsStringSync(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
      tmp.renameSync(path);
    } catch (e) {
      throw BudgetLedgerException('could not persist $path: $e');
    }
  }

  /// Sum of sats in the trailing 24h window ending at [now].
  int spentWithin(DateTime now) {
    final cutoff = now.subtract(const Duration(hours: 24));
    return _entries
        .where((e) => e.ts.isAfter(cutoff))
        .fold(0, (sum, e) => sum + e.sats);
  }

  /// Records an intended spend and persists it BEFORE the caller
  /// executes the RPC. Returns the reservation id for [settle]/[cancel].
  String reserve(DateTime now, String method, int sats) {
    final id = '${now.microsecondsSinceEpoch}-${_counter++}';
    _entries.add(_Entry(id, now, method, sats, false));
    _persist();
    return id;
  }

  /// Adjusts a reservation to the actual spent amount and persists.
  void settle(String reservationId, int actualSats) {
    final e = _entries.firstWhere((e) => e.id == reservationId);
    e.sats = actualSats;
    e.settled = true;
    _persist();
  }

  /// Removes a reservation (RPC refused/failed before spending).
  void cancel(String reservationId) {
    _entries.removeWhere((e) => e.id == reservationId);
    _persist();
  }
}
