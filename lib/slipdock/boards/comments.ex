defmodule Slipdock.Boards.Comments do
  @moduledoc """
  Comments on a card or a wiki page.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Comment
  alias Slipdock.Repo

  ## Comments

  @doc """
  Comments on a card or on a wiki page. `opts[:by]` is who wrote it, when
  known, and is kept as its author; anybody it `@mentions` on a card is told
  (see `Slipdock.Mentions`).
  """
  def add_comment(owner, body, opts \\ []) do
    author = if match?(%Slipdock.Accounts.User{}, opts[:by]), do: opts[:by]

    %Comment{}
    |> struct!(Boards.Shared.owned_by(owner))
    |> struct!(user_id: author && author.id, user: author, kind: opts[:kind])
    |> Comment.changeset(%{"body" => body})
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn comment ->
      # The server's epic lines (#1881) restate events the log already has.
      unless opts[:kind] == Slipdock.EpicLog.kind(),
        do: Boards.Shared.log_owned(owner, "comment", "commented on “#{owner.title}”")

      # A comment is writing too: "see [[Retry policy]]" belongs in that
      # page's backlinks (see `Slipdock.Wiki.Links`).
      Slipdock.Wiki.Links.reconcile_comment(comment)
      Boards.Shared.notify_owned(owner)
      # Automations are about work, so a comment on a page does not run them.
      if match?(%Card{}, owner) do
        Slipdock.Snooze.activity(owner, opts[:by], :comment)
        Slipdock.Mentions.comment_added(owner, comment.body, opts[:by])
        # A closing comment's `Findings:` block is kept (W-2310 §Findings).
        Slipdock.Findings.from_comment(comment, by: author)
        Boards.CardEvents.automate(%{type: "comment_added", card: owner, comment: comment.body})
        # A red build reported on a subcard is a line on its epic (#1881).
        Slipdock.EpicLog.commented(owner, comment.body, comment.kind)
      end
    end)
  end

  @doc "A comment on `owner` (a card or a page), or nil if it is not one of its own."
  def get_comment(owner, id), do: Boards.Shared.get_owned(Comment, owner, id)

  def delete_comment(%Comment{} = comment) do
    Slipdock.Findings.comment_deleted(comment)

    Repo.delete(comment)
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.Shared.notify_owned(Boards.Shared.owner_of(comment))
    end)
  end

  def delete_comment(id), do: delete_comment(Repo.get!(Comment, id))
end
