defmodule Slipdock.TransferLinks do
  @moduledoc """
  Short-lived, single-use URLs for moving a file without an API token or the
  bytes passing through a model (#1147).

  An agent with a shell asks for one over MCP (`upload_file` or
  `download_file` with `link: true`) and hands it to curl. The link reaches
  one card or page (an upload) or one attachment (a download), works once,
  and is gone after `ttl_seconds/0`, whichever comes first. It acts as the
  token that minted it: that token's scope and its user's access are checked
  again when it is used, and deleting the token deletes its links.

  A use that is refused (a sha256 that doesn't match, a missing file) hands
  the link back, so the caller can fix the request and try again until it
  expires; only a use that succeeds spends it.
  """
  import Ecto.Query

  alias Slipdock.Accounts.{User, UserToken}
  alias Slipdock.Boards.{Attachment, Card}
  alias Slipdock.Repo
  alias Slipdock.TransferLinks.Link
  alias Slipdock.Wiki.Page

  @ttl_seconds 10 * 60

  @doc "How long a link lasts unused, in seconds."
  def ttl_seconds, do: @ttl_seconds

  @doc """
  A new link for `target` — `{:card, card}` or `{:page, page}` to upload to,
  `{:attachment, attachment}` to download — acting as `user` with
  `user_token`. Returns `{:ok, secret, expires_at}`; the secret goes in the
  URL and is not kept.
  """
  def mint(%User{} = user, %UserToken{} = user_token, target) do
    sweep()
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    expires_at = DateTime.add(DateTime.utc_now(:second), @ttl_seconds)

    attrs =
      Map.merge(target_attrs(target), %{
        token_hash: hash(secret),
        user_id: user.id,
        user_token_id: user_token.id,
        expires_at: expires_at
      })

    {:ok, _link} = Repo.insert(struct(Link, attrs))
    {:ok, secret, expires_at}
  end

  defp target_attrs({:card, %Card{id: id}}), do: %{kind: "upload", card_id: id}
  defp target_attrs({:page, %Page{id: id}}), do: %{kind: "upload", page_id: id}

  defp target_attrs({:attachment, %Attachment{id: id}}),
    do: %{kind: "download", attachment_id: id}

  @doc """
  Spends the `kind` ("upload" or "download") link `secret` names, if it is
  unused, unexpired, and its token and user are still good. Returns the link
  with its user, token and target loaded, or `{:error, :gone}` for every
  other case alike: a guess learns nothing about which.
  """
  def claim(secret, kind) when is_binary(secret) and kind in ["upload", "download"] do
    now = DateTime.utc_now(:second)

    query =
      from(l in Link,
        where: l.token_hash == ^hash(secret) and l.kind == ^kind,
        where: is_nil(l.used_at) and l.expires_at > ^now,
        select: l
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, [link]} ->
        link = Repo.preload(link, [:user, :user_token, :card, :page, attachment: [:card, :page]])

        if usable?(link, now), do: {:ok, link}, else: {:error, :gone}

      _ ->
        {:error, :gone}
    end
  end

  def claim(_secret, _kind), do: {:error, :gone}

  defp usable?(%Link{user: %User{disabled_at: nil}, user_token: %UserToken{} = token}, now),
    do:
      token.context == "api" and
        (is_nil(token.expires_at) or DateTime.after?(token.expires_at, now))

  defp usable?(_link, _now), do: false

  @doc "Hands a claimed link back, for a use that was refused, until it expires."
  def release(%Link{id: id}) do
    from(l in Link, where: l.id == ^id) |> Repo.update_all(set: [used_at: nil])
    :ok
  end

  # Links past their time are no use to anybody; dropped whenever one is made.
  defp sweep do
    now = DateTime.utc_now(:second)
    from(l in Link, where: l.expires_at <= ^now) |> Repo.delete_all()
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
