defmodule SlipdockWeb.MCP.Tools.UpdatePage do
  @moduledoc """
  A wiki page's housekeeping, as the CLI's `page edit --title/--summary`,
  `page mv`, `page file`, `page rm`, `page restore` and `page pin` do it:
  everything about a page but its body, which is `write_page`'s.

  Restoring happens first and archiving last, so one call can bring a page
  back and rename it, or tidy it away and file it, either way round. Purging
  a page for good stays on the CLI, with the board's owner.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Access, Wiki}
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "update_page"

  @impl true
  def title, do: "Update a wiki page"

  @impl true
  def description,
    do:
      "Changes a page but not its body: title, summary, parent (\"\" for the top) and " <>
        "position, folder, archived (false restores), and pinning it as the page for a card. " <>
        "Only what you pass changes. write_page edits the body."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        page: %{
          type: "string",
          description: "Page code like W-31, or a slug or title with board."
        },
        board: %{type: "string", description: "Board, when page is a slug or title."},
        title: %{type: "string"},
        summary: %{type: "string", description: "One line on what the page is; \"\" clears it."},
        parent: %{
          type: "string",
          description: "Page to sit under (code, slug or title); \"\" moves it to the top."
        },
        position: %{
          type: ["integer", "string"],
          description: "Among its siblings: a number from 0, or \"top\" or \"bottom\"."
        },
        folder: %{
          type: "string",
          description: "Folder name or path like \"Design/Decisions\", made if new; \"\" unfiles."
        },
        archived: %{type: "boolean", description: "true puts it away with its children."},
        pin_card: %{type: "integer", description: "Card this is *the* page for."},
        unpin_card: %{type: "integer"},
        message: %{type: "string", description: "Why, for the page history."}
      },
      required: ["page"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, page} <- page(args, auth, context.user),
         board <- Wiki.board_of(page),
         {:ok, archived} <- Args.boolean(args, "archived"),
         {:ok, attrs} <- attrs(args),
         {:ok, attrs} <- folder(board, attrs, args),
         {:ok, move} <- move(board, page, args),
         {:ok, pin} <- pin_target(auth, args, "pin_card"),
         {:ok, unpin} <- pin_target(auth, args, "unpin_card"),
         {:ok, page} <- restore(page, archived),
         {:ok, page} <- save(page, attrs, opts(args, context)),
         {:ok, page} <- reposition(page, move),
         :ok <- pin(page, pin, true),
         :ok <- pin(page, unpin, false),
         {:ok, page} <- archive(page, archived) do
      page = Wiki.get_page!(page.id)

      {:ok,
       page
       |> V.page_summary()
       |> Map.take([
         :id,
         :code,
         :title,
         :slug,
         :summary,
         :parent_id,
         :folder_id,
         :position,
         :archived_at,
         :content_hash
       ])
       |> Map.merge(%{
         pinned_to: pinned_to(pin, unpin),
         url: context.base_url <> V.page_url(page)
       })}
    end
  end

  defp page(args, auth, user) do
    with {:ok, ref} <- Args.required(args, "page"),
         {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, page} <- find(ref, board_ref, auth),
         :ok <- Args.refusal(Authorize.page(auth, page, :write)) do
      if Wiki.visible?(page, Access.page_permission(user, page)),
        do: {:ok, page},
        else: {:error, "no page you can see matches that"}
    end
  end

  defp find(ref, nil, auth), do: lookup(Wiki.find_page(ref, as: auth.assigns.current_user))

  defp find(ref, board_ref, auth) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, board_ref, :read)) do
      lookup(Wiki.find_page(board, ref))
    end
  end

  defp lookup({:ok, page}), do: {:ok, page}
  defp lookup(_), do: {:error, "no page you can see matches that"}

  # A blank title is a mistake rather than a wish; a blank summary clears it.
  defp attrs(args) do
    with {:ok, title} <- Args.optional(args, "title"),
         {:ok, summary} <- summary(args) do
      if is_map_key(args, "title") and is_nil(title),
        do: {:error, "title can't be blank"},
        else: {:ok, drop_unsent(%{"title" => title, "summary" => summary}, args)}
    end
  end

  defp summary(%{"summary" => s}) when is_binary(s), do: {:ok, String.trim(s)}
  defp summary(%{"summary" => _}), do: {:error, "summary must be a string"}
  defp summary(_), do: {:ok, nil}

  defp drop_unsent(attrs, args), do: Map.filter(attrs, fn {k, _} -> is_map_key(args, k) end)

  # The folder by id, slug, name or path, made when it is not there yet, as
  # the API files a page; "" takes it out of the one it is in.
  defp folder(_board, attrs, args) when not is_map_key(args, "folder"), do: {:ok, attrs}

  defp folder(board, attrs, args) do
    with {:ok, ref} <- Args.optional(args, "folder") do
      if ref in [nil, "none", "root"] do
        {:ok, Map.put(attrs, "folder_id", nil)}
      else
        case Wiki.find_folder(board, ref) do
          {:ok, folder} ->
            {:ok, Map.put(attrs, "folder_id", folder.id)}

          _ ->
            with {:ok, folder} <- Args.refusal(Wiki.create_folder(board, %{"name" => ref})),
                 do: {:ok, Map.put(attrs, "folder_id", folder.id)}
        end
      end
    end
  end

  # `nil` for no move at all; otherwise the parent (nil for the top) and where
  # among its children. A position alone reorders under the parent it has.
  defp move(board, page, args) do
    with {:ok, position} <- position(args) do
      cond do
        is_map_key(args, "parent") ->
          with {:ok, parent} <- parent(board, page, args),
               do: {:ok, {parent, position || :bottom}}

        position ->
          {:ok, {page.parent_id, position}}

        true ->
          {:ok, nil}
      end
    end
  end

  defp parent(board, page, args) do
    with {:ok, ref} <- Args.optional(args, "parent") do
      if ref in [nil, "root", "none"] do
        {:ok, nil}
      else
        case Wiki.find_page(board, ref) do
          {:ok, %{id: id}} when id == page.id -> {:error, "a page can't sit under itself"}
          {:ok, parent} -> {:ok, parent}
          _ -> {:error, "no page you can see on this board matches parent #{inspect(ref)}"}
        end
      end
    end
  end

  defp position(%{"position" => n}) when is_integer(n) and n >= 0, do: {:ok, n}
  defp position(%{"position" => "top"}), do: {:ok, :top}
  defp position(%{"position" => "bottom"}), do: {:ok, :bottom}

  defp position(%{"position" => s}) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> position_error()
    end
  end

  defp position(%{"position" => nil}), do: {:ok, nil}
  defp position(%{"position" => _}), do: position_error()
  defp position(_), do: {:ok, nil}

  defp position_error, do: {:error, "position must be a number from 0, or \"top\" or \"bottom\""}

  # Pinning to a card needs only to be able to read it, as the API's pin does;
  # one the caller cannot see reads the same as one that is not there.
  defp pin_target(auth, args, key) do
    if is_map_key(args, key) do
      with {:ok, id} <- Args.id(args, key),
           {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
           :ok <- Args.refusal(Authorize.card(auth, card, :read)) do
        {:ok, card}
      end
    else
      {:ok, nil}
    end
  end

  defp restore(page, false), do: Args.refusal(Wiki.unarchive_page(page))
  defp restore(page, _), do: {:ok, page}

  defp archive(page, true), do: Args.refusal(Wiki.archive_page(page))
  defp archive(page, _), do: {:ok, page}

  defp save(page, attrs, _opts) when map_size(attrs) == 0, do: {:ok, page}
  defp save(page, attrs, opts), do: Args.refusal(Wiki.update_page(page, attrs, opts))

  defp reposition(page, nil), do: {:ok, page}

  defp reposition(page, {parent, position}),
    do: Args.refusal(Wiki.move_page(page, parent, position))

  defp pin(_page, nil, _pinned), do: :ok

  defp pin(page, card, pinned) do
    with {:ok, _} <- Args.refusal(Wiki.pin(page, {:card, card}, pinned)), do: :ok
  end

  defp pinned_to(nil, nil), do: nil
  defp pinned_to(pin, unpin), do: %{pinned: pin && pin.id, unpinned: unpin && unpin.id}

  # Recorded as made over MCP, under the token's name, as write_page's saves are.
  defp opts(args, %{user: user, token: token}) do
    [user: user, via: "mcp", agent: token.label, message: args["message"]]
  end
end
