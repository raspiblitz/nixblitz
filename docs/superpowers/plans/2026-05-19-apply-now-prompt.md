# "Apply now?" Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a plugin install completes or the operator leaves Configure with pending changes, surface a confirm popup that routes them to the Apply review screen (no auto-start), so "configured" isn't mistaken for "running."

**Architecture:** A new `applyNowPromptProvider` (StateProvider holding a nullable `ApplyNowPrompt`) drives an app-level `ApplyNowPopup` overlay rendered as a `Stack` sibling in `app.dart` and gated into `modalActiveProvider`. `[y]` clears the prompt + sets `currentViewProvider = AppView.apply` (lands on the existing mandatory review screen); `[n]`/Esc clears the prompt. Two trigger sites set the provider: plugin-install success and Configure Esc-to-dashboard with pending changes.

**Tech Stack:** Dart, nocterm + nocterm_riverpod, Riverpod StateProvider.

**Spec:** `docs/superpowers/specs/2026-05-19-apply-now-prompt-design.md`

**nocterm constraints (CLAUDE.md):** key handlers wrap their body in try/catch; provider sets happen as the last actions in a handler/callback (no non-provider work depending on lines after a `.state =`). The `[y]` callback sets two providers in sequence — the same pattern `apply_view._reset` uses; Task 6 verifies the popup doesn't linger over the Apply view.

---

### Task 1: `ApplyNowPrompt` model + provider + modal wiring

**Files:**

- Modify: `tui/lib/src/providers/ui_state_provider.dart`

- [ ] **Step 1: Add the model + provider**

In `tui/lib/src/providers/ui_state_provider.dart`, after the
`topMenuOverlayProvider` declaration (around line 58, before
`modalActiveProvider`), add:

```dart
/// Payload for the "Apply now?" popup. Set by action-completion
/// sites (plugin install done, leaving Configure with pending
/// edits); null means no popup. See
/// docs/superpowers/specs/2026-05-19-apply-now-prompt-design.md.
class ApplyNowPrompt {
  const ApplyNowPrompt({this.headline});

  /// Optional one-line summary of what just happened, e.g.
  /// "configured blitz-api v0.1.0". Null → the popup shows only the
  /// generic pending-change count (the Configure-exit case).
  final String? headline;
}

final applyNowPromptProvider = StateProvider<ApplyNowPrompt?>((ref) => null);
```

- [ ] **Step 2: Add it to `modalActiveProvider`**

Replace the existing `modalActiveProvider` body (around line 65-70):

```dart
final modalActiveProvider = Provider<bool>((ref) {
  final help = ref.watch(helpVisibleProvider);
  final sudo = ref.watch(pendingSudoPromptProvider);
  final topMenu = ref.watch(topMenuOverlayProvider);
  final applyNow = ref.watch(applyNowPromptProvider);
  return help || sudo != null || topMenu || applyNow != null;
});
```

- [ ] **Step 3: Verify it compiles**

Run: `cd tui && dart analyze lib/src/providers/ui_state_provider.dart`
Expected: No issues (or only pre-existing repo-wide infos).

- [ ] **Step 4: Commit**

```bash
git add tui/lib/src/providers/ui_state_provider.dart
git commit -m "$(cat <<'EOF'
feat(tui): add applyNowPromptProvider + ApplyNowPrompt model

State backing the "Apply now?" popup; folded into modalActiveProvider
so the underlying view yields focus while it's up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `ApplyNowPopup` widget + summary helper + test

**Files:**

- Create: `tui/lib/src/ui/widgets/apply_now_popup.dart`
- Test: `tui/test/ui/widgets/apply_now_popup_test.dart`

- [ ] **Step 1: Write the failing test for the summary helper**

`tui/test/ui/widgets/apply_now_popup_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/apply_now_popup.dart';

