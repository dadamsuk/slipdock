[Slipdock — the manual](../manual.md)

## Quick notes

**Quick note instead** in the quick add box (on a laptop), the pencil at the top
right (on a tablet), `Shift-Alt-N`, or **Quick note** in the phone's menu opens a box
to write in, on any page. **Save** (or `Ctrl-Enter`) files it in your wiki and shows
where it went, with a link to the page; the box empties, ready for the next one.

- **The name** is `YYYY-MM-DD HH.MM` in your own timezone, then a few words the AI model
  takes from what you wrote: `2026-10-30 15.39 Printers banner call`.
- **The place** is the folder of your wiki the model thinks fits best, by what the note is
  about. It may add one new folder beneath an existing one, never a new top-level folder, and
  only somewhere you can write. If its first answer can't be used it is asked once more.
- **Your settings** (Account → Preferences → Quick notes) pick a location in your wiki.
  The location is where a note goes when the model can't place it, and the save says so.
  With nothing set, it is the top of your Knowledge Base.
- **No model, or one that fails:** the note is still saved, at your location, named after
  its first words.
- Closing the box keeps what you typed until you leave the page, and a failed save keeps it too.

From a shell, `slipdock note ring the printers` (or `--body -` to read stdin); `POST
/api/notes {text}` and the `quick_note` MCP tool do the same.

---

← [On a phone](on-a-phone.md) · [Contents](../manual.md) · [AI tools beside a page](ai-tools-beside-a-page.md) →
