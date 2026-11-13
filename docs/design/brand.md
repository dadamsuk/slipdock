# Brand system: the decision

Chosen 2026-11-04 for epic #1700 (Brand system 1, #1701). The full record, with
the alternatives and why not, is the wiki page **W-2307** (*Decision: Slip teal
primary, Sora page titles, JetBrains Mono*). The side-by-side comparison is
**W-2305**. The kit itself is `brand/BRAND.md`.

## Palette: option A, Slip teal

| Token | Light | Dark |
|---|---|---|
| base-100 (cards, panels) | `#FFFFFF` | `#16304A` |
| base-200 (page ground) | Page `#F3F6F7` | Harbor ink `#10263A` |
| base-300 (wells, borders) | `#E2EAED` | `#0A1B2A`, a step below the ground |
| base-content (text) | Harbor ink `#10263A` | Mist `#EAF1F3` |
| primary | `#1A6E7C` (Slip teal, a step darker) | `#5FB3C1` (Slip teal light) |
| primary-content | white | ink `#0B1D2C` |
| accent | Buoy orange `#F26A3A`: the one moving card only | the same |

- Muted text is base-content at `/65` in light; `/60` on white is 4.21:1.
- Buttons (#1703): `btn-primary` is solid (primary fill, primary-content
  label), one per form; `btn-secondary` the soft teal tint; plain `btn` a
  hairline on base-100 for Cancel and Back; `btn-ghost` tertiary;
  `btn-ghost btn-error` destructive, behind `data-confirm`. `btn-outline` is
  not used.
- Orange is never a button fill with white text (3.2:1).

## Type

- **Sora 600**, −0.02em tracking, for page titles only: the `page-title`
  class, 24px (28px from `sm`), on every page's `h1` and in `<.page_header>`.
- **Inter** for everything else, with `cv11` (the single-storey *a*) off.
  Headings inside a page or a modal are `section-title`, 18px semibold.
- **JetBrains Mono** for code (`font-mono`, `field-mono`, `code`): the
  `--font-mono` token. No other mono family is written anywhere.
- All three are vendored under `priv/static/fonts` (latin subsets of the
  weight axis from `@fontsource-variable` 5.3.0), each with its OFL licence
  beside it. Checked by `test/slipdock_web/fonts_test.exs` and, in
  Chromium, `tools/e2e/fonts.sh` (#1705).

## Where it is applied

| Part | Card | Pull request | Checked by |
|---|---|---|---|
| The decision | #1701 | #18 | wiki W-2307 |
| Theme tokens in `assets/css/app.css` | #1702 | #19 | `design_tokens_test.exs`, `tools/e2e/brand-tokens.sh` |
| Button hierarchy | #1703 | #21 | `buttons_test.exs`, `tools/e2e/buttons.sh` |
| Checkboxes, toggles, radios | #1704 | #17 | `controls_test.exs`, `tools/e2e/controls.sh` |
| Fonts and title sizes | #1705 | #23 | `fonts_test.exs`, `tools/e2e/fonts.sh` |

All five are on `main`. The handbook's account of the system is W-1946
(UX & UI) §Styling and §Design system, and W-1947 (Components) §Core.
