import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'views/dashboard_view.dart';
import 'views/apply_view.dart';
import 'views/config_too_new_view.dart';
import 'views/configure_view.dart';
import 'views/debug_view.dart';
import 'views/install_view.dart';
import 'views/setup_view.dart';
import 'views/system_view.dart';
import 'shutdown.dart';
import 'widgets/cached_package_diff.dart';
import 'widgets/footer_hints.dart';
import 'widgets/help_popup.dart';
import 'widgets/password_overlay.dart';
import 'widgets/top_menu.dart';
import '../build_info.dart';
import '../providers/ui_state_provider.dart';
import '../providers/viewport_provider.dart';
import '../services/check_runner.dart';

// helpVisibleProvider and modalActiveProvider live in
// ui_state_provider.dart so widgets without a back-import to
// `app.dart` (ScrollableLog, the views' own Focusables) can read
// them.

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
bool isInstallerEnvironment() {
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

/// Builds the segments for the top-of-screen header strip's
/// center text: `<alias> | <platform> | <pending-status>`.
/// Returns a list of `(text, color)` pairs so the call site
/// can render the trailing pending segment in yellow when
/// changes are pending without re-tinting the whole header.
///
/// Alias source prefers the live snapshot from blitz-api over
/// `config.lnd.alias` so an in-progress edit (operator typed a
/// new alias in Configure but hasn't run Apply yet) doesn't
/// make the header lie about what the running LND is actually
/// announcing on the wire. Falls back to config when there's
/// no snapshot — covers initial setup, blitz-api off, fresh
/// reconnect.
///
/// `pendingCount` comes from `pendingChangeKeysProvider`
/// (per-key, NOT file-level — see the provider docstring for
/// the trade-off vs the dashboard banner).
///
/// Network and per-service status stay out of the header —
/// both already show on the dashboard tiles + footer banners,
/// and the strip has limited horizontal real estate on narrower
/// terminals.
List<({String text, Color color})> _headerSegments(
  NixblitzConfig config,
  String liveAlias,
  int pendingCount,
  AppView view,
) {
  const dim = Color.fromRGB(180, 180, 200);
  const pending = Color.fromRGB(220, 180, 100); // same yellow as `*` markers
  final segs = <({String text, Color color})>[];

  // Live alias from tileDataCache's lightning snapshot wins; fall
  // back to config only when no event has landed yet (LN not set up,
  // blitz-api down, SSE hasn't reconnected). isAppEnabled gates
  // so we don't show a config-only stub when LN isn't enabled.
  final configAlias = config.appOption<String>('lnd', 'alias') ?? '';
  final fallbackAlias = (config.isAppEnabled('lnd') && configAlias.isNotEmpty)
      ? configAlias
      : '';
  final alias = liveAlias.isNotEmpty ? liveAlias : fallbackAlias;
  if (alias.isNotEmpty) segs.add((text: alias, color: dim));

  final platform = switch (config.system.platform) {
    'pi5' => 'Pi 5',
    'vm' => 'VM',
    'x86' => 'x86',
    final s => s,
  };
  if (platform.isNotEmpty) segs.add((text: platform, color: dim));

  // Status segment: during the pre-dashboard wizard phases the
  // "all applied" / "X pending" idiom is meaningless (no system
  // to apply against yet); show a phase label instead. Wording
  // for the dashboard case deliberately avoids "in sync" /
  // "synced" — that reads as Bitcoin / Lightning chain-sync
  // state in this domain. `applied` ties to the `[a]` Apply
  // keybind that flips pending → applied.
  switch (view) {
    case AppView.install:
      segs.add((text: 'installing', color: dim));
    case AppView.setup:
      segs.add((text: 'setting up', color: dim));
    default:
      if (pendingCount > 0) {
        segs.add((text: '$pendingCount pending', color: pending));
      } else {
        segs.add((text: 'all applied', color: dim));
      }
  }

  return segs;
}

/// True when the current view is one of the lifecycle wizards
/// (install / setup / configTooNew). The top menu hides during
/// these because the operator is on a forced linear path with no
/// menu navigation to offer.
bool _isLifecycleView(AppView view) =>
    view == AppView.install ||
    view == AppView.setup ||
    view == AppView.configTooNew;

/// Context-sensitive hint list painted in the bottom strip — see
/// `widgets/footer_hints.dart`. Composed in the shell rather than
/// per-view so the strip's layout stays uniform and the sidebar /
/// content interaction model is visible at a glance.
///
/// Returns an empty list for views that paint their own per-phase
/// hints (Apply / Update / Install / Setup / packageDiff / config-
/// TooNew) — the global strip stays out of their way.
// Universal hint trailers reused across view-state branches. Top-
// level so the per-view branches below can still return `const`
// lists.
const _hintTop = FooterHint(key: '←/→', action: 'switch view');
const _hintHelp = FooterHint(key: '?', action: 'help');
const _hintQuit = FooterHint(key: 'q', action: 'quit');

List<FooterHint> _computeFooterHints(BuildContext context) {
  final view = context.watch(currentViewProvider);
  final hints = _hintsFor(context, view);
  if (context.watch(viewportClassProvider) == ViewportClass.compact) {
    return _compactifyHints(hints);
  }
  return hints;
}

/// Drop the global trailers (`←/→ switch view`, `? help`, `q quit`)
/// and shorten the remaining action text. The trailers stay
/// reachable via the hamburger overlay + `?` hotkey; cramped
/// phone-landscape screens shouldn't blow them on a line that's
/// going to clip anyway.
List<FooterHint> _compactifyHints(List<FooterHint> hints) {
  const trailerKeys = {'←/→', '?', 'q', 'h/l'};
  const shorten = <String, String>{
    'pick section': 'move',
    'pick option': 'move',
    'pick action': 'move',
    'pick row': 'move',
    'edit section': 'open',
    'change value': 'edit',
    'run check': 'run',
    'run action': 'run',
    'arm / confirm': 'arm',
    'back to dashboard': 'back',
    'back to sidebar': 'back',
    'Check / Apply / Power': 'sections',
    'navigate': 'move',
    'scroll': 'scroll',
  };
  return [
    for (final h in hints)
      if (!trailerKeys.contains(h.key))
        FooterHint(key: h.key, action: shorten[h.action] ?? h.action),
  ];
}

List<FooterHint> _hintsFor(BuildContext context, AppView view) {
  switch (view) {
    case AppView.dashboard:
      return const [
        FooterHint(key: '↑/↓', action: 'scroll'),
        _hintTop,
        _hintHelp,
        _hintQuit,
      ];

    case AppView.configure:
      final col = context.watch(configureFocusedColumnProvider);
      if (col == ConfigureColumn.sidebar) {
        return const [
          FooterHint(key: '↑/↓', action: 'pick section'),
          FooterHint(key: 'Enter', action: 'edit section'),
          FooterHint(key: 'Esc', action: 'back to dashboard'),
          _hintTop,
          _hintHelp,
        ];
      }
      return const [
        FooterHint(key: '↑/↓', action: 'pick option'),
        FooterHint(key: 'Enter', action: 'change value'),
        FooterHint(key: 'Esc', action: 'back to sidebar'),
        _hintTop,
        _hintHelp,
      ];

    case AppView.system:
      final col = context.watch(systemColumnProvider);
      final section = context.watch(systemSectionProvider);
      if (col == SystemColumn.sidebar) {
        return const [
          FooterHint(key: '↑/↓', action: 'Check / Apply / Power'),
          FooterHint(key: 'Enter', action: 'pick action'),
          FooterHint(key: 'Esc', action: 'back to dashboard'),
          _hintTop,
          _hintHelp,
        ];
      }
      final enterLabel = switch (section) {
        SystemSection.check => 'run check',
        SystemSection.apply => 'run action',
        SystemSection.power => 'arm / confirm',
      };
      return [
        const FooterHint(key: '↑/↓', action: 'pick action'),
        FooterHint(key: 'Enter', action: enterLabel),
        const FooterHint(key: 'Esc', action: 'back to sidebar'),
        _hintTop,
        _hintHelp,
      ];

    case AppView.debug:
      return const [
        FooterHint(key: '↑/↓', action: 'navigate'),
        FooterHint(key: 'Esc', action: 'back to dashboard'),
        _hintTop,
        _hintHelp,
        _hintQuit,
      ];

    // Self-paint their own per-phase hints; shell strip stays
    // empty to avoid double-bottom-bars.
    case AppView.install:
    case AppView.setup:
    case AppView.apply:
    case AppView.packageDiff:
    case AppView.configTooNew:
      return const [];
  }
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
    final isInstaller = isInstallerEnvironment();
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

class _Shell extends StatefulComponent {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  StreamSubscription<Size>? _resizeSubscription;
  bool _viewportSeeded = false;
  Timer? _quitArmTimer;

  @override
  void initState() {
    super.initState();
    // Pump the live terminal size + resize stream into the viewport
    // provider so layout-sensitive widgets (sidebars, modals, top
    // menu) react to SIGWINCH within one frame. Microtask defer so
    // we don't mutate state mid-mount.
    final binding = TerminalBinding.instance;
    Future.microtask(() {
      if (!mounted) return;
      _pushSize(binding.terminal.size);
    });
    final resizeStream = binding.terminal.backend.resizeStream;
    if (resizeStream != null) {
      _resizeSubscription = resizeStream.listen((size) {
        if (!mounted) return;
        _pushSize(size);
      });
    }
  }

  void _pushSize(Size size) {
    final w = size.width.toInt();
    final h = size.height.toInt();
    final current = context.read(viewportSizeProvider);
    if (_viewportSeeded && current.width == w && current.height == h) {
      return;
    }
    _viewportSeeded = true;
    context.read(viewportSizeProvider.notifier).state = ViewportSize(w, h);
  }

  @override
  void dispose() {
    _resizeSubscription?.cancel();
    _quitArmTimer?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    // Touch the FS watcher once so it instantiates and starts
    // listening on the first build. Provider memoizes — repeated
    // reads are no-ops; the subscription stays alive for the
    // ProviderScope's lifetime.
    context.read(configWatcherProvider);

    final helpVisible = context.watch(helpVisibleProvider);
    final sudoPromptVisible = context.watch(pendingSudoPromptProvider) != null;

    // Fire-and-forget light check at startup if the cached status is
    // stale (>30 min). Guarded by a per-process flag inside the
    // helper so _Shell rebuilds don't re-trigger. Lifecycle wizards
    // (install / setup) skip — there's no flake.lock yet on the
    // installer ISO, and update-status only matters post-dashboard.
    if (!_isLifecycleView(context.read(currentViewProvider))) {
      maybeAutoStartupCheck(context);
    }

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
                context.read(helpVisibleProvider.notifier).state = true;
                return true;
              }
              final currentView = context.read(currentViewProvider);

              // Top-menu navigation: ←/→/h/l cycle through the
              // strip's entries and switch view immediately. Only
              // fires outside lifecycle wizards (install / setup /
              // configTooNew), where the menu is hidden anyway.
              if (!_isLifecycleView(currentView)) {
                final menuIdx = topMenuIndexForView(currentView);
                if (event.logicalKey == LogicalKey.arrowLeft ||
                    event.logicalKey == LogicalKey.keyH) {
                  final prev = menuIdx <= 0
                      ? kTopMenuEntries.length - 1
                      : menuIdx - 1;
                  context.read(currentViewProvider.notifier).state =
                      kTopMenuEntries[prev].view;
                  return true;
                }
                if (event.logicalKey == LogicalKey.arrowRight ||
                    event.logicalKey == LogicalKey.keyL) {
                  final next =
                      menuIdx < 0 || menuIdx >= kTopMenuEntries.length - 1
                      ? 0
                      : menuIdx + 1;
                  context.read(currentViewProvider.notifier).state =
                      kTopMenuEntries[next].view;
                  return true;
                }
              }

              // Hotkey shortcuts — run globally (only fire if the
              // focused view didn't consume the key first via its
              // own Focusable). Apply's `[a]`, Update's `[c]/[C]`,
              // and text-edit overlays all swallow these before
              // they reach the shell, so view-local meanings still
              // win on the views that need them. Anywhere else
              // (Configure list, Debug, Dashboard, …) the shell
              // catches the key and switches view.
              if (event.logicalKey == LogicalKey.keyC) {
                context.read(currentViewProvider.notifier).state =
                    AppView.configure;
                return true;
              }
              if (event.logicalKey == LogicalKey.keyA ||
                  event.logicalKey == LogicalKey.keyU) {
                // Both [a] (Apply) and [u] (Update) now land on the
                // unified System tab — the merged screen splits them
                // into Apply and Check sections internally.
                context.read(currentViewProvider.notifier).state =
                    AppView.system;
                return true;
              }
              if (event.matches(LogicalKey.keyD, shift: true)) {
                context.read(currentViewProvider.notifier).state =
                    AppView.debug;
                return true;
              }
              if (event.logicalKey == LogicalKey.keyQ) {
                // Confirm `q` when an Apply / Update flow is mid-
                // stream — a fat-fingered `q` in place of `a` must
                // not nuke a half-finished rebuild. After
                // `updateLock` commits flake.lock or `commitAll`
                // commits config.json, an immediate quit leaves
                // HEAD ahead of `/run/current-system` with no
                // breadcrumb in the working tree.
                final busy = context.read(inflightOperationProvider);
                if (busy) {
                  final armed = context.read(quitArmedProvider);
                  if (!armed) {
                    context.read(quitArmedProvider.notifier).state = true;
                    _quitArmTimer?.cancel();
                    _quitArmTimer = Timer(const Duration(seconds: 3), () {
                      if (!mounted) return;
                      context.read(quitArmedProvider.notifier).state = false;
                    });
                    return true;
                  }
                  _quitArmTimer?.cancel();
                  _quitArmTimer = null;
                }
                shutdownWithTerminalRestore();
                return true;
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
                    vertical: 0,
                  ),
                  // Header as its own (non-interactive) pane —
                  // matches the zellij idiom where every region
                  // is a bordered rectangle. Idle border color
                  // because there's no focus distinction here:
                  // the header never receives keys.
                  decoration: const BoxDecoration(
                    border: BoxBorder(
                      top: BorderSide(color: Color.fromRGB(80, 80, 100)),
                      right: BorderSide(color: Color.fromRGB(80, 80, 100)),
                      bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
                      left: BorderSide(color: Color.fromRGB(80, 80, 100)),
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
                          child: () {
                            // Header pulls from three providers:
                            // config (alias fallback / platform),
                            // tileDataCache (live LN alias from
                            // lightning snapshot), and
                            // pendingChangeKeysProvider (the
                            // count of dotted-path keys differing
                            // from HEAD).
                            final cfg = context
                                .watch(configProvider)
                                .maybeWhen(data: (c) => c, orElse: () => null);
                            if (cfg == null) return const Text('');
                            // Synchronous Provider — direct read,
                            // no AsyncValue unwrap. The header
                            // status updates in the same frame as
                            // the configProvider tick that
                            // triggered it (no flicker through a
                            // loading state).
                            final lnData = context
                                .watch(tileDataCacheProvider)
                                .snapshotFor('lightning')
                                .data;
                            final liveAlias = lnData['alias'] is String
                                ? lnData['alias'] as String
                                : '';
                            final pendingCount = context
                                .watch(pendingChangeKeysProvider)
                                .length;
                            final segs = _headerSegments(
                              cfg,
                              liveAlias,
                              pendingCount,
                              context.watch(currentViewProvider),
                            );
                            // Render as a Row of segment + " | "
                            // separator + segment, each in its
                            // own colour. The separator stays in
                            // the same dim grey as the other
                            // segments — only the pending status
                            // is yellow when count > 0.
                            const sepColor = Color.fromRGB(180, 180, 200);
                            final children = <Component>[];
                            for (var i = 0; i < segs.length; i++) {
                              if (i > 0) {
                                children.add(
                                  const Text(
                                    ' | ',
                                    style: TextStyle(color: sepColor),
                                  ),
                                );
                              }
                              children.add(
                                Text(
                                  segs[i].text,
                                  style: TextStyle(color: segs[i].color),
                                ),
                              );
                            }
                            // mainAxisSize.min — without it the
                            // Row stretches to fill the Center's
                            // width and Center has nothing to
                            // actually center, so the segments
                            // butt up against the NIXBLITZ logo
                            // on the left.
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: children,
                            );
                          }(),
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
                if (!_isLifecycleView(context.watch(currentViewProvider)))
                  TopMenu(activeView: context.watch(currentViewProvider)),
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
                      AppView.system => const SystemView(),
                      AppView.apply => const ApplyView(),
                      AppView.packageDiff => CachedPackageDiff(
                        onClose: () =>
                            context.read(currentViewProvider.notifier).state =
                                AppView.system,
                      ),
                      AppView.debug => const DebugView(),
                      AppView.configTooNew => const ConfigTooNewView(),
                    },
                  ),
                ),
                if (context.watch(quitArmedProvider))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: const Text(
                      'Rebuild in flight — press q again within 3s to quit anyway',
                      style: TextStyle(
                        color: Color.fromRGB(255, 200, 80),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                // Context-sensitive footer — only on views whose nav
                // model isn't already self-explanatory. install /
                // setup / configTooNew run linear wizards; apply /
                // update / packageDiff have their own internal hint
                // lines tuned to each sub-phase.
                FooterHints(hints: _computeFooterHints(context)),
              ],
            ),
          ),
        ),
        if (helpVisible)
          HelpPopup(
            onClose: () {
              context.read(helpVisibleProvider.notifier).state = false;
            },
          ),
        // Compact-mode hamburger-overlay listing every top-menu
        // entry. Opens when the operator taps the `☰` glyph in the
        // compact top strip.
        if (context.watch(topMenuOverlayProvider)) const TopMenuOverlay(),
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
