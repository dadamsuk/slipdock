# Visual design review and proposal

Date: 2026-09-26. Status: all four phases below were implemented the same day (uncommitted); the screenshots in `tmp/design-review/` show the state before the changes. Reviewed against commit `2e072a0` on the dev server, in light and dark themes, at 1440×900 desktop and 390×844 mobile. Screenshots live in `tmp/design-review/` (git-ignored); the proposed-direction mockup is `tmp/design-review/mockup.html`.

## Summary

The app is already coherent: one container language (rounded corners, hairline rings, soft shadows), a consistent chip vocabulary on cards, sensible use of theme tokens, and no obviously broken screens. The gaps are at the system level rather than the screen level. Fixing four things would lift every view at once:

1. **The brand and the accent disagree.** The logo mark, avatar and dark theme are indigo/violet. The light theme's `primary` is orange, so every call to action, progress bar, active tab ring, "today" line and default timeline bar reads as a warning colour. Light and dark look like two different products.
2. **The board header carries too much.** At 1440px the board name truncates to "P.." while the board description gets space. Six view tabs, search, three action buttons, an archive icon, a three-way theme toggle and the avatar all compete on one 48px row. On mobile it collapses to a row of unlabeled icons.
3. **Controls jump between views.** Board view keeps search and filter in the header; the other five views put them in a second toolbar row with a different layout. Switching tabs moves the controls.
4. **No type scale or radius scale.** Sizes 9, 10, 11, 13px are used ad hoc; fields are 4px-radius while containers are 12–16px, so buttons and inputs look like they come from a different kit than the cards around them.

Everything below is in service of those four.

## Palette direction (added later the same day)

The first pass kept a saturated indigo accent and the vivid 500-level Tailwind hues for tags, covers and priorities. On review the whole scheme felt too loud, so it moved to pastels:

- Theme tokens in `app.css` dropped their chroma by roughly half. Light `primary` is a dusty periwinkle (`oklch(56% 0.11 277)`), `success`, `warning`, `error` and `info` are muted mint, butter, coral and sky, and the light base surfaces carry a faint warm tint. Dark mode uses lighter, softer versions of the same hues with dark text on them.
- Primary buttons and badges are soft tints (about 16% primary over the surface) with primary-coloured text, not solid fills. The brand mark and avatar use the same tint.
- `Slipdock.Palette` now maps every named colour to a 300-level dot, a 100-level chip with 700-level text, and a 200-to-200 gradient in light mode, each with a muted 400-level dark variant.
- Priority and flag icons use 600-level hues in light mode and 300-level in dark, and flag toggles fill with 100-level tints.
- Timeline bars take dark text on pastel fills instead of white on saturated ones, and the default and done bars mix primary and success into the surface.

## What already works (keep)

- Card anatomy: tag row, title with a hover-revealed complete toggle, then a wrapped meta row. Cover colour as a thin top strip.
- Column treatment: recessed well (`bg-base-300/60`) with white cards on top gives clear figure/ground in both themes.
- Semantic chip colours: overdue = error tint, done = success tint, WIP-limit reached = warning. Correct, and readable in dark.
- The timeline: derived bars drawn dashed, "today" line, weekend shading, and the unscheduled tray are all clear.
- Dark theme surfaces: the three-step slate scale has enough separation between page, column and card.
- Empty states: icon in a soft tinted square, heading, one line of copy, one action.

## Findings, by impact

### 1. Accent and brand (system-wide)

Evidence: `assets/css/app.css` light theme sets `--color-primary: oklch(70% 0.213 47.604)` (orange). The mark in `layouts.ex` and the login card hard-code `from-indigo-500 to-violet-600`. Dark theme primary is `oklch(58% 0.233 277)` (indigo).

Effect: on light, the "New board" button, "Save", "Share", checklist progress, table sort indicator, timeline default bars, calendar today cell, card hover ring and subcards badge are all orange. Orange is also the WIP-limit and "at risk" colour, so the accent has no meaning.

Proposal:
- One accent in both themes: indigo, `oklch(58% 0.20 277)` light / `oklch(68% 0.18 277)` dark. Reserve amber for warning, rose for error, emerald for success, exactly as the chips already do.
- Brand mark and avatar use `bg-primary` rather than a hard-coded gradient, so the theme owns the brand.
- Secondary stays a neutral slate. Drop `accent: black`; nothing should need a third hue.

### 2. Header and toolbar (board page)

Evidence: `board_live/show.ex` render, `<:nav>` and `<:actions>` slots; `swim_toolbar` in `swimlane_components.ex` for the other views.

