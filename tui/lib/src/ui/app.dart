import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import 'views/dashboard_view.dart';
import 'views/apply_view.dart';
import 'views/config_too_new_view.dart';
import 'views/configure_view.dart';
import 'views/debug_view.dart';
import 'views/install_view.dart';
import 'views/setup_view.dart';
import 'views/update_view.dart';
import 'shutdown.dart';
import 'widgets/help_popup.dart';
import 'widgets/password_overlay.dart';
import '../build_info.dart';
import '../providers/ui_state_provider.dart';

final _helpVisibleProvider = StateProvider<bool>((ref) => false);

/// Detect whether we're running inside a NixOS installer image —
/// the x86 minimal ISO, the Pi 5 SD-image installer, etc. These
/// are the environments where [AppView.install] is the right
/// startup view and disk-wiping commands are safe to run.
///
/// Two signals, ORed together so each image variant is covered:
///
/// 1. **Root filesystem is tmpfs.** True on the upstream NixOS
///    minimal ISO (the x86 walkthrough's path), where the rootfs
///    overlays a tmpfs on top of the read-only squashfs. False
///    on installer images that boot writable disk images
///    (like nvmd's Pi 5 sdimage-installer, which roots on a
///    real ext4 partition).
///
/// 2. **`VARIANT_ID=installer` in `/etc/os-release`.** Set by
///    upstream nixos-images for every installer flavour. This
///    is what catches the Pi 5 case the tmpfs check misses.
///    Installed NixOS systems either omit `VARIANT_ID` or set
///    it to something else.
bool _isInstallerEnvironment() {
  try {
    final result = Process.runSync('stat', ['-f', '-c', '%T', '/']);
    if ((result.stdout as String).trim() == 'tmpfs') return true;
  } catch (e) {
    LogService.warn('Could not stat / for tmpfs check: $e');
  }
  try {
    final content = File('/etc/os-release').readAsStringSync();
    // Match `VARIANT_ID=installer` (with or without quotes) on
    // its own line. Avoid substring matches like
    // `BUILD_ID=…installer…` — only the explicit field counts.
    final hit = RegExp(
      r'^VARIANT_ID="?installer"?$',
      multiLine: true,
    ).hasMatch(content);
    if (hit) return true;
  } catch (e) {
    LogService.warn('Could not read /etc/os-release: $e');
  }
  return false;
}

/// Center text for the top-of-screen header strip — sits
/// between the "NIXBLITZ" logo and the version string. Surfaces
/// the at-a-glance identity of the box: the operator-chosen LN
/// node alias (when LND is enabled and they actually picked
/// one) plus a prettified platform name.
///
/// Network and per-service status deliberately stay out of the
/// header — both already show on the dashboard tiles + footer
/// banners, and the header has limited horizontal real estate
/// on narrower terminals.
String _formatHeaderInfo(NixblitzConfig config) {
  final parts = <String>[];
  if (config.lnd.enabled && config.lnd.alias.isNotEmpty) {
    parts.add(config.lnd.alias);
  }
  final platform = switch (config.system.platform) {
    'pi5' => 'Pi 5',
    'vm' => 'VM',
    'x86' => 'x86',
    final s => s,
  };
  if (platform.isNotEmpty) parts.add(platform);
  return parts.join(' | ');
}

/// Footer text for the current view. Dashboard omits `[a]:
/// Apply` when the working tree is clean and only surfaces
/// `[r]: Refresh templates` when drift was detected at launch
/// — there's nothing to apply / refresh otherwise, so
/// advertising the shortcut is noise.
String _footerHint(
  AppView view, {
  required bool hasPending,
  required bool hasDrift,
}) {
  return switch (view) {
    AppView.install => '[↑/↓]: Navigate  [Enter]: Select  [?]: Help',
    AppView.setup => 'Setting up...  [?]: Help',
    AppView.dashboard => [
      '[c]: Configure',
      if (hasPending) '[a]: Apply',
      '[u]: Update',
      if (hasDrift) '[r]: Refresh templates',
      '[D]: Debug',
      '[?]: Help',
      '[q]: Quit',
    ].join('  '),
    AppView.configure =>
      '[↑/↓]: Navigate  [Enter]: Edit  [Esc]: Back  [?]: Help',
    AppView.apply => '[a]: Apply  [d]: Discard  [Esc]: Back  [?]: Help',
    AppView.debug => '[↑/↓]: Navigate  [Enter]: Run  [Esc]: Back  [?]: Help',
    AppView.configTooNew => '[c]: Continue anyway  [q]: Quit',
    AppView.update =>
      '[↑/↓]: Navigate  [Enter]: Select  [Esc]: Back  [?]: Help',
  };
}

