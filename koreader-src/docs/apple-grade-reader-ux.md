# Libra 2 Reader UX Doctrine

This profile is designed for a Kobo Libra 2: a 7 inch, 300 PPI E Ink Carta
device with a 1 GHz CPU. The right design target is not a visually rich app; it
is a calm reading appliance that exposes power only when it is useful.

## Sources

- Apple Human Interface Guidelines:
  https://developer.apple.com/design/human-interface-guidelines/
- Apple HIG design principles, refreshed in 2026:
  https://developer.apple.com/design/human-interface-guidelines/design-principles
- Apple HIG typography:
  https://developer.apple.com/design/human-interface-guidelines/typography
- Apple WWDC25 "Design foundations from idea to interface":
  https://developer.apple.com/videos/play/wwdc2025/359/
- Apple WWDC22 "The craft of SwiftUI API design: Progressive disclosure":
  https://developer.apple.com/videos/play/wwdc2022/10059/
- Apple HIG menus:
  https://developer.apple.com/design/human-interface-guidelines/menus
- Apple HIG toolbars:
  https://developer.apple.com/design/human-interface-guidelines/toolbars
- Apple HIG buttons:
  https://developer.apple.com/design/human-interface-guidelines/buttons
- Apple UI Design Dos and Don'ts:
  https://developer.apple.com/design/tips/
- Apple navigation design guidance:
  https://developer.apple.com/videos/play/wwdc2022/10001/
- Apple Books reading flow:
  https://support.apple.com/guide/iphone/read-books-iphc1af7c57/ios
- Apple HIG buttons: 44x44 pt hit regions as the minimum comfortable target.
- Apple layout guidance: primary content should fit the screen without
  horizontal scrolling, controls should sit near the content they affect, and
  hidden content should use progressive disclosure.
- KOReader user guide: the top menu is general navigation and settings; the
  bottom menu is for document appearance; QuickMenu is the fastest path for
  personalized actions.
- Kobo Libra 2 official specs: 1264x1680, 300 PPI E Ink, 32 GB storage, 1 GHz
  CPU, ComfortLight PRO.
- E-ink design guidance:
  https://www.withintent.com/blog/e-ink-design/
- E-paper refresh model:
  https://www.pervasivedisplays.com/how-e-paper-works/fast-update-refresh/
- WCAG 2.2 target size and contrast:
  https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html
  https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html

## 2026 Research Update

Apple's current public design guidance is consistent on one thing: a good app
answers three questions immediately: where am I, what can I do, and where can I
go next. Their 2025 design foundations session also frames design work as
structure, navigation, content organization, and visual design in that order.
For this reader, that means the book page comes first, the top menu is only for
orientation, and the primary actions must not compete with the page.

The HIG's menu and toolbar guidance maps well to KOReader on Kobo. Menus are
space-efficient places for commands that do not deserve constant presence, while
toolbars are grouped controls along an edge of the view. On Libra 2, the
equivalent is not a persistent toolbar because E Ink repaints are expensive; it
is two anchored bottom-corner QuickMenus that appear only when called.

Apple's progressive-disclosure guidance is especially relevant to KOReader
because this codebase has far more capability than a normal reading session
needs. The simple case is: turn pages, open contents, change type/PDF fit,
adjust light, bookmark, and return to the library. Everything else should
compose from secondary menus instead of expanding the primary reading surface.
That same rule applies to code: the simple reader path should not require
history, collections, file search, screenshots, network listeners, dictionary,
Wikipedia, translation, or device-status modules until the user asks for them.

Touch targets must stay generous. Apple's button guidance uses 44x44 pt as the
minimum comfortable hit region, and the Libra 2 profile keeps icon size and
corner gesture zones aligned with that floor. WCAG's smaller 24x24 minimum is a
compliance floor, not the product target; this reader aims for the stricter
touch-device standard because e-ink touch feedback is slower.

E-ink guidance pushes the design further than normal mobile UI: avoid feature
creep, avoid fluid scrolling and rapid screen changes, avoid layered shadows and
animation, avoid keyboard-heavy tasks, and keep the interface simple enough for
slow hardware. That validates hiding dictionaries, translation, network tools,
plugin management, and long-tail settings behind one "More tools" path instead
of leaving them in the first reading surface.

The e-paper refresh model reinforces the same conclusion. Fast updates are
still screen work, and partial updates trade speed against ghosting and
complexity. The best UI is therefore not a more animated UI; it is a UI that
changes less often, changes smaller regions, and avoids repeated background
state updates during steady reading.

Apple Books is the closest mainstream product reference for the reading flow:
the page itself owns the screen, page margins turn pages, a hidden bottom menu
opens contents/search/appearance/bookmark tools, and appearance changes are
grouped behind one themes/settings surface. The Libra 2 profile follows the
same product idea without copying the look: the bottom of the device is the
primary control region, while the top menu is a recovery/orientation surface.

## Product Principles

1. Reading is the product. The page should be almost empty of chrome while a
   book is open.
2. Frequent controls live in the bottom corners because that is the reachable
   one-handed zone on the Libra 2.
3. Secondary controls remain discoverable but hidden under one predictable
   menu path.
