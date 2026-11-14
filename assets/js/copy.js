// Copying text to the clipboard and saying so (#2887): the one place the
// "Copied" confirmation is written, for the CopyText and CopyLink hooks and
// the wiki tree's Copy link.
//
// The confirmation goes where the element shows its words: its [data-label]
// child, and its tooltip when it has one (data-tip, as the wiki's page code
// does, #1743). Each is put back after COPIED_MS.

export const COPIED_MS = 1500
export const COPIED = "Copied"

// Copies `text`, then says "Copied" on `el` for a moment. Resolves true once
// copied, false where there is no clipboard (an insecure origin, an old
// browser) or the write is refused; the words are left alone then, so the
// button never claims a copy that didn't happen.
export function copyWithFeedback(el, text, clipboard = globalThis.navigator?.clipboard) {
  if (!clipboard) return Promise.resolve(false)
  // Written now, not in a later tick: the browser lets a page write the
  // clipboard only while it is handling the click.
  let written
  try { written = clipboard.writeText(text) } catch (_e) { return Promise.resolve(false) }
  return Promise.resolve(written).then(() => { confirmCopied(el); return true }, () => false)
}

// Says "Copied" on `el` for COPIED_MS. A second copy while it still says so
// leaves it be, so the first one's timer puts back the real words rather
// than a second timer putting back "Copied".
export function confirmCopied(el) {
  if (!el) return
  if (el.dataset && el.dataset.tip !== undefined && el.dataset.tip !== COPIED) {
    const tip = el.dataset.tip
    el.dataset.tip = COPIED
    setTimeout(() => { el.dataset.tip = tip }, COPIED_MS)
  }
  const label = el.querySelector?.("[data-label]")
  if (!label || label.textContent === COPIED) return
  const old = label.textContent
  label.textContent = COPIED
  setTimeout(() => { label.textContent = old }, COPIED_MS)
}