/// Run when the on-disk config is older than this TUI expects:
/// migrate `config.json` to [currentConfigVersion] and leave
/// the working tree dirty so the user reviews + applies via
/// `[a]`. Templates refresh used to live here too, but it's
/// now a separate concern driven by drift detection (see
/// [detectTemplatesDrift] + the dashboard's drift banner).
/// Schema-version bumps are about config-shape migrations
/// only; templates that change for bug-fix-only reasons (no
/// schema bump) get caught by the drift check.
void _autoMigrateConfig(String baseDir) {
  try {
    // Read + re-write config so migrations run and the
    // `version` field bumps. Synchronous path — ConfigService
    // has both async and sync variants; we want sync here to
    // block before the UI renders.
    final configService = ConfigService(baseDir: baseDir);
    final json =
        jsonDecode(File('$baseDir/config.json').readAsStringSync())
            as Map<String, dynamic>;
    final config = NixblitzConfig.fromJson(json);
    configService.writeConfigSync(config);

    LogService.info(
      'Auto-migrate complete: config migrated to v$currentConfigVersion. '
      'Working tree left dirty for user review.',
    );
  } catch (e, st) {
    LogService.error('Auto-migrate failed', e, st);
  }
}

class NixBlitzApp extends StatelessComponent {
  final String baseDir;
  final String startupBinary;

  const NixBlitzApp({
    super.key,
    required this.baseDir,
    required this.startupBinary,
  });

