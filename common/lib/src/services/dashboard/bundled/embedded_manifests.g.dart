// GENERATED — do not edit. Run 'just gen-manifests' to regenerate.
// Source: common/lib/src/services/dashboard/bundled/manifests/

part of 'embedded_manifests.dart';

const String _bitcoinJson = r'''
{
  "id": "bitcoin",
  "title": "Bitcoin",
  "accent_color": "#f7931a",
  "layout": [
    {
      "StatusRow": {
        "label": "Network",
        "value": { "$data": "chain_name" },
        "color": { "$data": "chain_color" }
      }
    },
    {
      "ProgressBar": {
        "label": "Sync",
        "value": { "$data": "verification_progress" },
        "format": "percent"
      }
    },
    {
      "Row": { "label": "Blocks", "value": { "$format": "{blocks}/{headers}" } }
    },
    { "Row": { "label": "Peers", "value": { "$data": "peers" } } },
    { "Row": { "label": "Disk", "value": { "$bytes": "size_on_disk" } } },
    {
      "Row": { "label": "Mempool", "value": { "$format": "{mempool_txs} txs" } }
    }
  ],
  "footer": {
    "$status": {
      "$on": "sync_state",
      "synced": { "Footer": { "text": "synced", "color": "ok" } },
      "syncing": { "Footer": { "text": "syncing", "color": "warn" } },
      "stalled": { "Footer": { "text": "stalled", "color": "error" } }
    }
  }
}
''';

const String _hardwareJson = r'''
{
  "id": "hardware",
  "title": "Hardware",
  "accent_color": "#4caf50",
  "layout": [
    {
      "ProgressBar": {
        "label": "CPU",
        "value": { "$data": "cpu_percent" },
        "max": 100,
        "format": "percent"
      }
    },
    {
      "ProgressBar": {
        "label": "Mem",
        "value": { "$data": "mem_used_bytes" },
        "max": 1,
        "format": "bytes"
      }
    },
    {
      "ProgressBar": {
        "label": "Disk",
        "value": { "$data": "disk_used_bytes" },
        "max": 1,
        "format": "bytes"
      }
    },
    { "Row": { "label": "Temp", "value": { "$format": "{temperature_c}°C" } } }
  ]
}
''';

const String _lightningJson = r'''
{
  "id": "lightning",
  "title": "Lightning",
  "accent_color": "#9b6cf2",
  "layout": [
    { "Row": { "label": "Alias", "value": { "$data": "alias" } } },
    {
      "Row": {
        "label": "Pubkey",
        "value": { "$truncate": { "key": "pubkey", "len": 12 } }
      }
    },
    {
      "StatusRow": {
        "label": "Synced",
        "value": { "$data": "synced_label" },
        "color": { "$data": "synced_color" }
      }
    },
    {
      "Row": {
        "label": "Channels",
        "value": { "$format": "{active}/{pending}" }
      }
    },
    { "Row": { "label": "Peers", "value": { "$data": "peers" } } },
    {
      "Row": {
        "label": "On-chain",
        "value": { "$format": "{onchain_sats} sat" }
      }
    },
    {
      "Row": {
        "label": "In-channel",
        "value": { "$format": "{channel_sats} sat" }
      }
    }
  ]
}
''';

const String _systemJson = r'''
{
  "id": "system",
  "title": "System",
  "accent_color": "#607d8b",
  "streamer_args": ["--units", "blitz-api,blitz-web,nginx,redis"],
  "layout": [
    { "Row": { "label": "Uptime", "value": { "$duration": "uptime_sec" } } },
    {
      "Section": {
        "title": "Services",
        "children": [
          {
            "StatusRow": {
              "label": "blitz-api",
              "value": { "$data": "services.blitz-api" },
              "color": {
                "$status": {
                  "$on": "services.blitz-api",
                  "active": "ok",
                  "inactive": "muted",
                  "failed": "error"
                }
              }
            }
          },
          {
            "StatusRow": {
              "label": "blitz-web",
              "value": { "$data": "services.blitz-web" },
              "color": {
                "$status": {
                  "$on": "services.blitz-web",
                  "active": "ok",
                  "inactive": "muted",
                  "failed": "error"
                }
              }
            }
          },
          {
            "StatusRow": {
              "label": "nginx",
              "value": { "$data": "services.nginx" },
              "color": {
                "$status": {
                  "$on": "services.nginx",
                  "active": "ok",
                  "inactive": "muted",
                  "failed": "error"
                }
              }
            }
          },
          {
            "StatusRow": {
              "label": "redis",
              "value": { "$data": "services.redis" },
              "color": {
                "$status": {
                  "$on": "services.redis",
                  "active": "ok",
                  "inactive": "muted",
                  "failed": "error"
                }
              }
            }
          }
        ]
      }
    }
  ]
}
''';

const Map<String, String> _allManifests = {
  'bitcoin': _bitcoinJson,
  'hardware': _hardwareJson,
  'lightning': _lightningJson,
  'system': _systemJson,
};
