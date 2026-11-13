defmodule Slipdock.Verified.Actors do
  @moduledoc """
  Who did something, as the checks of `Slipdock.Verified` read it: whether
  an actor is an agent the checks apply to, whether two actors are the same
  one, the actor the server accepts as, and an actor's name in words.
  """

  alias Slipdock.Repo

  @doc "Whether the checks apply to a change made by `actor`."
  def gated?(%{kind: "agent", via: via}) when via != "assistant", do: true
  def gated?(_actor), do: false

  @server_agent "the server"

  @doc """
  The actor the server accepts an unverified card as (#1953): not a person,
  so a `before_merge` tier still holds it, and not an agent, so no audit
  samples it.
  """
  def server_actor, do: %{Slipdock.Actor.automation() | agent: @server_agent}

  @doc false
  def server?(actor),
    do: match?(%{"kind" => "automation", "agent" => @server_agent}, actor_map(actor))

  @doc """
  Whether two actors (`Slipdock.Actor` maps, as stored or as built) are the
  same one: the same kind, person, token label and runner job. Two runner
  jobs, two tokens, or a person and an agent are different.
  """
  def same_actor?(nil, _actor), do: false

  def same_actor?(a, b) do
    a = actor_map(a)
    b = actor_map(b)
    Map.take(a, ~w(kind user_id agent job_id)) == Map.take(b, ~w(kind user_id agent job_id))
  end

  @doc false
  def actor_map(nil), do: nil

  def actor_map(actor) do
    Map.new(~w(kind via user_id agent job_id), fn key ->
      {key, Map.get(actor, key, Map.get(actor, String.to_existing_atom(key)))}
    end)
  end

  @doc """
  Who an actor stored on a card (`verify_by`, `verify_submitter`) was, in
  words: an agent by its token's label, a person by their name.
  """
  def who(nil), do: "somebody"

  def who(actor) do
    case actor_map(actor) do
      %{"kind" => kind} when kind in ["agent", "automation"] ->
        who(actor, nil)

      %{"user_id" => id} when is_integer(id) ->
        Slipdock.Accounts.User.display_name(Repo.get(Slipdock.Accounts.User, id))

      _ ->
        "somebody"
    end
  end

  @doc """
  The person behind an actor stored on a card, when it was a person whose
  account still exists: nil for an agent, a deleted account or nobody. The
  card panel uses it to show their email and offer a note or an assignment.
  """
  def person(nil), do: nil

  def person(actor) do
    case actor_map(actor) do
      %{"kind" => "agent"} -> nil
      %{"user_id" => id} when is_integer(id) -> Repo.get(Slipdock.Accounts.User, id)
      _ -> nil
    end
  end

  @doc false
  def who(actor, user), do: actor |> actor_map() |> named(user)

  # The server's own acceptance (#1953) names itself.
  defp named(%{"kind" => "automation", "agent" => agent}, _user) when is_binary(agent), do: agent

  defp named(a, user) do
    cond do
      a["via"] == "runner" and a["agent"] -> "runner #{a["agent"]}"
      a["kind"] == "agent" and a["agent"] -> "agent “#{a["agent"]}”"
      a["kind"] == "agent" -> "an agent"
      user -> Slipdock.Accounts.User.display_name(user)
      true -> "somebody"
    end
  end

  @doc false
  def handoff_via(actor) do
    case actor_map(actor)["via"] do
      "web" -> "ui"
      via when via in ~w(api mcp cli runner) -> via
      _ -> "api"
    end
  end
end
