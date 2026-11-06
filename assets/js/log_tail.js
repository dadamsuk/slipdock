// A job's live log (#1871) keeps its newest line in view as lines arrive,
// unless the reader has scrolled up to read an earlier one.

// Within this many pixels of the bottom counts as at the bottom.
export const NEAR = 24

export function atBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= NEAR
}

export const LogTail = {
  mounted() {
    this.stuck = true
    this.onScroll = () => { this.stuck = atBottom(this.el) }
    this.el.addEventListener("scroll", this.onScroll)
    this.el.scrollTop = this.el.scrollHeight
  },
  beforeUpdate() { this.stuck = atBottom(this.el) },
  updated() { if (this.stuck) this.el.scrollTop = this.el.scrollHeight },
  destroyed() { this.el.removeEventListener("scroll", this.onScroll) },
}
