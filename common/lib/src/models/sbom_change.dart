/// A single package-level difference between two SBOMs.
enum SbomChangeKind { added, removed, changed }

/// One entry in an SBOM diff: a package that was added, removed, or had its
/// version change between two CycloneDX component sets.
class SbomChange {
  final String name;

  /// Version on the "before" side; null for an `added` package.
  final String? from;

  /// Version on the "after" side; null for a `removed` package.
  final String? to;

  final SbomChangeKind kind;

  const SbomChange({
    required this.name,
    required this.from,
    required this.to,
    required this.kind,
  });

  factory SbomChange.fromJson(Map<String, dynamic> j) => SbomChange(
    name: j['name'] as String,
    from: j['from'] as String?,
    to: j['to'] as String?,
    kind: SbomChangeKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => SbomChangeKind.changed,
    ),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    'kind': kind.name,
  };
}