  @override
  Component build(BuildContext context) {
    // Detect if we're inside a NixOS installer image (x86 minimal
    // ISO, Pi 5 sdimage installer, etc.). On any installer image
    // we always start in install mode regardless of existing
    // config so a failed install attempt can be retried.
    final isInstaller = _isInstallerEnvironment();
    final configPath = '$baseDir/config.json';
    final configExists = File(configPath).existsSync();

    // Safety: if we're NOT in an installer image AND there's no
    // config, this is an installed non-NixBlitz system. Refuse to
    // start to prevent accidents (install mode would try to wipe
    // a disk).
    if (!isInstaller && !configExists) {
      return _RefusalScreen(message: _noConfigNonIsoMessage);
    }

    AppView initialView;
    if (isInstaller) {
      initialView = AppView.install;
    } else {
      // configExists is guaranteed true here (refusal above handles the else)
      try {
        final content = File(configPath).readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final diskVersion = (json['version'] as int?) ?? 1;
        // `setup_step_completed` is the name of the last wizard
        // step the operator finished (the wizard's SetupStep
        // enum names — `setPassword`, `buildServices`,
        // `waitBitcoind`, `initLightning`, `summary`). The
        // wizard is fully done when it equals the terminal step
        // name; any other value (including null) means the
        // operator quit mid-flow and should resume at the next
        // undone step. The terminal name is hardcoded here so
        // app-level routing doesn't need to import the wizard
        // module's private enum.
        final stepCompleted = json['setup_step_completed'] as String?;
        final setupComplete = stepCompleted == 'summary';

        if (diskVersion > currentConfigVersion) {
          // Newer than we understand. Let the user choose whether to
          // continue (fields we don't know may be dropped on save) or
          // quit and upgrade the TUI.
          LogService.warn(
            'Config version $diskVersion > this TUI ($currentConfigVersion); '
            'offering continue/quit.',
          );
          initialView = AppView.configTooNew;
        } else {
          if (diskVersion < currentConfigVersion) {
            // Older NixBlitz config schema on disk. Run
            // migrations to bring config.json up to date.
            // Templates refresh is intentionally NOT done here
            // anymore — drift detection on the dashboard owns
            // that concern, so a templates-only release also
            // gets caught (the case the page-size-16k fix
            // missed because no schema bump fired).
            _autoMigrateConfig(baseDir);
          }
          initialView = setupComplete ? AppView.dashboard : AppView.setup;
        }
      } catch (e, st) {
        LogService.error(
          'Failed to read config.json for mode detection',
          e,
          st,
        );
        initialView = AppView.dashboard;
      }
    }

    // Compute templates drift once at launch. Cheap (diff
    // ~20 short string blobs against on-disk files), and the
    // underlying state only changes via out-of-process events
    // (binary update, hand-edit). Result feeds the dashboard's
    // refresh banner via `templatesDriftProvider`.
    //
    // Skipped on installer images — the templates we'd diff
    // against don't exist yet (the install flow scaffolds
    // them onto the target disk, not the live media). Drift
    // detection is meaningful only on a fully-installed
    // system.
    final initialDrift = (isInstaller || !configExists)
        ? TemplatesDrift.inSync
        : detectTemplatesDrift(baseDir);
    if (initialDrift.hasDrift) {
      LogService.info(
        'Templates drift detected at launch: '
        '${initialDrift.modified.length} modified, '
        '${initialDrift.missing.length} missing. '
        'Modified=${initialDrift.modified}; missing=${initialDrift.missing}',
      );
    }

    return ProviderScope(
      overrides: [
        baseDirProvider.overrideWithValue(baseDir),
        startupBinaryProvider.overrideWithValue(startupBinary),
        currentViewProvider.overrideWith((ref) => initialView),
        templatesDriftProvider.overrideWith((ref) => initialDrift),
      ],
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark.copyWith(
          primary: const Color.fromRGB(247, 147, 26),
          background: const Color.fromRGB(24, 24, 36),
          surface: const Color.fromRGB(36, 36, 54),
          onBackground: const Color.fromRGB(220, 220, 220),
          onSurface: const Color.fromRGB(200, 200, 200),
          onPrimary: const Color.fromRGB(0, 0, 0),
          outline: const Color.fromRGB(80, 80, 100),
          outlineVariant: const Color.fromRGB(60, 60, 80),
          selectionColor: const Color.fromRGB(80, 80, 120),
        ),
        home: const _Shell(),
      ),
    );
  }
}

class _Shell extends StatelessComponent {
  const _Shell();

