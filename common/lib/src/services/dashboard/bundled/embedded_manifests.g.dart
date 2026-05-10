// GENERATED — do not edit. Run 'just gen-manifests' to regenerate.
// Source: common/lib/src/services/dashboard/bundled/manifests/

part of 'embedded_manifests.dart';

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
        "max": { "$data": "mem_total_bytes" },
        "format": "bytes"
      }
    },
    {
      "ProgressBar": {
        "label": "Disk",
        "value": { "$data": "disk_used_bytes" },
        "max": { "$data": "disk_total_bytes" },
        "format": "bytes"
      }
    },
    { "Row": { "label": "Temp", "value": { "$format": "{temperature_c}°C" } } }
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
  'hardware': _hardwareJson,
  'system': _systemJson,
};
