# "Apply now?" prompt — design

> After an in-TUI action produces pending changes, surface a
> confirm-style popup that shortcuts the operator to the Apply review
> screen — so "configured" doesn't get mistaken for "running."

## Context

After the operator installs a plugin (Configure → Plugins) or edits
a field in Configure, the change lands in `~/nixblitz/config.json`
but the running system is unchanged until they navigate to
System → Apply and confirm. New operators read "configured" as
"running" and go looking for a service that isn't up. The
post-install screen already says "Not yet running — open
System → Apply…" (`plugin_install_view.dart:396`) and the header
shows an "N pending" badge, but both rely on the operator
remembering a manual navigation step.

This adds a popup that nudges them there at the moment they finish
an action. Forge issue #31.

## Key decisions (locked in brainstorming)

- **"Apply now" routes to the review screen — it does NOT auto-start
  the rebuild.** We just shipped the Update/Apply unification whose
  whole point is a mandatory review before any generation change.
  The popup is a _navigation shortcut_, not a bypass: `[y]` lands
  the operator on the Apply review screen, where they still press
  `[a]` to start. This keeps the no-silent-apply guarantee intact
  and means the popup needs zero sudo/rebuild plumbing of its own
  (sudo fires on `[a]` in the existing Apply path).
- **Triggers fire at action-completion boundaries, never mid-edit:**
  (1) a plugin install completes, (2) leaving Configure (Esc →
  dashboard) with pending changes. Covers both cases the issue
  names without prompt-fatigue.
- **v1 is just the prompt** — no auto-apply, no "always apply
  immediately" preference, no every-edit firing, no background
  apply.

## Architecture

### State: `applyNowPromptProvider`

```dart
// tui/lib/src/providers/ui_state_provider.dart
class ApplyNowPrompt {
  const ApplyNowPrompt({this.headline});
  /// Optional one-line summary of what just happened, e.g.
  /// "configured blitz-api v0.1.0". Null → the popup shows only
  /// the generic pending-change count (the Configure-exit case).
  final String? headline;
}

final applyNowPromptProvider = StateProvider<ApplyNowPrompt?>((ref) => null);
```

`null` = no popup. Added to `modalActiveProvider`:

```dart
final modalActiveProvider = Provider<bool>((ref) {
  final help = ref.watch(helpVisibleProvider);
  final sudo = ref.watch(pendingSudoPromptProvider);
  final topMenu = ref.watch(topMenuOverlayProvider);
  final applyNow = ref.watch(applyNowPromptProvider);   // new
  return help || sudo != null || topMenu || applyNow != null;
});
```

### The popup: `ApplyNowPopup`

A new `tui/lib/src/ui/widgets/apply_now_popup.dart`, modeled on the
existing confirm/select popups. Rendered as a `Stack` sibling in
`app.dart` (alongside `HelpPopup` / `PasswordOverlay` /
`TopMenuOverlay`), gated on `applyNowPromptProvider != null`:

```
┌─ Apply now? ──────────────────────────────────────┐
│ <headline, if present>                            │
│ N pending change(s).                              │
│                                                   │
│ Applying runs `nixos-rebuild switch` (~2-5 min).  │
│                                                   │
│ [y] Apply now   [n] Keep working                  │
└───────────────────────────────────────────────────┘
```

- Pending count comes from `pendingChangeKeysProvider` (the same
  source the header badge uses). Terse on purpose — the full diff
  is what the review screen shows.
- The popup owns a `Focusable` that only claims keys while it's the
  active modal (consistent with the codebase's modal-gating idiom).

### Actions

- `[y]` → `currentViewProvider = AppView.apply` + clear
  `applyNowPromptProvider`. Lands on the Apply review screen
  (`_ApplyMode.review`); the operator presses `[a]` to commit +
  rebuild via the existing path.
- `[n]` / `Esc` → clear `applyNowPromptProvider`, stay on the
  current view.

**nocterm pitfall (CLAUDE.md #1):** setting a `StateProvider` inside
an `onKeyEvent` handler triggers an immediate rebuild that can
discard the rest of the handler. The `[y]` path sets two providers
(view + clear-prompt); it follows the codebase's existing
multi-provider sequencing pattern (cf. `apply_view._reset`), setting
the prompt-clear and the navigation with no non-provider work
depending on lines after them. The plan verifies this works (popup
must not linger over the Apply view after `[y]`).

### Trigger sites

1. **Plugin install complete** — `plugin_install_view.dart`, at the
   success branch where `_resultMessage = 'configured ${marker.id}
v${marker.version}'` is set today: also set
   `applyNowPromptProvider = ApplyNowPrompt(headline: 'configured
${marker.id} v${marker.version}')`. The operator stays on the
   result screen with the popup overlaid; `[n]` returns them to it,
   `[y]` jumps to Apply.

2. **Leaving Configure with pending changes** —
   `configure_view.dart`, in the Esc→dashboard transition: if
   `pendingChangeKeysProvider` is non-empty, navigate to the
   dashboard as normal **and** set `applyNowPromptProvider =
const ApplyNowPrompt()` (no headline → generic count). The popup
   overlays the dashboard; `[n]` dismisses (operator on dashboard),
   `[y]` → Apply.

Both sites just set the provider; the popup rendering + actions are
centralized in `app.dart` + the widget, so triggers stay one-liners
and there's a single popup implementation.

## Testing

- **Unit (tui):** `ApplyNowPrompt` value semantics; the
  pending-count summary string derived from a `pendingChangeKeys`
  set (extract the summary into a pure helper so it's testable
  without the nocterm widget). Follows the pattern of the existing
  `configure_view_test` helper-level tests.
- **Manual (VM / `just run`):** install a plugin → popup appears →
  `[y]` lands on the Apply review screen with the plugin change
  shown; `[n]` returns to the result screen. Edit a Configure field
  → Esc → popup on the dashboard → `[y]` → review screen. Confirm
  the popup never fires mid-edit, and never lingers over the Apply
  view after `[y]`.
- `just test; just analyze; just format` green.

## Out of scope

- **Auto-apply / skipping the review screen** — explicitly rejected;
  it would re-introduce the silent-apply path the unification killed.
- **"Always apply immediately" preference** — maybe a later
  iteration; v1 is just the prompt.
- **Every-edit firing / 0→1 global crossing detection** — fatigue
  risk; we trigger only at action-completion boundaries.
- **Background apply** — rebuild progress must stay visible.
- **Changing the header badge behavior** — it stays as-is behind
  the popup.
