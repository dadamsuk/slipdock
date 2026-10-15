// Dropping a card on a list's column rather than strictly into the list.
//
// Sortable only takes a card where the pointer is over a list of cards, so a
// drop on a list's header, its "Add card" footer, or the empty board under a
// short list used to put the card back where it came from. A list that opts
// in (`data-column-drop` on its Sortable element) makes its whole column a
// target: the column's width, the full height of the board. Over the list
// itself Sortable's own placement stands; anywhere else in the column the
// card goes to the bottom of that list.

// The lists of one Sortable group that take column drops, each with the box
// of its column and of the board area the column stands in.
export function dropZones(doc, group) {
  return Array.from(doc.querySelectorAll(`[data-column-drop][data-group="${group}"]`)).map(list => {
    const column = list.closest(list.dataset.columnDrop) || list
    const area = column.parentElement ? column.parentElement.closest("[data-drop-area]") : null
    const c = column.getBoundingClientRect()
    const a = area ? area.getBoundingClientRect() : c
    return {list, column, rect: {left: c.left, right: c.right, top: a.top, bottom: a.bottom}, listRect: list.getBoundingClientRect()}
  })
}

const inside = (r, x, y) => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom

// The zone whose column is under (x, y), unless the pointer is over a list
// itself, where Sortable already knows where the card goes.
export function zoneAt(zones, x, y) {
  if (x == null || y == null) return null
  if (zones.some(z => inside(z.listRect, x, y))) return null
  return zones.find(z => inside(z.rect, x, y)) || null
}

// What a drag that ended at (x, y) should do instead of what Sortable did:
//   null                — leave Sortable's result alone
//   {cancel: true}      — the card was let go over its own column, so it stays
//   {to: list}          — append it to that list
export function columnDrop({zones, x, y, from, to}) {
  const zone = zoneAt(zones, x, y)
  if (!zone) return null
  if (zone.list === from) return to === from ? null : {cancel: true}
  return {to: zone.list}
}

// Where the pointer is, from a mouse, pen or touch event.
export function pointOf(e) {
  const t = (e.touches && e.touches[0]) || (e.changedTouches && e.changedTouches[0]) || e
  return {x: t.clientX, y: t.clientY}
}
