[Slipdock — the manual](../manual.md)

## Google Drive, for meeting recordings

A meeting page can play its recording straight from the owner's Google
Drive, in step with its transcript
([manual](wiki.md#meeting-recordings-from-google-drive)). Nothing is
copied to the server. Each person connects their own Drive, read-only, through
an OAuth client you make once:

1. In Google Cloud, create an **OAuth client ID** of type *Web application*,
   with the redirect URI `https://<your host>/account/google/callback`. It
   must match exactly, scheme and host included: `http://` vs `https://`, a
   port, or `www.` all count, and Google refuses the sign-in otherwise. Enable
   the **Google Drive API** for the project, then set up the consent screen:
   - **On a Google Workspace**, make it **Internal**: it then needs no Google
     verification, and its refresh tokens don't expire.
   - **On a personal Google account** (gmail.com) the consent screen can only
     be **External**. Add the `.../auth/drive.readonly` scope to it, leave it
     in **Testing**, and add yourself (and anyone else who will connect) as a
     **test user**. In Testing, Google expires refresh tokens after **7
     days**, so each person has to connect Drive again weekly; Slipdock says
     so when it happens. `drive.readonly` is a *restricted* scope, so
     publishing the app to everyone needs Google's verification (a security
     assessment). For a single-user or small install, staying in Testing is
     the practical choice.
2. Give the server its id and secret:

   ```sh
   GOOGLE_CLIENT_ID=1234-abc.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=GOCSPX-…
   ```

   Unlike [the seeded settings](running-it-for-other-people.md#settings-the-environment-seeds-them-once), these are read on every start. Unset, the Drive
   connection isn't offered at all.
3. People connect Drive on **Account → Preferences**, and set their wiki's
   recordings folder in Wiki settings (or `slipdock wiki set
   --recordings-folder PATH`).

The scope is `drive.readonly`. Tokens are stored encrypted with a key derived
from `SECRET_KEY_BASE`, so changing that key means everyone connects again. A
wiki's recordings are served through its owner's connection to anyone who can
read the board, and only files under its recordings folder are served. A
draft page's recording is its writers' only, like the draft itself: someone
who can read the board but not write on it gets a 404. A client that holds an
API token plays the same stream from `GET /api/pages/:id/recording`, under the
same rule.

What a meeting page has to look like to play, for whatever records and
transcribes your meetings, is in the manual:
[Meeting transcripts: what Slipdock expects](wiki.md#meeting-transcripts-what-slipdock-expects).

---

← [Receiving email](receiving-email.md) · [Contents](../manual.md) · [As a service](as-a-service.md) →
