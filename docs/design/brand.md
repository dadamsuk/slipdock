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
| base-300 (wells, borders) | `#E2EAED` | a step lighter than base-100 |
| base-content (text) | Harbor ink `#10263A` | Mist `#EAF1F3` |
| primary | `#1A6E7C` (Slip teal, a step darker) | `#5FB3C1` (Slip teal light) |
| primary-content | white | Harbor ink |
| accent | Buoy orange `#F26A3A`: the one moving card only | the same |

- Muted text is base-content at `/65` in light; `/60` on white is 4.21:1.
- Primary buttons are solid: primary fill, primary-content label.
- Orange is never a button fill with white text (3.2:1).

## Type

- **Sora 600**, −0.02em tracking, for page titles only.
- **Inter** for everything else, with `cv11` (the single-storey *a*) off.
- **JetBrains Mono** for code, vendored rather than `ui-monospace`.

## Where it is applied

| Part | Card |
|---|---|
| Theme tokens in `assets/css/app.css` | #1702 |
| Button hierarchy | #1703 |
| Checkboxes, toggles, radios | #1704 |
| Fonts and title sizes | #1705 |
