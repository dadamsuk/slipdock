[Slipdock — the manual](../manual.md)

## As a service

`deploy/slipdock.service` is a systemd unit template that runs a production
release on boot. It is a template because a few lines are specific to your
machine and everything else is not — the file marks them: `User`/`Group`,
`WorkingDirectory`, the release path in `ExecStart`/`ExecStop`, and the
`EnvironmentFile` path.

```sh
cp .env.example .env            # DATABASE_URL, SECRET_KEY_BASE, PHX_HOST at least
chmod 600 .env
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
sudo cp deploy/slipdock.service /etc/systemd/system/
sudoedit /etc/systemd/system/slipdock.service   # the lines it marks
sudo systemctl daemon-reload
sudo systemctl enable --now slipdock
journalctl -u slipdock -f
```

Rebuild the release and restart the unit to upgrade. It is deliberately not
`mix phx.server`: the development server has a mailbox at `/dev/mailbox` that
shows anybody who can reach it every sign-in link it has sent, Phoenix's debug
error pages, and a `secret_key_base` published in this repository. If you do
run the dev server where other people can reach it, `SLIPDOCK_DEV_TOOLS=false`
turns off the mailbox and the debug pages.

The release listens on every address over plain http. Put a TLS proxy in front
and keep the port itself off the internet. When the server's address is https
(`SLIPDOCK_URL_SCHEME`, https by default in production), the session cookie is
marked `Secure`.

Settings go in `.env`, not in the unit file, so the unit stays the same on every
machine and the thing that differs between them is one file you already have to
protect. Nothing to do with a particular account — mail relay, hostnames,
sign-up rules — belongs in the unit.

---

← [Google Drive, for meeting recordings](google-drive-for-meeting-recordings.md) · [Contents](../manual.md) · [Security notes](security-notes.md) →
