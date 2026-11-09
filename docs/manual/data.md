[Slipdock — the manual](../manual.md)

## Data

Everything lives in Postgres — the `slipdock_dev` database on the server in
`compose.dev.yaml` unless `DATABASE_URL` says otherwise. `mix ecto.reset` wipes
it and re-runs
`priv/repo/seeds.exs`, which builds the demo workspace (`Slipdock.Demo`) on an
empty database: two boards, an epic with subcards, a scoring scheme, a wiki and
an automation, all on `example.com` addresses. `mix slipdock.demo` builds the
same thing on demand (`--force` to add it to a database that already has
boards), and `tools/screenshots.sh` is what photographs it for the README.

---

← [Licence](licence.md) · [Contents](../manual.md) · [JSON API](json-api.md) →
