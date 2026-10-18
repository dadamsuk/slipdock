defmodule Slipdock.Gardener.Steps do
  @moduledoc """
  The fixed vocabulary a gardener suggestion is written in (W-1807), and how
  each step is applied and undone.

  A step is a string-keyed map with an `"op"`:

    * `complete` `%{"card"}` – mark it complete
    * `move` `%{"card", "column"}` – into that list; `"index"` (default the
      top) is where in it
    * `archive` `%{"card"}` or `%{"page"}` – put it away
    * `link_duplicate` `%{"card", "other"}` – link `card` as a duplicate of `other`
    * `flag` `%{"card", "flag"}` – set a flag
    * `comment` `%{"card", "body"}` – comment, as the person applying it
    * `snooze` `%{"card", "until"}` – snooze it (a date, or a phrase quick add reads)
    * `redate` `%{"card", "due"}` – give it a new due date (ISO 8601, or nil)
    * `rewrite_link` `%{"page", "from", "to"}` – point `[[from]]` at `[[to]]`
    * `file_page` `%{"page", "folder"}` – into that folder (nil: out of any)

  A card id may be `"pick"`, with the candidates in `"from"`: the person
  chooses which when applying (`:keep` names the one that stays, so `"pick"`
  is the other) — how a duplicate's loser is chosen.

  Every step goes through the ordinary `Slipdock.Boards`, `Slipdock.Wiki`
  and `Slipdock.Snooze` functions, so activity, automations and permissions
  are what they always are. Applying one returns the steps that undo it —
  the same vocabulary plus `reopen`, `restore`, `unlink`, `unflag`,
  `uncomment`, `wake` and `set_body` — each carrying what it expects to find,
  so undoing after somebody has moved on refuses rather than clobbering.
  """

  import Ecto.Query

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Boards.{Card, CardLink, Column, Comment}
  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.Page

  @ops ~w(complete move archive link_duplicate flag comment snooze redate rewrite_link file_page)

  @doc "The ops a proposal may use."
  def ops, do: @ops

  @doc """
  Resolves `"pick"` in `steps` with `keep` (the card that stays). Steps with
  no pick come back as they are. `{:ok, steps}`, or `{:error, reason}` when
  a pick is needed and `keep` isn't one of its candidates.
  """
  def resolve_picks(steps, keep) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case step do
        %{"card" => "pick", "from" => from} ->
          keep = to_int(keep)

          if keep in from do
            [other] = from -- [keep]
            {:cont, {:ok, [Map.put(step, "card", other) |> Map.delete("from") | acc]}}
          else
            {:halt,
             {:error, "say which card to keep: one of #{Enum.map_join(from, ", ", &"##{&1}")}"}}
          end

        step ->
          {:cont, {:ok, [step | acc]}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  @doc "Whether `steps` still have a `\"pick\"` in them."
  def needs_pick?(steps), do: Enum.any?(steps, &match?(%{"card" => "pick"}, &1))

  @doc """
  Whether `user` may take every step: write access to each card and page
  they touch. `:ok` or `{:error, :forbidden}`.
  """
  def authorize(steps, user) do
    allowed? =
      Enum.all?(steps, fn step ->
        Enum.all?(subjects(step), fn
          {:card, id} -> with_card(id, &Access.can_write?(Access.card_permission(user, &1)))
          {:page, id} -> with_page(id, &Access.can_write?(Access.page_permission(user, &1)))
        end)
      end)

    if allowed?, do: :ok, else: {:error, :forbidden}
  end

  defp with_card(id, fun), do: (card = Repo.get(Card, id)) && fun.(card)
  defp with_page(id, fun), do: (page = Repo.get(Page, id)) && fun.(page)

  @doc "The cards and pages a step touches, as `{:card, id}` / `{:page, id}`."
  def subjects(step) do
    cards = for k <- ["card", "other"], id = step[k], is_integer(id), do: {:card, id}
    pages = for id <- [step["page"]], is_integer(id), do: {:page, id}
    cards ++ pages
  end

  @doc """
  Takes `steps` in order, as `user`. `{:ok, inverse}` — the steps that undo
  them all, already in the order to run them — or `{:error, reason}`, after
  undoing whatever had already been done.
  """
  def apply_all(steps, user) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, done} ->
      case apply_step(step, user) do
        {:ok, inverse} ->
          {:cont, {:ok, inverse ++ done}}

        {:error, reason} ->
          _ = undo_all(done, user, force: true)
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Runs inverse steps (from `apply_all/2`) in order, as `user`. Each first
  checks that what it undoes is still as it was left, and the whole undo is
  refused, before anything is changed, when one isn't: `{:error, reason}`.
  `force: true` skips that, for unwinding a half-applied suggestion.
  """
  def undo_all(inverse, user, opts \\ []) do
    with :ok <- if(opts[:force], do: :ok, else: check_all(inverse)) do
      Enum.reduce_while(inverse, :ok, fn step, :ok ->
        case apply_step(step, user) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp check_all(inverse) do
    Enum.reduce_while(inverse, :ok, fn step, :ok ->
      case expect(step) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  ## Applying -------------------------------------------------------------------

  defp apply_step(%{"op" => "complete", "card" => id}, user) do
    with {:ok, card} <- card(id) do
      if card.completed do
        {:ok, []}
      else
        with {:ok, _} <- Boards.update_card(card, %{"completed" => true}, by: user),
             do: {:ok, [%{"op" => "reopen", "card" => id}]}
      end
    end
  end

  defp apply_step(%{"op" => "reopen", "card" => id}, user) do
    with {:ok, card} <- card(id),
         {:ok, _} <- Boards.update_card(card, %{"completed" => false}, by: user),
         do: {:ok, []}
  end

  defp apply_step(%{"op" => "move", "card" => id, "column" => column_id} = step, _user) do
    with {:ok, card} <- card(id),
         {:ok, column} <- column(column_id) do
      from = card.column_id
      index = index_in(card)

      case Boards.move_card_to_index(card, column, step["index"] || :top) do
        :ok ->
          {:ok,
           [
             %{
               "op" => "move",
               "card" => id,
               "column" => from,
               "index" => index,
               "expect" => column_id
             }
           ]}

        {:error, :wrong_board} ->
          {:error, "that list is on another board"}
      end
    end
  end

  defp apply_step(%{"op" => "archive", "card" => id}, _user) do
    with {:ok, card} <- card(id) do
      if card.archived_at do
        {:ok, []}
      else
        with {:ok, _} <- Boards.archive_card(card),
             do: {:ok, [%{"op" => "restore", "card" => id}]}
      end
    end
  end

  defp apply_step(%{"op" => "archive", "page" => id}, _user) do
    with {:ok, page} <- page(id) do
      if page.archived_at do
        {:ok, []}
      else
        with {:ok, _} <- Wiki.archive_page(page), do: {:ok, [%{"op" => "restore", "page" => id}]}
      end
    end
  end

  defp apply_step(%{"op" => "restore", "card" => id}, _user) do
    with {:ok, card} <- card(id), {:ok, _} <- Boards.unarchive_card(card), do: {:ok, []}
  end

  defp apply_step(%{"op" => "restore", "page" => id}, _user) do
    with {:ok, page} <- page(id), {:ok, _} <- Wiki.unarchive_page(page), do: {:ok, []}
  end

  defp apply_step(%{"op" => "link_duplicate", "card" => id, "other" => other_id}, _user) do
    with {:ok, card} <- card(id),
         {:ok, other} <- card(other_id),
         {:ok, link} <- Boards.add_link(card, other, "duplicates"),
         do: {:ok, [%{"op" => "unlink", "link" => link.id}]}
  end

  defp apply_step(%{"op" => "unlink", "link" => id}, _user) do
    case Repo.get(CardLink, id) do
      nil -> {:ok, []}
      link -> with {:ok, _} <- Boards.remove_link(link), do: {:ok, []}
    end
  end

  defp apply_step(%{"op" => "flag", "card" => id, "flag" => flag}, user) do
    with {:ok, card} <- card(id) do
      if flag in card.flags do
        {:ok, []}
      else
        with {:ok, _} <- Boards.update_card(card, %{"flags" => card.flags ++ [flag]}, by: user),
             do: {:ok, [%{"op" => "unflag", "card" => id, "flag" => flag}]}
      end
    end
  end

  defp apply_step(%{"op" => "unflag", "card" => id, "flag" => flag}, user) do
    with {:ok, card} <- card(id),
         {:ok, _} <-
           Boards.update_card(card, %{"flags" => List.delete(card.flags, flag)}, by: user),
         do: {:ok, []}
  end

  defp apply_step(%{"op" => "comment", "card" => id, "body" => body}, user) do
    with {:ok, card} <- card(id),
         {:ok, comment} <- Boards.add_comment(card, body, by: user),
         do: {:ok, [%{"op" => "uncomment", "comment" => comment.id}]}
  end

  defp apply_step(%{"op" => "uncomment", "comment" => id}, _user) do
    case Repo.get(Comment, id) do
      nil -> {:ok, []}
      comment -> with {:ok, _} <- Boards.delete_comment(comment), do: {:ok, []}
    end
  end

  defp apply_step(%{"op" => "snooze", "card" => id, "until" => until}, user) do
    with {:ok, card} <- card(id) do
      case Slipdock.Snooze.snooze(card, user, until) do
        {:ok, _} -> {:ok, [%{"op" => "wake", "card" => id}]}
        {:error, reason} -> {:error, Slipdock.Snooze.error_message(reason)}
      end
    end
  end

  defp apply_step(%{"op" => "wake", "card" => id}, user) do
    with {:ok, card} <- card(id) do
      case Slipdock.Snooze.wake(card, by: user) do
        {:ok, _} -> {:ok, []}
        {:error, :not_snoozed} -> {:ok, []}
      end
    end
  end

  defp apply_step(%{"op" => "redate", "card" => id, "due" => due}, user) do
    with {:ok, card} <- card(id) do
      from = card.due_date && Date.to_iso8601(card.due_date)

      case Boards.update_card(card, %{"due_date" => due}, by: user) do
        {:ok, updated} ->
          to = updated.due_date && Date.to_iso8601(updated.due_date)
          {:ok, [%{"op" => "redate", "card" => id, "due" => from, "expect" => to}]}

        {:error, cs} ->
          {:error, describe_error(cs)}
      end
    end
  end

  defp apply_step(%{"op" => "rewrite_link", "page" => id, "from" => from, "to" => to}, user) do
    with {:ok, page} <- page(id) do
      body = rewrite(page.body, from, to)

      if body == page.body do
        {:error, "“#{page.title}” no longer links to [[#{from}]]"}
      else
        with {:ok, saved} <- save_body(page, body, user),
             do:
               {:ok,
                [
                  %{
                    "op" => "set_body",
                    "page" => id,
                    "body" => page.body,
                    "expect" => saved.content_hash
                  }
                ]}
      end
    end
  end

  defp apply_step(%{"op" => "set_body", "page" => id, "body" => body}, user) do
    with {:ok, page} <- page(id), {:ok, _} <- save_body(page, body, user), do: {:ok, []}
  end

  defp apply_step(%{"op" => "file_page", "page" => id, "folder" => folder_id}, user) do
    with {:ok, page} <- page(id) do
      from = page.folder_id

      case Wiki.update_page(page, %{"folder_id" => folder_id}, user: user, via: "gardener") do
        {:ok, _} ->
          {:ok, [%{"op" => "file_page", "page" => id, "folder" => from, "expect" => folder_id}]}

        {:error, reason} ->
          {:error, describe_error(reason)}
      end
    end
  end

  defp apply_step(%{"op" => op}, _user), do: {:error, "unknown step “#{op}”"}
  defp apply_step(_step, _user), do: {:error, "a step needs an op"}

  defp save_body(page, body, user) do
    case Wiki.update_page(page, %{"body" => body}, user: user, via: "gardener") do
      {:ok, saved} -> {:ok, saved}
      {:error, reason} -> {:error, describe_error(reason)}
      {:error, :conflict, _} -> {:error, "the page changed while it was being saved"}
    end
  end

  defp describe_error(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k} #{Enum.join(List.wrap(v), ", ")}" end)
  end

  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  @doc """
  `body` with every `[[from]]` link pointing at `to` instead, keeping any
  `#heading` and `|label`. Matching ignores case, as resolving does.
  """
  def rewrite(body, from, to) when is_binary(body) do
    pattern = ~r/\[\[\s*#{Regex.escape(from)}\s*(?=[\]#|])/iu
    Regex.replace(pattern, body, "[[" <> to)
  end

  def rewrite(nil, _from, _to), do: nil

  ## What an undo expects -------------------------------------------------------

  defp expect(%{"op" => "reopen", "card" => id}) do
    with {:ok, card} <- card(id),
         do: if(card.completed, do: :ok, else: changed(card, "has been reopened since"))
  end

  defp expect(%{"op" => "move", "card" => id, "expect" => column_id}) do
    with {:ok, card} <- card(id) do
      if card.column_id == column_id,
        do: :ok,
        else: changed(card, "has been moved to another list since")
    end
  end

  defp expect(%{"op" => "redate", "card" => id, "expect" => due}) do
    with {:ok, card} <- card(id) do
      if (card.due_date && Date.to_iso8601(card.due_date)) == due,
        do: :ok,
        else: changed(card, "has been given another due date since")
    end
  end

  defp expect(%{"op" => "restore", "card" => id}) do
    with {:ok, card} <- card(id),
         do: if(card.archived_at, do: :ok, else: changed(card, "has been restored since"))
  end

  defp expect(%{"op" => "restore", "page" => id}) do
    with {:ok, page} <- page(id),
         do:
           if(page.archived_at,
             do: :ok,
             else: {:error, "“#{page.title}” has been restored since"}
           )
  end

  defp expect(%{"op" => "unflag", "card" => id, "flag" => flag}) do
    with {:ok, card} <- card(id),
         do:
           if(flag in card.flags, do: :ok, else: changed(card, "has lost its #{flag} flag since"))
  end

  defp expect(%{"op" => "wake", "card" => id}) do
    with {:ok, card} <- card(id),
         do: if(card.snoozed_until, do: :ok, else: changed(card, "has woken since"))
  end

  defp expect(%{"op" => "set_body", "page" => id, "expect" => hash}) do
    with {:ok, page} <- page(id) do
      if page.content_hash == hash,
        do: :ok,
        else: {:error, "“#{page.title}” has been edited since"}
    end
  end

  defp expect(%{"op" => "file_page", "page" => id, "expect" => folder_id}) do
    with {:ok, page} <- page(id) do
      if page.folder_id == folder_id,
        do: :ok,
        else: {:error, "“#{page.title}” has been filed elsewhere since"}
    end
  end

  # Removing a link or a comment that has already gone is nothing to refuse.
  defp expect(_step), do: :ok

  defp changed(card, what), do: {:error, "card ##{card.id} “#{card.title}” #{what}"}

  ## Lookups --------------------------------------------------------------------

  defp card(id) do
    case Repo.get(Card, to_int(id)) do
      nil -> {:error, "card ##{id} has been deleted"}
      card -> {:ok, card}
    end
  end

  defp page(id) do
    case Repo.get(Page, to_int(id)) do
      nil -> {:error, "page ##{id} has been deleted"}
      page -> {:ok, page}
    end
  end

  defp column(id) do
    case Repo.get(Column, to_int(id)) do
      nil -> {:error, "that list has been deleted"}
      column -> {:ok, column}
    end
  end

  # Where the card sits in its list, counting pages placed there too, as
  # `Boards.move_card_to_index/3` counts.
  defp index_in(%Card{} = card) do
    card.column_id |> Boards.active_items() |> Enum.find_index(&(&1 == {:card, card.id}))
  end

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  @doc false
  def touched_card_ids(steps) do
    steps
    |> Enum.flat_map(&subjects/1)
    |> Enum.flat_map(fn
      {:card, id} -> [id]
      _ -> []
    end)
  end

  @doc false
  def links_between(a, b) do
    from(l in CardLink,
      where: (l.from_id == ^a and l.to_id == ^b) or (l.from_id == ^b and l.to_id == ^a)
    )
    |> Repo.exists?()
  end
end
