
## Every endpoint

```
<%= @endpoints %>
```

`GET /api/guide` takes `?section=short|all|<name>`: the short guide, the
whole one (as with no `section`), or one section by the name the short
guide lists; `?format=json` carries the chosen text in `guide`.

`:board` accepts an id, a board's `code`, or a name. Bodies are documented by the recipes
above; the fields a card accepts on create and update are `title`,
`description`, `priority`, `flags`, `tags`, `add_flags`, `remove_flags`,
`add_tags`, `remove_tags`, `start_date`, `due_date`, `date_precision`,
`completed`, `percent_complete`, `color`, `border_top`, `border_right`,
`border_bottom`, `border_left` (each edge's own palette colour; `""` takes
it off), `column`, `assignee` and `fields`.
Create also takes `archived` (`true` or `"true"`) to file the new card away at
once, a record of something already finished with; update does not, so an
existing card is put away with `POST /api/cards/:id/archive` and brought back
with `POST /api/cards/:id/restore`.