4. PDF and EPUB need different power tools, but the entry point should be the
   same: a concise reading QuickMenu.
5. Every extra repaint, settings flush, plugin probe, and network-capable
   feature must justify itself.
6. Labels should describe intent, not implementation. Use "Format", "Contents",
   "Fit", and "Refresh" instead of exposing internal action names.
7. The profile should be self-healing: if a settings file is stale or partly
   corrupt, repair the expected reader surface without rewriting unchanged data.
8. The common-case reader path should have lazy dependencies. If a feature is
   hidden behind "More tools" or a secondary dialog, its Lua module should also
   stay out of startup whenever practical.
9. EPUB and PDF are different engines. Reader startup should delay engine-only
   modules until the document type is known, so opening an EPUB does not load
   PDF/kopt controls and opening a PDF does not load CRE typography controls.
10. Reader side panels should be represented by lightweight menu proxies in the
    normal reading path. History and collections remain discoverable, but their
    full list/search/collection managers should be created only when opened.

## Control Surface

- Right page area: next page.
- Left page edge: previous page.
- Top center: narrower top menu with three tabs only: navigation, typography,
  and main. Settings are one level down in Main, because light/display settings
  already have a faster bottom-corner path.
- Bottom center tap: wider bottom format zone for the full document appearance
  panel.
- Bottom right hold: compact `Reader` QuickMenu for navigation, format,
  bookmarks, and type size.
- Bottom left hold: `Display` QuickMenu for frontlight, PDF reflow, fit width,
  and full refresh.
- File manager bottom right hold: `Library` QuickMenu.
- QuickMenus are anchored near the invoking gesture and use compact width
  factors, so they read as popovers instead of full-screen tool drawers.
- Footer: thin progress bar plus compact percent, time, and battery. Page
  number is kept out of the steady reading chrome because it changes every page
  and adds layout churn; `Page` remains one gesture away.
- Highlighting: long-press is optimized for marking text. Single-word lookup,
  Wikipedia, translate, and search are removed from the first highlight surface.
- Reader main menu: `Open previous document`, `File browser`, `History`,
  `Search`, `More tools`, and `Exit`. Everything else is second-level.
- File manager main menu: `Open last document`, `History`, `Search`,
  `More tools`, and `Exit`. Library management stays reachable but not
  prominent while browsing books.

## Reading QuickMenu

The reader QuickMenu should stay short, anchored near the gesture, and use
single-purpose labels:

- Contents
- Page
- Mark
- Format
- A+
- A-

The display QuickMenu owns lower-frequency visual operations:

- Light
- Reflow
- Fit
- Refresh

These cover the high-frequency reading loop without exposing dictionary,
Wikipedia, translation, plugin management, OPDS, statistics, terminal, or
network tools during normal reading.

Search and skim remain discoverable through the navigation/menu hierarchy, but
they are no longer in the first QuickMenu because they are interruptive tasks:
they change the reader's mode instead of directly continuing the page-turning
loop.

## Apple-Grade Interpretation

- Familiarity: two anchored bottom-corner menus are stable and easy to learn.
- Simplicity: the first reading menu is six commands, not a full tool drawer.
- Agency: every visible command has a direct, predictable effect.
- Progressive disclosure: search, skim, collections, favorites, plugins,
  dictionaries, and network tools stay available behind menus instead of
  occupying the primary reading surface.
- Craft: footer text is stable, labels are short, popovers stay compact, hit
  regions remain at least 44 pt, and no visual treatment is allowed to add
  avoidable e-ink refresh work.

## Information Architecture

Primary while reading:

- Turn pages.
- Open contents or go to a page.
- Change typography or PDF fit.
- Adjust light.
- Bookmark.
- Return to library/history.
- Search.

Secondary:

- Favorites, collections, bookmark browser.
- Book information and status.
- Export/move/text tools.
- Network, language, device, plugin, patch, update, and help surfaces.

This is the Apple-style hierarchy translated to Kobo: the first layer is for
intent, not inventory. The long feature list still exists, but it no longer asks
the reader to scan it during normal reading.

## E Ink Craft Rules

- Prefer static hierarchy over animation.
- Avoid UI flashing except when explicitly refreshing the page.
- Keep controls at or above 44 device-independent points.
- Favor anchored popups and bottom controls to reduce hand travel.
- Avoid repeated settings writes during boot and preflight.
- Skip unchanged footer layout work during steady-state reading; page turns
  already repaint the page, and forced footer repaints still run normally.
- Prefer stable footer text over page-number text so repeated page turns do
  less layout work on E Ink.
- Disable background plugins that do not improve local EPUB/PDF reading.
- Do not instantiate reader-side file search, screenshot, device-status, or
  network listeners in the Libra 2 reading profile unless the feature is
  explicitly requested.
- Do not load both fixed-layout and reflowable-document controller stacks before
  the document type is known.
- Keep history and collections out of the steady reader startup path; expose
  them through proxy menu entries that instantiate the full manager on demand.

## Quality Gate

A UX change is accepted only if it keeps the reading page cleaner, makes a
frequent action faster, hides a rarely used action without making it lost, or
removes CPU, I/O, or repaint work from the steady-state reader.
