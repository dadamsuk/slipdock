// <.file_picker> on a plain form post (core_components.ex, #1722). With a
// LiveView upload the server lists the chosen file; on a plain form nothing
// does, so this hook writes the file's name and size into the picker's row
// and its × empties the input again.

// The same words file_size/1 writes on the server: 512 B, 12.5 KB, 3.2 MB.
export function fileSize(bytes) {
  if (typeof bytes !== "number" || !isFinite(bytes) || bytes < 0) return ""
  if (bytes < 1024) return `${bytes} B`
  const round = n => String(Math.round(n * 10) / 10)
  if (bytes < 1024 * 1024) return `${round(bytes / 1024)} KB`
  return `${round(bytes / (1024 * 1024))} MB`
}

// Shows the chosen file (or none) in the picker `el`.
export function show(el, file) {
  const row = el.querySelector("[data-role=file]")
  if (!row) return
  if (file) {
    row.querySelector("[data-role=file-name]").textContent = file.name
    row.querySelector("[data-role=file-size]").textContent = fileSize(file.size)
    row.hidden = false
    el.removeAttribute("data-empty")
  } else {
    row.hidden = true
    el.setAttribute("data-empty", "")
  }
}

export const FilePicker = {
  mounted() {
    this.input = this.el.querySelector("input[type=file]")
    if (!this.input) return
    this.onChange = () => show(this.el, this.input.files && this.input.files[0])
    this.onClick = e => {
      if (!e.target.closest("[data-role=file-remove]")) return
      e.preventDefault()
      this.input.value = ""
      this.input.dispatchEvent(new Event("change", {bubbles: true}))
    }
    this.input.addEventListener("change", this.onChange)
    this.el.addEventListener("click", this.onClick)
    this.onChange()
  },

  updated() { if (this.input) this.onChange() },

  destroyed() {
    if (!this.input) return
    this.input.removeEventListener("change", this.onChange)
    this.el.removeEventListener("click", this.onClick)
  },
}
