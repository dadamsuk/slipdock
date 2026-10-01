# Writing one section at a time

A page is addressed by heading: `"Deploy/Rollback"` is the `## Rollback`
under the `# Deploy`. Matching is case-insensitive, and a bare heading name
works when it is unambiguous.

```sh
slipdock page sections <page>                       # every path you may name
slipdock page section <page> Log                    # read one
slipdock page section <page> Log --append "- line"  # add to the end of it
slipdock page section <page> "Deploy/Rollback" --file new.md   # replace it
```

## Why this is the default write

A whole-body edit is a bet that nobody else touched the page while you were
thinking. A section write is not: two writers working on different sections
of the same page never collide, and an append cannot clobber anything at all,
so it takes no `--base-hash` and never refuses.

For an agent keeping a running record — a `## Log` of dated notes, findings
added to an investigation — appending is the whole job, and it costs one
small request instead of sending the document back.

A section runs from its heading to the next heading at the same level or
higher, so replacing `## Rollback` takes its `### …` subsections with it.
That is what "edit the rollback section" means to a person, so it is what it
means here.

## Conventions that make this work

- **One `## Log` section per page** for dated, append-only notes, newest
  last. Then an agent appends and a person does not have to read a diff.
- **Don't rewrite a section you did not author** without saying so in
  `--message`.
- Replacing a section replaces its heading too — read it first if you mean to
  keep the heading you have.
