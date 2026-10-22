defmodule Slipdock.HeaderLinks do
  @moduledoc """
  Header links (#1205): boards and vaults a person pins to the header, left of
  the quick add button, each drawn as an icon they chose.

  They belong to the person, like hotkeys (`Slipdock.Hotkeys`): two people on
  one board keep their own, and sharing a board hands nobody else's links
  over. A board can be linked by anyone who can open it, a vault only by its
  owner. Access is checked when a link is made and again every time the
  header is drawn, since a share can be revoked long after the row was
  written; a link to an archived board is kept but not drawn, for when the
  board comes back.

  The icons are the wiki's (`Slipdock.Wiki.Icons`), which are all in the
  stylesheet. A header has room for a few, so there are at most `max/0`.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.HeaderLinks.HeaderLink
  alias Slipdock.Vaults.Vault
  alias Slipdock.Wiki.Icons
  alias Slipdock.{Access, Repo, Vaults}

  @max 8

  @doc "How many links a header holds."
  def max, do: @max

  @doc "The icon names a link may wear, in the order a picker shows them."
  def icons, do: Icons.names()

  @doc """
  `user`'s links that can be drawn, in their order: each a map of `:id`,
  `:icon`, `:kind` (`:board` or `:vault`), `:name` and `:target` (the board
  or vault itself).
  """
  def list(%User{} = user) do
    user
    |> rows()
    |> Enum.filter(fn {_link, target} -> visible?(user, target) and openable?(target) end)
    |> Enum.map(fn {link, target} -> entry(link, target) end)
  end

  def list(_), do: []

  defp rows(user) do
    from(l in HeaderLink,
      left_join: b in Board,
      on: b.id == l.board_id,
      left_join: v in Vault,
      on: v.id == l.vault_id,
      where: l.user_id == ^user.id,
      order_by: [asc: l.position, asc: l.id],
      select: {l, b, v}
    )
    |> Repo.all()
    |> Enum.map(fn {link, board, vault} -> {link, board || vault} end)
  end

  defp entry(link, target) do
    %{
      id: link.id,
      icon: link.icon,
      kind: kind(target),
      name: target.name,
      target: target
    }
  end

  defp kind(%Board{}), do: :board
  defp kind(%Vault{}), do: :vault

  @doc """
  Finds what a link would point at from what a form, a client or the CLI
  sent: `"board:12"` or `"vault:3"`, or a kind and a reference (a board's id,
  code or name; a vault's id or name). `{:ok, board_or_vault}` or
  `{:error, message}`.
  """
  def resolve(%User{} = user, "board:" <> ref), do: resolve(user, :board, ref)
  def resolve(%User{} = user, "vault:" <> ref), do: resolve(user, :vault, ref)
  def resolve(_user, _ref), do: {:error, "choose a board or a vault"}

  def resolve(user, kind, ref) when kind in ["board", "vault"],
    do: resolve(user, String.to_existing_atom(kind), ref)

  def resolve(%User{} = user, :board, ref) do
    case Access.find_board(user, to_string(ref)) do
      {:ok, board} -> {:ok, board}
      _ -> {:error, "board not found"}
    end
  end

  def resolve(%User{} = user, :vault, ref) do
    case Vaults.get_vault(user, ref) do
      {:ok, vault} -> {:ok, vault}
      _ -> {:error, "vault not found"}
    end
  end

  def resolve(_user, _kind, _ref), do: {:error, "a link is to a board or a vault"}

  @doc """
  Pins `target` (a board or vault) to `user`'s header as `icon`, at the end.
  Linking something already linked changes its icon and leaves it where it
  is. `{:ok, entry}` (as `list/1` gives them) or `{:error, message}`.
  """
  def add(%User{} = user, target, icon)
      when is_struct(target, Board) or is_struct(target, Vault) do
    with :ok <- valid_icon(icon),
         :ok <- allowed(user, target) do
      case Repo.one(from(l in HeaderLink, where: l.user_id == ^user.id) |> on(target)) do
        %HeaderLink{} = link ->
          link = link |> Ecto.Changeset.change(icon: icon) |> Repo.update!()
          {:ok, entry(link, target)}

        nil ->
          insert(user, target, icon)
      end
    end
  end

  defp insert(user, target, icon) do
    count = Repo.aggregate(from(l in HeaderLink, where: l.user_id == ^user.id), :count)

    if count >= @max do
      {:error, "the header holds #{@max} links; remove one first"}
    else
      position =
        Repo.one(from(l in HeaderLink, where: l.user_id == ^user.id, select: max(l.position))) ||
          -1

      link =
        Repo.insert!(
          case target do
            %Board{id: id} -> %HeaderLink{user_id: user.id, board_id: id}
            %Vault{id: id} -> %HeaderLink{user_id: user.id, vault_id: id}
          end
          |> Map.merge(%{icon: icon, position: position + 1})
        )

      {:ok, entry(link, target)}
    end
  end

  defp on(query, %Board{id: id}), do: from(l in query, where: l.board_id == ^id)
  defp on(query, %Vault{id: id}), do: from(l in query, where: l.vault_id == ^id)

  defp valid_icon(icon) do
    if icon in Icons.names(),
      do: :ok,
      else: {:error, "choose an icon: #{Enum.join(Icons.names(), ", ")}"}
  end

  defp allowed(user, target) do
    if visible?(user, target), do: :ok, else: {:error, "#{kind(target)} not found"}
  end

  @doc "Takes link `id` off `user`'s header. `:ok`, or `{:error, :not_found}`."
  def remove(%User{} = user, id) do
    case Repo.delete_all(from(l in HeaderLink, where: l.user_id == ^user.id and l.id == ^id)) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Moves link `id` one place `:left` or `:right` along `user`'s header. At an
  end it stays put. `:ok`, or `{:error, :not_found}`.
  """
  def move(%User{} = user, id, direction) when direction in [:left, :right] do
    links = user |> rows() |> Enum.map(&elem(&1, 0))

    case Enum.find_index(links, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      index ->
        other = if direction == :left, do: index - 1, else: index + 1

        reordered =
          if other < 0 or other >= length(links),
            do: links,
            else:
              links
              |> List.replace_at(index, Enum.at(links, other))
              |> List.replace_at(other, Enum.at(links, index))

        Repo.transaction(fn ->
          reordered
          |> Enum.with_index()
          |> Enum.each(fn {link, position} ->
            if link.position != position,
              do: link |> Ecto.Changeset.change(position: position) |> Repo.update!()
          end)
        end)

        :ok
    end
  end

  defp openable?(%Board{archived_at: archived_at}), do: is_nil(archived_at)
  defp openable?(%Vault{}), do: true

  # Anything that would list the board in the switcher can be linked, a grant
  # on one of its views included. A vault is its owner's.
  defp visible?(user, %Vault{user_id: owner}), do: owner == user.id
  defp visible?(user, %Board{} = board), do: Access.board_permission(user, board) != :none
  defp visible?(_user, nil), do: false
end
