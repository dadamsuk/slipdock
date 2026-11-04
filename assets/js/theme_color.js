// Colours the browser paints outside the page, taken from the theme's tokens
// (#1702) rather than written by hand: the page-loading bar is the primary,
// and the `theme-color` meta (the phone's status bar, a desktop PWA's title
// bar) is the surface the header sits on. Both follow a theme switch.

// A token's value, as app.css sets it for the current theme ("" if unset).
export function token(name, root = document.documentElement, style = getComputedStyle) {
  return style(root).getPropertyValue(`--color-${name}`).trim()
}

// topbar's options: a bar in the primary. A theme with no primary (the
// stylesheet hasn't loaded) keeps topbar's own default rather than drawing
// an invisible bar.
export function topbarOptions(read = token) {
  const primary = read("primary")
  return primary ? {barColors: {0: primary}, shadowBlur: 0} : {shadowBlur: 0}
}

// Points the theme-color meta at base-100, the header's surface. Makes the
// meta when the page has none; leaves it alone when there is no token yet.
export function syncThemeColor(doc = document, read = token) {
  const colour = read("base-100", doc.documentElement)
  if (!colour) return null
  let meta = doc.querySelector('meta[name="theme-color"]')
  if (!meta) {
    meta = doc.createElement("meta")
    meta.setAttribute("name", "theme-color")
    doc.head.appendChild(meta)
  }
  meta.setAttribute("content", colour)
  return colour
}
