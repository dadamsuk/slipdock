# Working on Slipdock

These are the rules for working in this repository, for people and coding
agents alike. How to set it up and run the checks is in `CONTRIBUTING.md`;
Elixir and Phoenix conventions are in `AGENTS.md`. The project handbook
(W-1943 on the maintainers' `slipdock` board, testing and shipping in W-1950)
holds the detail behind each rule.

## The rules

1. **Tests come with the code**, in the same commit: the error and edge cases
   too, asserting what happens. If something can't be tested, say why on the
   card. A refactor that changes no behaviour is covered by the tests already
   there.
2. **Change every place a feature shows up**, or say on the card why not. The
   same feature usually lives in the web UI, the REST API, the CLI (`cli/`)
   and the MCP tools (`lib/slipdock_web/mcp/tools/`), and is described in the
   agents page and API guide (`docs/agents.md`; the guide's prose is a Markdown
   file per section in `lib/slipdock_web/api_guide/`, compiled in by
   `lib/slipdock_web/api_guide.ex`, and a change to it regenerates the copy
   `test/slipdock_web/api_guide_golden_test.exs` holds it to),
   the in-app help (`HelpLive`), the packaged skills (`priv/skills/`), the
   `README.md` and the manual (`docs/manual.md`, a page per section in
   `docs/manual/`). The README is the overview (#2792): a feature gets a line
   and a link there at most, its paragraph goes in
   `docs/manual/every-feature-in-brief.md` and its detail in its manual page.
3. **Edit the skills only in `priv/skills/`.** Installed copies (such as
   `~/.claude/skills`) are overwritten from the server, so an edit there is
   lost.
4. **Run `mix pre_push` before you push**, and say on the card that it
   passed. It runs the static checks, the format and compile checks and the
   repo's own rule tests; a pull request's CI doesn't run the static checks,
   so this is where a change meets them first. It takes a few minutes, so
   start it beside the tests you changed. Its options and its workings are in
   `CONTRIBUTING.md` §More about `mix pre_push`.
5. **Ship the way the card's board says.** Commit with the card's id in the
   message (`#123`). By push (the default), push to `main`, which deploys. By
   pull request, push the branch `card-<id>`, open a PR and give its URL when
   completing the card; never push to `main`. The PR's CI is the full suite:
   before pushing, run the tests you added or changed and `mix pre_push`, not
   the whole suite.
6. **Write down what you learn in the handbook**, not in an agent's own
   memory, which nobody else can read. Read the sections a card needs before
   building, update them before closing it, and say so in a `Handbook:` line
   in the closing comment.
7. **Keep it impersonal: this repository is public.** No real names, email
   addresses, hostnames, IP addresses or tokens in code, tests, docs or commit
   messages; tests use `example.com`. `test/slipdock/nothing_personal_test.exs`
   checks it.
