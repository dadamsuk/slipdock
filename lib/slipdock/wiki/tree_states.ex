defmodule Slipdock.Wiki.TreeStates do
  @moduledoc """
  Which containers a reader has open in a wiki's tree, kept on the server per
  reader and per tree (W-103 R11.7): `"board:4"` for a board's own tree,
  `"vault:2"` for a vault's. The same tree opens the same way on every
  machine they read it on.

  Only keys the tree itself uses are kept (`folder:12`, `page:7`, `board:4`,
  `dir:Projects/X`), and at most 300 of them: an open set is a
  convenience, and a runaway one would make every visit slow.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Accounts.User

  @max 300
  @key ~r/\A(?:(?:folder|page|board):\d+|dir:[^\n]{1,500})\z/

  defmodule State do
    @moduledoc false
    use Ecto.Schema

    schema "tree_states" do
      field :scope, :string
      field :open, {:array, :string}, default: []
      belongs_to :user, Slipdock.Accounts.User

      timestamps(type: :utc_datetime)
    end
  end

  @doc "The tree a scope names: a board's or a vault's, by id."
  def scope(:board, id), do: "board:#{id}"
  def scope(:vault, id), do: "vault:#{id}"

  @doc "What `user` last had open in the tree `scope`, or nil when nothing was kept."
  def get(%User{id: user_id}, scope) do
    Repo.one(from(s in State, where: s.user_id == ^user_id and s.scope == ^scope, select: s.open))
  end

  def get(_user, _scope), do: nil

  @doc """
  Keeps what `user` has open in the tree `scope`, replacing what was kept.
  Keys the tree does not use are dropped, and the list is cut at #{@max}.
  """
  def put(%User{id: user_id}, scope, keys) when is_binary(scope) and is_list(keys) do
    open =
      keys
      |> Enum.filter(&(is_binary(&1) and Regex.match?(@key, &1)))
      |> Enum.uniq()
      |> Enum.take(@max)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      State,
      [%{user_id: user_id, scope: scope, open: open, inserted_at: now, updated_at: now}],
      on_conflict: [set: [open: open, updated_at: now]],
      conflict_target: [:user_id, :scope]
    )

    {:ok, open}
  end

  def put(_user, _scope, _keys), do: {:error, :invalid}
end
