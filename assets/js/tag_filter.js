// The card's tag picker (#1727): one box that narrows the list of tags as
// you type, and names a new tag when nothing of that name is there. The list
// is the server's; this only hides and shows its rows, so a patch that ticks
// a tag leaves the narrowing alone (`updated` applies it again).

// Does a tag called `name` match what is typed? Case and surrounding space
// don't count; nothing typed matches everything.
export function matches(name, query) {
  const q = (query || "").trim().toLowerCase()
  return q === "" || name.toLowerCase().includes(q)
}

// What the picker shows for `query` over the tags `names`: which to show,
// whether "No tags match" shows, and the new tag to offer (null when nothing
// is typed or a tag of exactly that name exists).
export function narrow(names, query) {
  const q = (query || "").trim()
  const shown = names.map(n => matches(n, q))
  const exact = names.some(n => n.toLowerCase() === q.toLowerCase())
  return {
    shown,
    none: q !== "" && !shown.some(Boolean),
    offer: q === "" || exact ? null : q,
  }
}

export const TagFilter = {
  mounted() {
    this.input = this.el.querySelector("input[name=name]")
    this.input.addEventListener("input", () => this.apply())
    // After a submit the tag is made (or applied): start again from the
    // whole list. LiveView has read the box by the time this runs.
    this.el.addEventListener("submit", () => setTimeout(() => { this.input.value = ""; this.apply() }, 0))
    this.apply()
  },

  updated() { this.apply() },

  apply() {
    const list = document.getElementById(this.el.dataset.list)
    if (!list) return
    const rows = Array.from(list.querySelectorAll("[data-tag-name]"))
    const {shown, none, offer} = narrow(rows.map(r => r.dataset.tagName), this.input.value)
    rows.forEach((r, i) => { r.hidden = !shown[i] })
    const empty = list.querySelector("[data-role=no-tags]")
    if (empty) empty.hidden = !(none || rows.length === 0)

    const menu = this.el.closest("[popover]") || document
    const create = menu.querySelector("[data-role=new-tag]")
    const manage = menu.querySelector("[data-role=manage-tags]")
    if (create) {
      create.hidden = offer === null
      const label = create.querySelector("[data-role=new-tag-name]")
      if (label) label.textContent = offer || ""
    }
    if (manage) manage.hidden = offer !== null
  },
}
