defmodule Slipdock.Accounts.Groups do
  @moduledoc """
  Groups of users, so a board can be shared with several people in one grant
  (see `Slipdock.Access`). A group has an owner, who is also the one named
  when adding a member means inviting them. Reached through `Slipdock.Accounts`.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Accounts.{Group, Signups, User}

  def get_group!(id), do: Group |> Repo.get!(id) |> Repo.preload([:owner, :members])

  @doc "Groups the user owns or belongs to."
  def list_groups(%User{} = user) do
    from(g in Group,
      left_join: m in "group_members",
      on: m.group_id == g.id,
      where: g.owner_id == ^user.id or m.user_id == ^user.id,
      distinct: true,
      order_by: [asc: g.name]
    )
    |> Repo.all()
    |> Repo.preload([:owner, :members])
  end

  def group_ids_for(%User{} = user) do
    Repo.all(from(m in "group_members", where: m.user_id == ^user.id, select: m.group_id))
  end

  def create_group(%User{} = owner, attrs) do
    %Group{owner_id: owner.id}
    |> Group.changeset(Map.put(attrs, "owner_id", owner.id))
    |> Repo.insert()
    |> case do
      {:ok, group} -> {:ok, Repo.preload(group, [:owner, :members])}
      error -> error
    end
  end

  def update_group(%Group{} = group, attrs) do
    group |> Group.changeset(attrs) |> Repo.update()
  end

  def delete_group(%Group{} = group), do: Repo.delete(group)

  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  @doc """
  Adds the user with `email` to the group, inviting them if this server makes
  accounts for people you share things with.

  The group's owner is the inviter: they are the one doing the sharing, and the
  one an invitation should name.
  """
  def add_group_member(%Group{} = group, email) do
    inviter = group.owner || Repo.get(User, group.owner_id)

    with {:ok, user} <- Signups.invite_user(email, inviter, to: "the group “#{group.name}”") do
      Repo.insert_all("group_members", [%{group_id: group.id, user_id: user.id}],
        on_conflict: :nothing
      )

      # Whatever the group has been granted is theirs to see now.
      Slipdock.Boards.notify_users_boards_changed([user.id])
      {:ok, get_group!(group.id)}
    end
  end

  def remove_group_member(%Group{} = group, %User{} = user) do
    Repo.delete_all(
      from(m in "group_members", where: m.group_id == ^group.id and m.user_id == ^user.id)
    )

    Slipdock.Boards.notify_users_boards_changed([user.id])
    {:ok, get_group!(group.id)}
  end

  def group_member?(%Group{} = group, %User{} = user) do
    group.owner_id == user.id or
      Repo.exists?(
        from(m in "group_members", where: m.group_id == ^group.id and m.user_id == ^user.id)
      )
  end
end
