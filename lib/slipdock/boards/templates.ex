defmodule Slipdock.Boards.Templates do
  @moduledoc """
  Board templates: the built-in ones and a person's own, who may edit them,
  and the attributes a board is made from.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Column
  alias Slipdock.Boards.Template
  alias Slipdock.Repo

  ## Templates
  #
  # A template is built in (`system`: nobody's, read-only to everyone, admins
  # included) or one person's own. A person sees the built-ins and their own,
  # changes only their own, and never learns that anybody else's exists.

  @doc """
  The templates `user` can use: the built-ins and their own. `nil` means
  nobody in particular (the server's own work), and gets the built-ins only.
  """
  def list_templates(user),
    do: Repo.all(from(t in visible_templates(user), order_by: [asc: t.name]))

  defp visible_templates(nil), do: from(t in Template, where: t.system)

  defp visible_templates(%{id: user_id}),
    do: from(t in Template, where: t.system or t.owner_id == ^user_id)

  @doc "The template `id`, if `user` can see it (see `list_templates/1`); raises otherwise."
  def get_template!(user, id), do: Repo.get!(visible_templates(user), id)

  @doc """
  Finds a template `user` can see by id or (case-insensitive) name. Their
  own names never match a built-in's (`create_template/2` refuses them), so
  a name finds one template at most.
  """
  def find_template(user, ref) do
    ref = to_string(ref)

    query =
      case Integer.parse(ref) do
        {id, ""} ->
          from(t in visible_templates(user), where: t.id == ^id)

        _ ->
          name = String.downcase(String.trim(ref))
          from(t in visible_templates(user), where: fragment("lower(?)", t.name) == ^name)
      end

    case Repo.one(from(q in query, order_by: q.id, limit: 1)) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  @doc """
  Whether `user` may `:read` or `:write` (edit or delete) `template`: `:ok`,
  `{:error, :forbidden}` for a built-in they would change (nobody may), or
  `{:error, :not_found}` for somebody else's, which is not theirs to know of.
  """
  def authorize_template(user, %Template{} = template, need) when need in [:read, :write] do
    cond do
      template.system and need == :read -> :ok
      template.system -> {:error, :forbidden}
      user && template.owner_id == user.id -> :ok
      true -> {:error, :not_found}
    end
  end

  @doc "A built-in template is read-only to everyone."
  def template_editable?(user, %Template{} = template),
    do: authorize_template(user, template, :write) == :ok

  @doc "Makes a template owned by `user`; `attrs` can't make it anybody else's, or built in."
  def create_template(%{id: user_id}, attrs) do
    %Template{owner_id: user_id, system: false}
    |> Template.changeset(attrs)
    |> reserve_built_in_names(Repo)
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn _ -> Boards.PubSub.broadcast_templates() end)
  end

  @doc """
  Makes a built-in template: the server's own (the demo and onboarding make
  one they need when it is missing). Never reached from a request.
  """
  def create_system_template(attrs) do
    %Template{system: true}
    |> Template.changeset(attrs)
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn _ -> Boards.PubSub.broadcast_templates() end)
  end

  @doc "Changes `user`'s own template; see `authorize_template/3` for the refusals."
  def update_template(user, %Template{} = template, attrs) do
    with :ok <- authorize_template(user, template, :write) do
      template
      |> Template.changeset(attrs)
      |> reserve_built_in_names(Repo)
      |> Repo.update()
      |> Boards.Shared.tap_ok(fn _ -> Boards.PubSub.broadcast_templates() end)
    end
  end

  @doc "Deletes `user`'s own template; see `authorize_template/3` for the refusals."
  def delete_template(user, %Template{} = template) do
    with :ok <- authorize_template(user, template, :write) do
      Repo.delete(template)
      |> Boards.Shared.tap_ok(fn _ -> Boards.PubSub.broadcast_templates() end)
    end
  end

  # A person's template may not take a built-in's name (in any case), or
  # finding a template by name would have two answers.
  @doc false
  def reserve_built_in_names(changeset, repo) do
    case Ecto.Changeset.get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        lower = String.downcase(name)

        if repo.exists?(
             from(t in Template, where: t.system and fragment("lower(?)", t.name) == ^lower)
           ),
           do: Ecto.Changeset.add_error(changeset, :name, "already exists"),
           else: changeset
    end
  end

  def change_template(%Template{} = template, attrs \\ %{}),
    do: Template.changeset(template, attrs)

  @doc "Template attributes describing `board`'s current lists."
  def template_attrs_from_board(%Board{} = board) do
    columns =
      from(c in Column, where: c.board_id == ^board.id, order_by: c.position)
      |> Repo.all()
      |> Enum.map(
        &%{
          "name" => &1.name,
          "wip_limit" => &1.wip_limit,
          "color" => &1.color,
          "category" => &1.category
        }
      )

    %{
      "name" => board.name,
      "description" => board.description,
      "columns" => columns,
      "kind" => board.kind
    }
  end
end
