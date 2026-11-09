[Slipdock — the manual](../manual.md)

## AI tools beside a page

With an AI model set (Account → AI model), **AI tools** at the top of a wiki page, reading or
editing it, opens a panel beside it (full screen on a phone). Each tool asks the model once, on
your own key, and only answers:

- **Summarise**, **Key points** and **Suggest titles**: what they say.
- **Extract actions** lists what the page says someone has to do. **Make a card** beside one
  puts it in the board's first list, linked to the page, as a selection made into a card is.
  It is offered while reading a saved page you can write to.
- **Improve the writing**, while editing, fixes the spelling and grammar and shortens sentences.

Reading, the tools work on the saved page. Editing, they work on what is in the editor, saved
or not, and **Add to the page** puts the answer at the cursor as a paragraph of its own. Nothing
is saved until you save. **Copy** takes it anywhere else.

Encrypted passages are left out and never reach the model. A page over 30,000 characters is
cut there, and the panel says so. Drawings have no tools.

From a shell, `slipdock page ai W-31 summarise` (also `key_points`, `actions`, `titles`,
`improve`); `POST /api/pages/:id/ai {tool}` and the `page_tool` MCP tool do the same. They
need only read access to the page.

---

← [Quick notes](quick-notes.md) · [Contents](../manual.md) · [Keyboard](keyboard.md) →
