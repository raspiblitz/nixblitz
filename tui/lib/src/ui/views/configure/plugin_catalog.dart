/// Curated list of plugins from `nixblitz_official_plugins` that
/// the Configure → Plugins screen offers as one-tap installs. The
/// wizard-managed core (bitcoind / lnd / cln) is intentionally
/// absent — those land via the install wizard and shouldn't be
/// reinstalled through this screen.
///
/// Adding a new official plugin: drop a row here. Description is
/// what an operator sees before they press Enter; keep it to one
/// sentence in the same shape as the existing rows.
class OfficialPlugin {
  const OfficialPlugin({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
  });

  /// Matches the directory name under `nixblitz_official_plugins/`
  /// AND the plugin's on-disk dir name after install — used to
  /// filter "already installed" against `installedPluginsProvider`.
  final String id;

  /// Display name shown to the operator. Matches the plugin's
  /// `manifest.name` so the catalog row reads the same as the
  /// post-install Configure sidebar entry.
  final String name;

  /// One-sentence summary. Pulled verbatim from each plugin's
  /// `manifest.description` so the wording stays in sync with the
  /// consent prompt the operator sees during install.
  final String description;

  /// `nixblitz plugin add <url>` URL. forgejo: scheme so the
  /// operator's flake doesn't need to host or proxy these.
  final String url;
}

const List<OfficialPlugin> officialPluginCatalog = [
  OfficialPlugin(
    id: 'tailscale',
    name: 'Tailscale',
    description:
        'Enable Tailscale on this NixBlitz node. Optionally '
        'auto-join a tailnet via a reusable auth key, and advertise '
        'the node as an exit-node.',
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/tailscale',
  ),
  OfficialPlugin(
    id: 'netbird',
    name: 'NetBird',
    description:
        'Enable NetBird on this NixBlitz node. Join a NetBird '
        'network on demand via a setup key; optionally point at a '
        'self-hosted management server.',
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/netbird',
  ),
  OfficialPlugin(
    id: 'lnbits',
    name: 'LNBits',
    description:
        'Run LNBits — a Lightning wallet & accounts system — on '
        "this node. Optionally auto-wires the admin macaroon from "
        "the node's LND (or the regtest test-lnd instance).",
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnbits',
  ),
  OfficialPlugin(
    id: 'electrs',
    name: 'Electrs',
    description:
        "Run electrs (the Rust Electrum server) backed by this "
        "node's Bitcoin Core. Initial mainnet sync takes 6–18h and "
        '~45GB of disk; bitcoind must be unpruned.',
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/electrs',
  ),
  OfficialPlugin(
    id: 'blitz-api',
    name: 'Blitz API',
    description: 'FastAPI backend for the Blitz web frontend.',
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/blitz-api',
  ),
  OfficialPlugin(
    id: 'blitz-web',
    name: 'Blitz Web',
    description:
        'Mobile-first web frontend for the node (raspiblitz-web). '
        'Requires Blitz API.',
    url: 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/blitz-web',
  ),
];