Proposal, two fixed rows on every board view:

- **Row 1, 48px, identity and global actions.** Mark, breadcrumb ("Boards / ● Product Launch", with ancestry for sub-boards), then search (with a `/` shortcut hint), Share, avatar. Board description leaves the header; it belongs in settings and as the breadcrumb's tooltip. Theme toggle moves into the avatar menu.
- **Row 2, 44px, view and view-controls.** Segmented control for the six views (one active pill, not six ghost buttons), then the controls for that view (Group/Rows/Columns, Zoom, date nav, Sort, Filter, Display, Views), then card count right-aligned and an overflow menu holding Tags, Activity, Archive, Settings.
- Board view uses the same `swim_toolbar` as the other views (mode `:board`) so nothing moves when tabs change.
- Mobile (< 640px): row 1 becomes back-chevron + board name + overflow; row 2 becomes a horizontally scrollable segmented control with icon+label.

### 3. Type and radius scale

Proposal, expressed as Tailwind v4 `@theme` tokens in `app.css`:

| Token | Value | Use |
|---|---|---|
| `--text-2xs` | 11px / 1.3 | chip labels, counts |
| `--text-xs` | 12px / 1.4 | meta, table headers |
| `--text-sm` | 13.5px / 1.45 | card titles, body |
| `--text-base` | 15px / 1.5 | inputs, modal body |
| `--text-lg` | 17px / 1.4 | section headings |
| `--text-2xl` | 24px / 1.25 | modal title, page h1 |
| `--radius-field` | 8px | inputs, buttons |
| `--radius-box` | 12px | cards, dropdowns, modals |
| `--radius-well` | 16px | columns, page panels |

Also:
- Bundle a UI font. The app forbids external `<link>`s, so vendor a variable WOFF2 (Inter or Geist) into `assets/vendor/` and declare it with `@font-face` in `app.css`, `font-feature-settings: "cv11","ss01"`. Enable `font-variant-numeric: tabular-nums` on counts, dates and the table.
- Remove the `text-[9px]`, `text-[10px]`, `text-[13px]` literals; map them to the scale above.

### 4. Cards

Evidence: `kanban_components.ex` `card/1`.

- Meta row chips come in three shapes: filled pills (due, blocked), outlined pills (later due dates), and bare coloured icons (priority, flags). Make every chip the same 20px-high, 6px-radius unit; icons-only chips are 20×20. Priority gets its own chip with the chevron so it stops floating.
- Completed cards triple-encode: green check, strikethrough, 70% opacity. Keep the check and the opacity; drop the strikethrough on the board (keep it in table/outline where rows are dense).
- Card hover ring uses `ring-primary/40`; after the accent fix that becomes a calm indigo instead of orange.
- Card focus: cards are clickable divs. Give them `tabindex="0"`, `role="button"` and a visible `focus-visible` ring for keyboard users.

### 5. Flash and toasts

Evidence: `core_components.ex` `flash/1`; screenshot `01-home-light.png`, `login.png`.

- The toast is a saturated full-bleed bar pinned top-right, covering the avatar and theme toggle. Move it bottom-left, style it as a surface card (`bg-base-100`, ring, coloured dot or icon), auto-dismiss info after 4s, slide in.
- "Please sign in to continue" is shown as an error on a cold visit. Use the info variant.
- Add an "Undo" affordance in the move/archive/delete toasts; the app already has the events.

### 6. Table view

Evidence: `table_components.ex`; screenshot `05-table-light.png`.

- Every row renders two bordered native selects and a bordered date input, so 13 rows show 39 boxed controls. Render them as text with the field chrome only on hover/focus (`select-ghost`, `input-ghost`), and show dates as "Oct 30" until clicked.
- "4d overdue" wraps to two lines in the Due column: add `whitespace-nowrap` to `due_badge`.
- Sort indicator in the header is `text-primary`; fine after the accent fix.

### 7. Outline view

Evidence: `outline_components.ex`; screenshot `03-outline-light.png`.

- An "On track" pill on every row is noise. Show health pills only for blocked, at-risk and done; leave on-track blank.
- "—" placeholders in Progress and Schedule on most rows: render nothing.
- Add a 1px indent guide per level so depth is readable when rows scroll.

### 8. Card modal

Evidence: `board_live/show.ex` `card_modal/1`; screenshots `08-card-modal-light.png`, `32-card-mobile.png`.