void main() {
  group('applyNowPendingSummary', () {
    test('one change is singular', () {
      expect(applyNowPendingSummary(1), '1 pending change.');
    });

    test('multiple changes are plural with the count', () {
      expect(applyNowPendingSummary(3), '3 pending changes.');
    });

    test('zero / negative falls back to a generic line', () {
      expect(applyNowPendingSummary(0), 'You have pending changes.');
      expect(applyNowPendingSummary(-1), 'You have pending changes.');
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tui && dart test test/ui/widgets/apply_now_popup_test.dart`
Expected: FAIL — `apply_now_popup.dart` / `applyNowPendingSummary` not defined.

- [ ] **Step 3: Write the widget + helper**

`tui/lib/src/ui/widgets/apply_now_popup.dart`:

```dart
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

/// Confirm-style popup nudging the operator to apply pending changes.
/// Surfaced after an action that produces pending changes (plugin
/// install complete, leaving Configure with edits). `[y]` routes to
/// the Apply review screen; `[n]` / Esc dismisses. See
/// docs/superpowers/specs/2026-05-19-apply-now-prompt-design.md.
class ApplyNowPopup extends StatelessComponent {
  final String? headline;
  final int pendingCount;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ApplyNowPopup({
    super.key,
    required this.headline,
    required this.pendingCount,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyY) {
            onConfirm();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            onCancel();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Apply-now popup key handler failed', e, st);
          return true;
        }
      },
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
            color: const Color.fromRGB(24, 24, 36),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Apply now?',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (headline != null)
                Text(
                  headline!,
                  style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
                ),
              Text(
                applyNowPendingSummary(pendingCount),
                style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const SizedBox(height: 1),
              const Text(
                'Applying runs `nixos-rebuild switch` (~2-5 min).',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const SizedBox(height: 1),
              const Text(
                '[y] Apply now   [n] Keep working',
                style: TextStyle(color: Color.fromRGB(120, 120, 140)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Terse one-line pending summary for the popup body. Top-level pure
/// function so it's unit-testable without the nocterm widget.
String applyNowPendingSummary(int pendingCount) {
  if (pendingCount <= 0) return 'You have pending changes.';
  if (pendingCount == 1) return '1 pending change.';
  return '$pendingCount pending changes.';
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tui && dart test test/ui/widgets/apply_now_popup_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Format + commit**

```bash
just format
git add tui/lib/src/ui/widgets/apply_now_popup.dart \
        tui/test/ui/widgets/apply_now_popup_test.dart
git commit -m "$(cat <<'EOF'
feat(tui): ApplyNowPopup widget + pending-summary helper

Confirm-style [y]/[n] popup, positioned like HelpPopup. The
pending-summary string is a top-level pure function with unit
coverage; the widget itself is verified manually (nocterm has no
headless renderer).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Render the popup + wire actions in `app.dart`

**Files:**

- Modify: `tui/lib/src/ui/app.dart`

- [ ] **Step 1: Import the widget**

In `tui/lib/src/ui/app.dart`, with the other widget imports near the
top (alongside the existing `import '../widgets/...';` lines or the
view imports), add:

```dart
import 'widgets/apply_now_popup.dart';
```

- [ ] **Step 2: Render the popup as a Stack sibling**

In `app.dart`, the top-level `Stack`'s `children` list ends with the
sudo overlay (around line 796):

```dart
        if (sudoPromptVisible) const PasswordOverlay(),
```

Add directly after it (still inside the `children` list, before the
closing `],`):

```dart
        // "Apply now?" nudge after an action produced pending
        // changes. Routes to the Apply review screen on [y]; does
        // NOT auto-start the rebuild (the review stays mandatory).
        if (context.watch(applyNowPromptProvider) != null)
          ApplyNowPopup(
            headline: context.watch(applyNowPromptProvider)!.headline,
            pendingCount: context.watch(pendingChangeKeysProvider).length,
            onConfirm: () {
              context.read(applyNowPromptProvider.notifier).state = null;
              context.read(currentViewProvider.notifier).state =
                  AppView.apply;
            },
            onCancel: () {
              context.read(applyNowPromptProvider.notifier).state = null;
            },
          ),
```

- [ ] **Step 3: Gate the underlying view's focus**

The root `Focusable` already gates on `helpVisible` + `sudoPromptVisible`
(line ~520). Extend it so the popup also takes focus. Find:

```dart
        Focusable(
          focused: !helpVisible && !sudoPromptVisible,
```

and replace with:

```dart
        Focusable(
          focused: !helpVisible && !sudoPromptVisible && !applyNowVisible,
```

Then add, alongside the existing `helpVisible` / `sudoPromptVisible`
locals (around line 505-506):

```dart
    final applyNowVisible = context.watch(applyNowPromptProvider) != null;
```

- [ ] **Step 4: Verify it compiles**

Run: `cd tui && dart analyze lib/src/ui/app.dart`
Expected: No new issues (the 6 pre-existing `implementation_imports`
infos on `dashboard_view.dart` / `tile_renderer.dart` are unrelated).

- [ ] **Step 5: Commit**

```bash
git add tui/lib/src/ui/app.dart
git commit -m "$(cat <<'EOF'
feat(tui): render ApplyNowPopup overlay + wire [y]/[n] actions

[y] clears the prompt and routes to AppView.apply (the mandatory
review screen); [n]/Esc clears the prompt. The root view's
Focusable yields while the popup is up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Trigger — plugin install complete

**Files:**

- Modify: `tui/lib/src/ui/views/plugin_install_view.dart:113-128`

- [ ] **Step 1: Set the prompt on install success**

In `plugin_install_view.dart`, the success `.then((marker) { … })`
block (around line 113-128) sets `_resultMessage` /`_resultMarker`
inside `setState`. After the `setState(...)` call closes (still
inside the `Future.microtask` + `if (!mounted) return;` guard), set
the prompt:

```dart
        .then((marker) {
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _resultMarker = marker;
              _resultMessage = 'configured ${marker.id} v${marker.version}';
              _phase = _Phase.done;
            });
            // Nudge toward applying — the plugin's files are on disk
            // but its service won't run until a rebuild. Routes to
            // the Apply review screen on [y].
            context.read(applyNowPromptProvider.notifier).state =
                ApplyNowPrompt(
                  headline: 'configured ${marker.id} v${marker.version}',
                );
          });
        })
```

Add the import if not already present:

```dart
import '../../providers/ui_state_provider.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tui && dart analyze lib/src/ui/views/plugin_install_view.dart`
Expected: No new issues.

- [ ] **Step 3: Commit**

```bash
git add tui/lib/src/ui/views/plugin_install_view.dart
git commit -m "$(cat <<'EOF'
feat(tui): trigger Apply-now prompt after a plugin install

On install success, set applyNowPromptProvider with a "configured
<id> v<ver>" headline so the operator is nudged to apply instead
of assuming the plugin is already running.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Trigger — leaving Configure with pending changes

**Files:**

- Modify: `tui/lib/src/ui/views/configure_view.dart:390-398`

- [ ] **Step 1: Set the prompt on Esc-to-dashboard when pending**

In `configure_view.dart`, the Esc handler's sidebar→dashboard branch
(around line 390-398) currently reads:

```dart
              if (event.logicalKey == LogicalKey.escape) {
                if (focusedColumn == ConfigureColumn.content) {
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.sidebar;
                } else {
                  context.read(currentViewProvider.notifier).state =
                      AppView.dashboard;
                }
                return true;
              }
```

Replace the `else` branch so it sets the prompt (when pending)
before navigating:

```dart
              if (event.logicalKey == LogicalKey.escape) {
                if (focusedColumn == ConfigureColumn.content) {
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.sidebar;
                } else {
                  // Leaving Configure. If there are pending edits,
                  // surface the Apply-now prompt over the dashboard.
                  // (Set before navigating: provider sets in a key
                  // handler run sequentially, but order is defensive
                  // — the prompt is the signal we don't want dropped.)
                  if (context.read(pendingChangeKeysProvider).isNotEmpty) {
                    context.read(applyNowPromptProvider.notifier).state =
                        const ApplyNowPrompt();
                  }
                  context.read(currentViewProvider.notifier).state =
                      AppView.dashboard;
                }
                return true;
              }
```

Ensure these imports exist in the file:

```dart
import '../../providers/ui_state_provider.dart';   // applyNowPromptProvider
```

(`pendingChangeKeysProvider` comes from `package:common/common.dart`,
already imported by this view.)

- [ ] **Step 2: Verify it compiles**

Run: `cd tui && dart analyze lib/src/ui/views/configure_view.dart`
Expected: No new issues.

- [ ] **Step 3: Commit**

```bash
git add tui/lib/src/ui/views/configure_view.dart
git commit -m "$(cat <<'EOF'
feat(tui): trigger Apply-now prompt when leaving Configure dirty

Esc → dashboard with a non-empty pendingChangeKeysProvider now
surfaces the Apply-now popup over the dashboard. Only fires on
flow exit, never mid-edit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Verify end-to-end + docs

**Files:**

- Modify: `docs/getting-started.md` (one-line mention near the
  Configure → Apply loop)

- [ ] **Step 1: Run the trio**

Run: `just test; just analyze; just format`
Expected: tests green (common + tui, including the new
`apply_now_popup_test`); analyze shows only the pre-existing 6
`implementation_imports` infos; format clean.

- [ ] **Step 2: Manual smoke (just run / VM)**

With `just run` (or on the VM):

- Install a plugin via Configure → Plugins → confirm the "Apply
  now?" popup appears over the result screen with the "configured
  <id>" headline.
- Press `[y]` → lands on the System → Apply **review** screen
  showing the plugin change; the popup is gone (does NOT linger).
- Re-trigger, press `[n]` → popup dismisses, operator stays on the
  result screen.
- Edit a Configure field, press Esc back to the dashboard →
  popup appears over the dashboard; `[y]` → review screen.
- Confirm the popup never fires mid-edit (only on Esc / install
  done), and the `[y]` → Apply transition leaves no lingering
  popup (the key risk from the two-provider set in the handler).

If the popup lingers over the Apply view after `[y]`: the
sequential provider set was discarded by the rebuild. Fallback —
gate the popup render on `applyNowPromptProvider != null &&
currentView != AppView.apply` in app.dart so it self-hides on
navigation regardless of set ordering.

- [ ] **Step 3: Document it**

In `docs/getting-started.md`, near the Configure → Apply loop
description, add a sentence:

```markdown
After installing a plugin or leaving Configure with unsaved edits,
an "Apply now?" prompt offers to jump straight to the Apply review
screen — `[y]` to review + apply, `[n]` to keep working.
```

- [ ] **Step 4: Commit**

```bash
git add docs/getting-started.md
git commit -m "$(cat <<'EOF'
docs: mention the Apply-now prompt in getting-started

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `just test` green (common + tui, new popup-summary test included).
- [ ] `just analyze` — only the pre-existing 6 `implementation_imports` infos.
- [ ] `just format` clean.
- [ ] Manual: both triggers fire only on action completion; `[y]`
      routes to the review screen with no lingering popup; `[n]`/Esc
      dismisses; rebuild still requires the explicit `[a]` on the
      review screen (no auto-start, no silent apply).
- [ ] `git status` clean.
