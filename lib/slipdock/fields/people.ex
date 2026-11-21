defmodule Slipdock.Fields.People do
  @moduledoc """
  A person field's people (#3614). The field holds user ids, kept as strings
  in `card_field_values.options` in the order they were picked; whoever it
  may newly hold is a current member of the board tree, the people who can
  read its root board (`Slipdock.Wiki.members/1`, as the assignee picker
  offers). Someone who has left keeps their place on the cards that hold
  them, marked as a former member, and can't be picked again.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, FieldDefinition}
  alias Slipdock.Repo

  @doc "The tree's current members, the people the field offers, by email."
  def members(%FieldDefinition{} = field) do
    case root(field) do
      nil -> []
      board -> Slipdock.Wiki.members(board)
    end
  end

  @doc """
  What a person filter offers (#3614): `{value, label}` for "Me", the viewer
  whoever they are, then each current member.
  """
  def filter_choices(%FieldDefinition{} = field),
    do: [{"me", "Me"} | Enum.map(members(field), &{to_string(&1.id), User.display_name(&1)})]

  @doc """
  The people `ids` name, in order: `%{id, name, email, former}`, `former`
  true for one who is no longer a member. An id with no account is left out.
  """
  def people(_field, ids) when ids in [nil, []], do: []

  def people(%FieldDefinition{} = field, ids) when is_list(ids) do
    ints = ids |> Enum.map(&to_id/1) |> Enum.reject(&is_nil/1)
    users = from(u in User, where: u.id in ^ints) |> Repo.all() |> Map.new(&{&1.id, &1})
    current = current_ids(field, Map.values(users))

    for id <- Enum.uniq(ints), user = users[id] do
      %{
        id: id,
        name: User.display_name(user),
        email: user.email,
        former: not MapSet.member?(current, id)
      }
    end
  end

  def people(_field, _ids), do: []

  @doc "A person as it is shown: their name, and `(former member)` after it when they have left."
  def label(%{name: name, former: true}), do: "#{name} (former member)"
  def label(%{name: name}), do: name

  @doc """
  What to store for `raw`, a list or a comma-separated string of emails,
  user ids or `me` (whoever the process acts for, `Slipdock.Actor`):
  `{:ok, [id]}` in the order given without repeats, or `{:error, message}`
  naming the field and the person. Each must be a current member, except
  one already in `held`, the ids the card holds now, so saving a card that
  keeps a former member doesn't fail.
  """
  def cast(%FieldDefinition{} = field, raw, held) do
    refs = refs(raw)
    members = field |> members() |> MapSet.new(& &1.id)
    held = MapSet.new(held, &to_string/1)

    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, ids} ->
      case resolve(ref, members, held) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, {:error, refusal(field, ref)}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  @doc "The id of the user the process acts for, the `me` of a value or a filter; nil for nobody."
  def me_id do
    case Slipdock.Actor.principal() do
      {%User{id: id}, _token} -> id
      _ -> Slipdock.Actor.current()[:user_id]
    end
  end

  @doc "A filter's people with `me` read as the viewer (`me_id/0`), as id strings."
  def resolve_filter(people) do
    people
    |> List.wrap()
    |> Enum.flat_map(fn
      "me" -> if id = me_id(), do: [to_string(id)], else: []
      id -> [to_string(id)]
    end)
  end

  defp resolve(ref, members, held) do
    case user_for(ref) do
      %User{id: id} ->
        cond do
          MapSet.member?(members, id) -> {:ok, to_string(id)}
          MapSet.member?(held, to_string(id)) -> {:ok, to_string(id)}
          true -> :error
        end

      nil ->
        :error
    end
  end

  defp user_for(ref) do
    cond do
      String.downcase(ref) == "me" -> (id = me_id()) && Repo.get(User, id)
      match?({_, ""}, Integer.parse(ref)) -> Repo.get(User, String.to_integer(ref))
      true -> Slipdock.Accounts.get_user_by_email(ref)
    end
  end

  defp refusal(field, ref), do: "#{field.name}: #{ref} isn't a member of this board."

  defp refs(raw) when is_list(raw), do: Enum.flat_map(raw, &refs/1)

  defp refs(raw) when is_integer(raw), do: [Integer.to_string(raw)]
  defp refs(%{"id" => id}), do: refs(id)
  defp refs(%{id: id}), do: refs(id)

  defp refs(raw),
    do:
      raw
      |> to_string()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp current_ids(_field, []), do: MapSet.new()

  defp current_ids(field, users) do
    case root(field) do
      nil -> MapSet.new()
      board -> board |> Slipdock.Wiki.members_among(users) |> MapSet.new(& &1.id)
    end
  end

  defp root(%FieldDefinition{board_id: id}), do: id && Repo.get(Board, id)

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil
end
