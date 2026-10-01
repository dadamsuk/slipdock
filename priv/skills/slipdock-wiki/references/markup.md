# Wiki markup

Page bodies are CommonMark plus the GitHub extensions — tables, task lists,
strikethrough, autolinks, footnotes — and the references below.

## References

```
[[Retry policy]]                  a page on this board: title first, then slug
[[retry-policy|how it works]]     the same, with the text to show
[[QVM/Retry policy]]              a page on another board (board code or name)
[[W-31]]  or bare  W-31           a page by its code — survives renames
[[#412]]  or bare  #412           card 412
[[board:QVM]]                     a board
[[view:QVM/Blocked work]]         a saved view
@jess                             someone on the board
```

Bare `#412` is only a card reference when a card with that number exists and
the reader can open it; otherwise it stays literal, so `#1 priority` survives.

A reference inside a code span or a fenced block is never a link. The parser
works on the document's syntax tree, not on its text, so this is a property
rather than a promise.

## Card chips

`#412` is not a snapshot. It is drawn when the page is read, from what the
card says then — its title, its list and whether it is done. A card renamed
or finished after you wrote about it is never stale in your prose, which is
the reason to write `#412` rather than "the card about retries".

## Directives

```
[[!toc]]          a table of contents from this page's headings
[[!children]]     the pages under this one, with their summaries
[[!backlinks]]    everything that links here
```

On a line of their own they become blocks. Backlinks are shown in the page
footer whether or not you ask for them.

## Wanted pages

Linking `[[Rollback procedure]]` before writing it is not a broken link — it
is how the next person finds the work. It renders as an invitation to write
the page, and `slipdock page wanted <board>` lists every one, most-wanted
first. Leaving them deliberately is good practice.

## What is not allowed

Raw HTML is rendered and then sanitised: `<script>`, event handlers and
`javascript:` URLs never survive, whoever wrote them. Plain `<span>`,
`<a href>` and the usual formatting tags do.
