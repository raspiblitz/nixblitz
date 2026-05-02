/// Shared branding constants for the TUI. The website renders the
/// same figlet but maintains its own duplicate copy in
/// `website/lib/pages/home_page.dart` because build_web_compilers
/// can't compile this package's web-incompatible transitive imports
/// (services in `common.dart` reach for `dart:io`). Update both
/// copies in lockstep when the wordmark changes.
library;

/// `figlet -f "ANSI Shadow" NIXBLITZ`. Six lines, 56 columns wide.
/// Used as the install / setup wizards' header. Kept as a single
/// literal so the layout is exactly what figlet emits — never
/// reformat or trim.
///
/// Width budget: 56 cols fits in any 80-column terminal with margin.
/// Anything narrower (mobile SSH, embedded console) will clip on the
/// right; the surface that renders the banner can hide it on small
/// viewports if that becomes a real problem.
const String nixblitzAsciiBanner = r'''
███╗   ██╗██╗██╗  ██╗██████╗ ██╗     ██╗████████╗███████╗
████╗  ██║██║╚██╗██╔╝██╔══██╗██║     ██║╚══██╔══╝╚══███╔╝
██╔██╗ ██║██║ ╚███╔╝ ██████╔╝██║     ██║   ██║     ███╔╝
██║╚██╗██║██║ ██╔██╗ ██╔══██╗██║     ██║   ██║    ███╔╝
██║ ╚████║██║██╔╝ ██╗██████╔╝███████╗██║   ██║   ███████╗
╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝   ╚═╝   ╚══════╝
''';

/// Width of [nixblitzAsciiBanner] in display columns. Useful for
/// `if terminal_cols < nixblitzAsciiBannerWidth then skip` guards.
const int nixblitzAsciiBannerWidth = 56;
