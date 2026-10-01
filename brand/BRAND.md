# Slipdock brand

Logo assets for slipdock.us. All SVGs are outlined (text converted to paths), so they need no font to render.

## Concept

Kanban columns drawn as dock slips. Finger piers form the columns, cards are moored in the berths, and an orange card is sliding into place. In the wordmark, the orange card replaces the dot of the "i".

## Files

| File | Use |
|---|---|
| `lockup-horizontal.svg` | Primary logo. Site header, docs, anywhere with width. |
| `lockup-horizontal-domain.svg` | Same, reading "slipdock.us". Marketing where the URL matters. |
| `lockup-stacked.svg` | Square-ish spaces: splash screens, social avatars with room. |
| `lockup-reversed.svg` | On dark (navy) backgrounds. |
| `lockup-mono.svg` | Single-colour contexts (print, embossing, one-ink). |
| `wordmark.svg` | Name only, on light backgrounds. |
| `wordmark-reversed.svg` | Name only, on dark backgrounds. |
| `wordmark-mono.svg` | Name only, single colour (navy i-dot). |
| `wordmark-domain.svg` | "slipdock.us" name only. |
| `icon.svg` | Detailed app icon. Use at 48 px and above. |
| `icon-simple.svg` | Simplified icon. Use from 20 px to 47 px. |
| `icon-16.svg` | Simplest icon for 16 px (no teal card). |
| `mark.svg` | The mark with no tile, light-background colours. |
| `favicon.ico` | 16 + 32 px favicon. |
| `favicon-16.png`, `favicon-32.png` | PNG favicons. |
| `icon-180.png` | Apple touch icon. |
| `icon-192.png`, `icon-512.png` | PWA manifest icons. |

## Where these live in this repository

`brand/` is the kit as delivered and the source of truth. The app serves only
what it needs from `priv/static/`: `favicon.ico` at the root, and
`images/brand/` for the icons and lockups referenced by the layout. Those are
copies — change `brand/` first, then copy across, rather than editing one side.

## Rules

- Detailed icon at 48 px and above; simplified icon below 48 px; `icon-16.svg` at 16 px.
- The i-dot is always the orange card, tilted 8 degrees. Never render the wordmark with a normal dot.
- In the one-colour version the i-dot takes the same colour as the letters.
- On navy backgrounds use the reversed lockup (light tile, light wordmark). Do not put the navy tile on navy.
- Keep clear space around the logo equal to the height of the icon tile's corner radius at minimum.

## Colours

| Name | Hex | Use |
|---|---|---|
| Harbor ink | `#10263A` | Primary text, icon tile, dark backgrounds |
| Slip teal | `#1E7F8F` | ".us", secondary accents on light backgrounds |
| Slip teal light | `#5FB3C1` | Teal on dark backgrounds |
| Buoy orange | `#F26A3A` | The moving card, i-dot, primary action accent |
| Mist | `#EAF1F3` | Light surfaces, pier colour on dark |
| Page | `#F3F6F7` | App background |

Orange is a graphic accent. White text on `#F26A3A` is below 4.5:1 contrast; for buttons with white text, darken it (around `#C94F22`) or use ink text.

## Type

- Wordmark: Sora 700, letter-spacing -0.045em; ".us" in Sora 500.
- Sora is on Google Fonts (OFL licence) and on npm as `@fontsource/sora`. It is a reasonable choice for UI headings; pick a body face separately.

## HTML head

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/icon-simple.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/icon-180.png">
<meta name="theme-color" content="#10263A">
```

Source design canvas: https://claude.ai/artifact/KwpThbo2WXDkK4p7YYDVmf (private to the owner).
