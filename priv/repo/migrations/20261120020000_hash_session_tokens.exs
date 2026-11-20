defmodule Slipdock.Repo.Migrations.HashSessionTokens do
  use Ecto.Migration

  # Session tokens are stored as their SHA-256 digest from now on, like the
  # other tokens; the cookie keeps the raw token (#3503). The rows already
  # there are digested in place, so the sessions they stand for carry on:
  # Postgres's own `sha256(bytea)` gives the same bytes as
  # `Slipdock.Accounts.UserToken.session_digest/1`.
  #
  # There is no way back to the raw tokens, so going down ends every browser
  # session instead (everyone signs in again).
  def up, do: execute(rehash())

  def down, do: execute("DELETE FROM users_tokens WHERE context = 'session'")

  def rehash, do: "UPDATE users_tokens SET token = sha256(token) WHERE context = 'session'"
end
