# Working on Slipdock

These are the rules for working in this repository, for people and coding
agents alike. How to set it up and run the checks is in `CONTRIBUTING.md`;
Elixir and Phoenix conventions are in `AGENTS.md`. The project handbook
(W-1943 on the maintainers' `slipdock` board, testing and shipping in W-1950)
holds the detail behind each rule.

## The rules

1. **Tests come with the code, as much as its risk asks**, in the same
   commit, asserting what happens. Security, permissions, data loss and
   money: the error and edge cases too. Other features and fixes: the happy
   path and the errors a person would meet. UI notices, copy and flash
   wording need no test of their own. W-1950 §Tests has the tiers. If
   something can't be tested, say why on the card. A refactor that changes
   no behaviour is covered by the tests already there. **The second time a
   kind of problem turns up, fix the kind**: one shared mechanism and a check
   that fails CI if it comes back, not a fix and a card per instance.
2. **Change every place a feature shows up**, or say on the card why not.
   The places are listed, with their paths, in `CONTRIBUTING.md` §Where a
   feature shows up: that is the one list, so read it there rather than
   from memory.
3. **Edit the skills only in `priv/skills/`.** Installed copies (such as
   `~/.claude/skills`) are overwritten from the server, so an edit there is
   lost.
4. **Run `mix pre_push` before you push**, and say on the card that it
   passed. It runs the static checks, the format and compile checks, the
   daemon's `go vet` and `go test -race`, and the repo's own rule tests; a
   pull request's CI doesn't run the static checks, so this is where a change
   meets them first. It takes no test files: run your tests yourself with
   `mix test <the files you changed>` in another terminal while it runs, a
   few files, not a whole directory (a directory's run at the same time can
   time out). It takes about 4 minutes. Its only options, `--prune` and
   `--from-git-ref <ref>`, and its workings are in `CONTRIBUTING.md`
   §More about `mix pre_push`.
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
