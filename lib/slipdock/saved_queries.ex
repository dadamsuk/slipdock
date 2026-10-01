defmodule Slipdock.SavedQueries do
  @moduledoc """
  The questions a person keeps asking their boards.

  The search page opens with a handful of examples — "anything about flaky
  tests", "what's at risk across all my boards right now" — because an empty
  box is no help at all when you have never used it. They are scaffolding,
  and once somebody has saved a query of their own the scaffolding comes
  down: their own questions are better examples than ours, and a list of
  both is a list of neither. `examples_for/3` is what decides that.

  Only the text is kept, never the answer. The answer to "what's at risk
  this week" is a snapshot of a Tuesday; the question outlives it, which is
  the whole reason for asking it again.

  Saved queries are the person's own, like `Slipdock.Favourites` — two people
  on the same board keep different ones, and nothing here is ever shared.
  The two modes keep separate lists: a question you ask a model is not the
  same thing as a phrase you search for, even when the words match.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Repo
  alias Slipdock.SavedQueries.SavedQuery

  @modes SavedQuery.modes()

  ## Reading ------------------------------------------------------------------

  @doc "Everything `user` has saved in `mode`, newest first."
  @spec list(User.t() | nil, String.t() | atom) :: [SavedQuery.t()]
  def list(user, mode \\ nil)

  def list(%User{} = user, nil) do
    from(q in SavedQuery,
      where: q.user_id == ^user.id,
      order_by: [desc: q.inserted_at, desc: q.id]
    )
    |> Repo.all()
  end

  def list(%User{} = user, mode) do
    case normalize(mode) do
      {:ok, mode} ->
        from(q in SavedQuery,
          where: q.user_id == ^user.id and q.mode == ^mode,
          order_by: [desc: q.inserted_at, desc: q.id]
        )
        |> Repo.all()

      :error ->
        []
    end
  end

  def list(_, _), do: []

  @doc """
  What to offer someone who has not typed anything yet: their own saved
  queries when they have any, otherwise `fallback` (the built-in examples).

  Returns `{:saved, queries}` or `{:examples, texts}`, so the caller can
  label the list and decide whether to draw a delete button beside each row.
  """
  @spec examples_for(User.t() | nil, String.t() | atom, [String.t()]) ::
          {:saved, [SavedQuery.t()]} | {:examples, [String.t()]}
  def examples_for(user, mode, fallback) do
    case list(user, mode) do
      [] -> {:examples, fallback}
      saved -> {:saved, saved}
    end
  end

  @doc "Whether `user` has this exact text saved in this mode."
  @spec saved?(User.t() | nil, String.t() | atom, String.t()) :: boolean
  def saved?(%User{} = user, mode, text) do
    with {:ok, mode} <- normalize(mode),
         trimmed when trimmed != "" <- String.trim(to_string(text)) do
      Repo.exists?(
        from(q in SavedQuery,
          where: q.user_id == ^user.id and q.mode == ^mode and q.text == ^trimmed
        )
      )
    else
      _ -> false
    end
  end

  def saved?(_, _, _), do: false

  ## Writing ------------------------------------------------------------------

  @doc """
  Saves `text` for `user` under `mode`. Saving the same thing twice is
  saving it once: the existing row comes back rather than an error.
  """
  @spec save(User.t(), String.t() | atom, String.t()) ::
          {:ok, SavedQuery.t()} | {:error, Ecto.Changeset.t() | :bad_mode}
  def save(%User{} = user, mode, text) do
    case normalize(mode) do
      {:ok, mode} ->
        attrs = %{"user_id" => user.id, "mode" => mode, "text" => text}

        %SavedQuery{}
        |> SavedQuery.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, saved} -> {:ok, saved}
          {:error, changeset} -> existing(user, mode, changeset)
        end

      :error ->
        {:error, :bad_mode}
    end
  end

  @doc "Removes a saved query by id. Only ever the caller's own."
  @spec delete(User.t(), integer) :: :ok
  def delete(%User{} = user, id) when is_integer(id) do
    Repo.delete_all(from(q in SavedQuery, where: q.user_id == ^user.id and q.id == ^id))
    :ok
  end

  @doc "Removes a saved query by its text. Idempotent."
  @spec remove(User.t(), String.t() | atom, String.t()) :: :ok
  def remove(%User{} = user, mode, text) do
    with {:ok, mode} <- normalize(mode) do
      trimmed = String.trim(to_string(text))

      Repo.delete_all(
        from(q in SavedQuery,
          where: q.user_id == ^user.id and q.mode == ^mode and q.text == ^trimmed
        )
      )
    end

    :ok
  end

  @doc """
  Saves `text` if it isn't saved, removes it if it is. What the star on the
  search box does.
  """
  @spec toggle(User.t(), String.t() | atom, String.t()) ::
          {:ok, :saved | :removed} | {:error, term}
  def toggle(%User{} = user, mode, text) do
    if saved?(user, mode, text) do
      remove(user, mode, text)
      {:ok, :removed}
    else
      case save(user, mode, text) do
        {:ok, _} -> {:ok, :saved}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The valid modes, as strings."
  def modes, do: @modes

  ## Helpers ------------------------------------------------------------------

  # A unique-constraint failure means somebody saved it twice, which is not an
  # error worth showing anyone — hand back the row they already had. Any other
  # failure (blank text, too long) leaves `text` nil or invalid and is a real
  # error, so it goes back as one rather than being looked up.
  defp existing(user, mode, changeset) do
    case Ecto.Changeset.get_field(changeset, :text) do
      text when is_binary(text) and text != "" ->
        from(q in SavedQuery,
          where: q.user_id == ^user.id and q.mode == ^mode and q.text == ^text
        )
        |> Repo.one()
        |> case do
          nil -> {:error, changeset}
          saved -> {:ok, saved}
        end

      _ ->
        {:error, changeset}
    end
  end

  defp normalize(mode) when mode in @modes, do: {:ok, mode}
  defp normalize(mode) when is_atom(mode), do: normalize(Atom.to_string(mode))
  defp normalize(_), do: :error
end
