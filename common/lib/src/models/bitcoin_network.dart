/// Bitcoin network choice. Used by the install wizard (network choice
/// menu), the dashboard chrome (network indicator), and Nix template
/// generation (regtest auto-enables test-lnd, mainnet/testnet/signet/regtest
/// each drive different bitcoind config defaults).
enum BitcoinNetwork {
  mainnet,
  testnet,
  regtest,
  signet;

  /// Wire-form name (snake_case) — what gets written to JSON and read by
  /// Nix `cfg.app_configs.bitcoind.network`.
  String get wireName => switch (this) {
    BitcoinNetwork.mainnet => 'mainnet',
    BitcoinNetwork.testnet => 'testnet',
    BitcoinNetwork.regtest => 'regtest',
    BitcoinNetwork.signet => 'signet',
  };

  /// Parse the wire-form name. Returns null on unknown input.
  static BitcoinNetwork? fromWireName(String s) => switch (s) {
    'mainnet' => BitcoinNetwork.mainnet,
    'testnet' => BitcoinNetwork.testnet,
    'regtest' => BitcoinNetwork.regtest,
    'signet' => BitcoinNetwork.signet,
    _ => null,
  };
}