- Title is a single-line `<input>` at `text-2xl`; on mobile it truncates to "Finalise pricing p". Use an auto-growing textarea (the `AutoGrow` hook exists) and `text-xl` below `sm`.
- On mobile, present the modal as a full-height sheet with no outer margin instead of a floating card with 16px gutters.
- The right sidebar uses default daisyUI selects; after the radius change they will match the rest.
- Section headers ("FLAGS", "TAGS", "DESCRIPTION") are good. Give the sidebar the same 24px vertical rhythm as the main column.

### 9. Login

- After the accent fix the button and mark agree. Consider a very soft accent gradient on the page background so the single card is not floating on flat grey.
- daisyUI's default focus on the email input renders as a heavy black double border. Replace with `focus:ring-2 ring-primary/40 border-primary`.

### 10. Contrast and small text

- Meta text at 11px uses `text-base-content/40` and `/50` in several places (placeholders, "hidden by filters", chip labels). Below 12px, use at least `/60` on light and `/65` on dark to stay above 4.5:1.
- The theme toggle's icons at `opacity-75` on `base-300` are borderline; moving the toggle into the menu removes the issue.

### 11. Motion

- Existing `kanban-pop` (140ms) on new forms is good. Add: toast slide-in, modal enter (`scale-95 → 100`, 150ms), dropdown fade, and `sortable-ghost` already covers drag.
- Wrap all of it in `@media (prefers-reduced-motion: no-preference)`.

## Proposed direction (mockup)

`tmp/design-review/40-mockup-proposed.png` renders the two-row header, segmented view switcher, unified chips and a surface-style toast in both themes, using the tokens above. It is a static HTML sketch, not app code.

## Implementation plan

Each phase is independently shippable and keeps `mix precommit` green.

### Phase 1: tokens (small, highest leverage)

Files: `assets/css/app.css`, `lib/slipdock_web/components/layouts.ex`, `lib/slipdock_web/live/login_live/index.ex`.

- Set light `--color-primary` to indigo; align dark. Set `--radius-field: 0.5rem`, `--radius-box: 0.75rem`.
- Add `@theme` type scale and vendored font.
- Replace hard-coded `from-indigo-500 to-violet-600` with `bg-primary` on the mark and avatar.
- Restyle `flash/1`: bottom-left, surface card, auto-dismiss.

### Phase 2: header and toolbar

Files: `lib/slipdock_web/components/layouts.ex`, `lib/slipdock_web/live/board_live/show.ex`, `lib/slipdock_web/components/swimlane_components.ex`.

- Split `Layouts.app` header into the two rows described above; add a `:toolbar` slot.
- Add `mode: :board` to `swim_toolbar` and move board search/filter into it.
- Segmented control component in `core_components.ex` replacing the `join` of `btn-xs` links.
- Move theme toggle into the avatar menu; move Tags/Activity/Archive/Settings into an overflow menu.
- Mobile header variant.

### Phase 3: components

Files: `lib/slipdock_web/components/kanban_components.ex`, `table_components.ex`, `outline_components.ex`, `board_live/show.ex` (modal).

- Unified 20px chip; priority chip; drop strikethrough on board cards; keyboard focus on cards.
- Ghost fields and `whitespace-nowrap` in the table.
- Outline: suppress on-track pills and dash placeholders; indent guides.
- Modal: auto-grow title, mobile sheet.

### Phase 4: polish and audit

- Motion set with reduced-motion guard.
- Contrast pass on every `/40` and `/50` text under 12px.
- Re-capture the screenshot set and compare against `tmp/design-review/`.

## Screenshot index

| File | View |
|---|---|
| `login.png` | Login, light |
| `01-home-light.png` / `20-home-dark.png` | Boards index |
| `02-board-light.png` / `21-board-dark.png` | Board view |
| `03-outline-light.png` | Outline |
| `04-swimlanes-light.png` | Swimlanes |
| `05-table-light.png` / `24-table-dark.png` | Table |
| `06-timeline-light.png` / `23-timeline-dark.png` | Timeline |
| `07-calendar-light.png` | Calendar |
| `08-card-modal-light.png` / `22-card-modal-dark.png` | Card modal |
| `09-work-light.png` | My work (empty state) |
| `10-templates-light.png` | Templates |
| `11-account-light.png`, `12-groups-light.png` | Account, Groups |
| `13-settings-light.png` | Board settings modal |
| `14-filter-open-light.png` | Filter dropdown |
| `30-home-mobile.png`, `31-board-mobile.png`, `32-card-mobile.png` | Mobile, dark |
| `40-mockup-proposed.png` | Proposed direction mockup |
