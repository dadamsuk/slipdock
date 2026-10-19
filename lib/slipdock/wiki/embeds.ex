defmodule Slipdock.Wiki.Embeds do
  @moduledoc """
  The files a page embeds — `![[diagram.png]]`, `![[report.pdf]]`,
  `![[sketch.excalidraw]]` — and what sharing the page passes on with them
  (#832).

  A page shared with somebody is meant to read as its owner wrote it, and
  an image is part of the page. So a file the page embeds can be read by
  anybody who can read the page, through it: the renderer links the file
  with `?page=<id>` (`url/2`), and the file and drawing controllers serve
  it when `reaches?/3` says so. A linked file (`[[report.pdf]]`) is not
  embedded and is not passed on: it stays the reader's own permission.

  A sharee who may edit the page must not be able to write
  `![[someone-elses.png]]` into it and so read any file on the owner's
  board. An embed only counts when it is in the page as last saved by
  somebody who could see that file themselves (or by the system — a sync,
  an import): the newest such revision is the body that vouches for it.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Wiki.{Excalidraw, Files, Links, Markup, Page, Revision, WikiFile}

  @doc """
  Whether `![[target]]` names a file rather than a page: anything with an
  extension other than `.md`.
  """
  def file_target?(target) do
    ext = target |> to_string() |> Path.extname() |> String.downcase()
    ext not in ["", ".md"] and Regex.match?(~r/\A\.[a-z0-9]{1,8}\z/, ext)
  end

  @doc "The files `body` embeds from `page`, as the system finds them."
  @spec files(Page.t(), String.t() | nil) :: [WikiFile.t()]
  def files(%Page{} = page, body) do
    targets =
      for ref <- (body || "") |> Links.text_runs() |> Enum.flat_map(&Markup.refs/1),
          Map.get(ref, :embed) && (file_target?(ref.target) or Excalidraw.name?(ref.target)),
          uniq: true,
          do: ref.target

    case targets do
      [] ->
        []

      _ ->
        board = Wiki.board_of(page)
        for target <- targets, %WikiFile{} = file <- [Files.find(board, target, nil)], do: file
    end
  end

  @doc """
  Whether `page` embeds `file`, in the page as last saved by somebody who
  could see the file without the page.
  """
  @spec vouched?(Page.t(), WikiFile.t()) :: boolean
  def vouched?(%Page{} = page, %WikiFile{} = file) do
    # Still in the page as it reads now, and in what vouches for it.
    embeds?(page, page.body, file) and
      case vouching_body(page, file) do
        nil -> false
        body -> embeds?(page, body, file)
      end
  end

  defp embeds?(page, body, file), do: Enum.any?(files(page, body), &(&1.id == file.id))

  @doc """
  Whether `user` may read `file` through `page`: they can read the page,
  and the page embeds the file (`vouched?/2`).
  """
  @spec reaches?(User.t() | nil, Page.t() | nil, WikiFile.t()) :: boolean
  def reaches?(
        %User{} = user,
        %Page{archived_at: nil} = page,
        %WikiFile{archived_at: nil} = file
      ),
      do: Wiki.visible?(page, Access.page_permission(user, page)) and vouched?(page, file)

  def reaches?(_user, _page, _file), do: false

  @doc "The page `?page=` names, for the controllers; nil when it names none."
  def page_param(%{"page" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> Repo.get(Page, n)
      _ -> nil
    end
  end

  def page_param(_params), do: nil

  @doc """
  Whether `file` is shown on `page` as published (#1166): the page is
  published, the file is an image, and the page embeds it (`vouched?/2`).
  Anything else on a published page stays a name: an anonymous reader has
  no permissions, and an image is the one kind of file that is plainly
  part of the page.
  """
  @spec published?(Page.t() | nil, WikiFile.t()) :: boolean
  def published?(
        %Page{public_token: token, archived_at: nil} = page,
        %WikiFile{archived_at: nil} = file
      )
      when is_binary(token) do
    not Page.draft?(page) and WikiFile.image?(file) and file.board_id == page.board_id and
      vouched?(page, file)
  end

  def published?(_page, _file), do: false

  @doc "Where `file` is served to anybody reading `page` through its published link."
  def published_url(%WikiFile{id: id, name: name}, %Page{public_token: token}),
    do: "/w/#{token}/files/#{id}/#{URI.encode(name)}"

  @doc "Where `file` is served to somebody reading it through `page`."
  def url(%WikiFile{} = file, %Page{id: id}), do: Files.url(file) <> "?page=#{id}"

  # A page that has never been saved through `Wiki` (no revisions) is as it
  # was made: its body is the owner's. Otherwise the newest revision whose
  # author could see the file; nil if none could.
  defp vouching_body(page, file) do
    board = Repo.preload(file, :board).board

    revisions =
      from(r in Revision,
        where: r.page_id == ^page.id,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: :author
      )
      |> Repo.all()

    case revisions do
      [] ->
        page.body

      _ ->
        Enum.find_value(revisions, fn revision ->
          if could_see?(revision.author, board), do: revision.body || ""
        end)
    end
  end

  defp could_see?(nil, _board), do: true

  defp could_see?(%User{} = author, board),
    do: Access.can_read?(Access.board_permission(author, board))
end
