defmodule Slipdock.Boards.Activity do
  @moduledoc """
  One line in a board's activity log: what happened (`kind`, `message`), to
  what (a card or a page), and who did it (#1735).

  Who is `actor_kind` — `person`, `agent`, `automation`, `email` or
  `system` — with `user_id` for the person (or the token's owner, for an
  agent) and `actor_name`, a snapshot of the name to show: the person's name
  at the time, the agent's token label, the rule's name. `user_id` is
  nilified when the user is deleted and the snapshot stays. Rows from before
  #1735 have no actor and read as "Someone".
  """
  use Ecto.Schema

  alias Slipdock.Accounts.User
  alias Slipdock.{Actor, Repo}

  @actor_kinds ~w(person agent automation email system)

  schema "activities" do
    field :kind, :string
    field :message, :string
    field :actor_kind, :string
    field :actor_name, :string
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    # Set when the entry is about a wiki page rather than a card.
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :user, User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The kinds of actor an entry can name."
  def actor_kinds, do: @actor_kinds

  @doc """
  Fills in who made the change, from `actor` (by default this process's,
  `Slipdock.Actor.current/0`). An entry that already names an actor keeps it.
  Every activity row is inserted through this.
  """
  def stamp(activity, actor \\ Actor.current())

  def stamp(%__MODULE__{actor_kind: kind} = activity, _actor) when is_binary(kind), do: activity

  def stamp(%__MODULE__{} = activity, actor) do
    {kind, user_id, name} = who(actor || Actor.unknown())
    %{activity | actor_kind: kind, user_id: user_id, actor_name: name}
  end

  defp who(%{kind: "automation"} = actor),
    do: {"automation", nil, present(actor[:name]) || present(actor[:agent])}

  defp who(%{via: "email", user_id: id} = actor) when is_integer(id),
    do: person("email", actor)

  defp who(%{kind: "human", user_id: id} = actor) when is_integer(id),
    do: person("person", actor)

  defp who(%{kind: "agent"} = actor),
    do: {"agent", actor[:user_id], present(actor[:agent]) || agent_name(actor[:via])}

  defp who(_actor), do: {"system", nil, nil}

  # The name given with the actor, else the user's own, looked up here; a
  # user who is gone by now is a name with no link.
  defp person(kind, actor) do
    if name = present(actor[:name]) do
      {kind, actor.user_id, name}
    else
      case Repo.get(User, actor.user_id) do
        nil -> {kind, nil, nil}
        user -> {kind, user.id, User.display_name(user)}
      end
    end
  end

  defp agent_name("assistant"), do: "Assistant"
  defp agent_name("runner"), do: "Runner"
  defp agent_name(_), do: "Agent"

  defp present(s) when is_binary(s) and s != "", do: s
  defp present(_), do: nil
end
