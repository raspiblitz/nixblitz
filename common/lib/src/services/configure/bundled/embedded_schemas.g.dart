// GENERATED — do not edit. Run 'just gen-app-schemas' to regenerate.
// Source: common/lib/src/services/configure/bundled/manifests/

// ignore_for_file: constant_identifier_names

part of 'embedded_schemas.dart';

const String _bitcoindJson = r'''
{
  "id": "bitcoind",
  "label": "Bitcoin Core",
  "description": "Bitcoin reference client (full or pruned node)",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
    {
      "name": "network",
      "type": "enum",
      "label": "Network",
      "choices": ["mainnet", "regtest"],
      "default": "mainnet"
    },
    {
      "name": "pruned",
      "type": "bool",
      "label": "Prune mode",
      "default": false
    },
    {
      "name": "prune_size_gb",
      "type": "int",
      "label": "Prune size (GB)",
      "default": 0,
      "min": 0
    }
  ]
}
''';

const String _clnJson = r'''
{
  "id": "cln",
  "label": "Core Lightning",
  "description": "Core Lightning (CLN) backend",
  "capabilities": ["lightning_backend"],
  "service_unit": "clightning",
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false }
  ]
}
''';

const String _lndJson = r'''
{
  "id": "lnd",
  "label": "LND",
  "description": "Lightning Network Daemon (LND backend)",
  "capabilities": ["lightning_backend"],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
    {
      "name": "alias",
      "type": "string",
      "label": "Alias",
      "default": "",
      "placeholder": "my-node"
    }
  ]
}
''';

const Map<String, String> _allAppSchemas = {
  'bitcoind': _bitcoindJson,
  'cln': _clnJson,
  'lnd': _lndJson,
};