  @override
  Component build(BuildContext context) {
    // Touch the FS watcher once so it instantiates and starts
    // listening on the first build. Provider memoizes — repeated
    // reads are no-ops; the subscription stays alive for the
    // ProviderScope's lifetime.
    context.read(configWatcherProvider);

    final helpVisible = context.watch(_helpVisibleProvider);
    final sudoPromptVisible = context.watch(pendingSudoPromptProvider) != null;

    return Stack(
      children: [
        Focusable(
          focused: !helpVisible && !sudoPromptVisible,
          onKeyEvent: (event) {
            try {
              if (event.matches(LogicalKey.keyC, ctrl: true)) {
                shutdownWithTerminalRestore();
                return true;
              }
              if (event.logicalKey == LogicalKey.question) {
                context.read(_helpVisibleProvider.notifier).state = true;
                return true;
              }
              final currentView = context.read(currentViewProvider);
              if (currentView == AppView.dashboard) {
                if (event.logicalKey == LogicalKey.keyC) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.configure;
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyA) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.apply;
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyU) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.update;
                  return true;
                }
                if (event.matches(LogicalKey.keyD, shift: true)) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.debug;
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyR) {
                  // Refresh templates from the binary's
                  // embedded copy. Gated on actual drift —
                  // [r] is a no-op when the dashboard banner
                  // isn't showing, so a stray keypress doesn't
                  // overwrite hand-edited templates the
                  // operator hasn't reviewed yet.
                  final drift = context.read(templatesDriftProvider);
                  if (!drift.hasDrift) return true;
                  try {
                    final dir = context.read(baseDirProvider);
                    ScaffoldService(targetDir: dir).refreshTemplatesSync();
                    LogService.info(
                      'refresh: rewrote ${drift.totalChanged} drifted '
                      'template ${drift.totalChanged == 1 ? "file" : "files"}',
                    );
                    // Drift just got resolved — clear the
                    // banner. The apply view picks up the
                    // dirty tree from the file-system change.
                    context.read(templatesDriftProvider.notifier).state =
                        TemplatesDrift.inSync;
                    context.read(currentViewProvider.notifier).state =
                        AppView.apply;
                  } catch (e, st) {
                    LogService.error('Templates refresh failed', e, st);
                  }
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyQ) {
                  shutdownWithTerminalRestore();
                  return true;
                }
              }
              return false;
            } catch (e, st) {
              LogService.error('Global shell key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  decoration: const BoxDecoration(
                    border: BoxBorder(
                      bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'NIXBLITZ',
                        style: TextStyle(
                          color: Color.fromRGB(247, 147, 26),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            context
                                .watch(configProvider)
                                .maybeWhen(
                                  data: _formatHeaderInfo,
                                  orElse: () => '',
                                ),
                            style: const TextStyle(
                              color: Color.fromRGB(180, 180, 200),
                            ),
                          ),
                        ),
                      ),
                      Text(
                        buildVersionString,
                        style: const TextStyle(
                          color: Color.fromRGB(150, 150, 180),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 1),
                // Wrap the view swap in a stable SizedBox.expand so the
                // flex parent data applied by Expanded stays anchored to
                // one render object across view (and internal step)
                // changes. Without this, views that swap their root
                // widget type between steps (install, setup, update…)
                // lose the flex data and crash when they contain an
                // inner Expanded(ScrollableLog).
                Expanded(
                  child: SizedBox.expand(
                    child: switch (context.watch(currentViewProvider)) {
                      AppView.install => const InstallView(),
                      AppView.setup => const SetupView(),
                      AppView.dashboard => const DashboardView(),
                      AppView.configure => const ConfigureView(),
                      AppView.apply => const ApplyView(),
                      AppView.update => const UpdateView(),
                      AppView.debug => const DebugView(),
                      AppView.configTooNew => const ConfigTooNewView(),
                    },
                  ),
                ),
                const Divider(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    _footerHint(
                      context.watch(currentViewProvider),
                      hasPending: context
                          .watch(pendingChangesProvider)
                          .maybeWhen(
                            data: (lines) => lines.isNotEmpty,
                            orElse: () => false,
                          ),
                      hasDrift: context.watch(templatesDriftProvider).hasDrift,
                    ),
                    style: const TextStyle(
                      color: Color.fromRGB(247, 147, 26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (helpVisible)
          HelpPopup(
            onClose: () {
              context.read(_helpVisibleProvider.notifier).state = false;
            },
          ),
        // Sudo password modal — full-screen overlay; takes focus
        // exclusively so keystrokes can't leak into the underlying
        // view (passwords typed past Enter would otherwise be visible).
        if (sudoPromptVisible) const PasswordOverlay(),
      ],
    );
  }
}

const String _noConfigNonIsoMessage = '''
This system does not appear to be a NixBlitz installation.

To install NixBlitz:
  1. Boot a NixOS ISO (any recent 25.11 image)
  2. Run: nix run git+https://forge.f44.fyi/f44/nixblitz_ng

Refusing to start install mode on an installed system to prevent
accidental disk wipe.

Press any key to exit.''';

class _RefusalScreen extends StatelessComponent {
  final String message;

  const _RefusalScreen({required this.message});

  @override
  Component build(BuildContext context) {
    return ProviderScope(
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark,
        home: Focusable(
          focused: true,
          onKeyEvent: (event) {
            shutdownWithTerminalRestore(1);
            return true;
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NixBlitz — Cannot Start',
                  style: TextStyle(
                    color: Color.fromRGB(255, 80, 80),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                Text(message),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
