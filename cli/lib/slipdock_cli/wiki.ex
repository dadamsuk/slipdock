defmodule SlipdockCLI.Wiki do
  @moduledoc false

  # Wiki pages and the folders they are filed in, plus the whole-board JSON
  # export and import that carry the wiki along with the cards.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Meld
  alias SlipdockCLI.Render

  @commands ~w(folder wiki page export import writeup)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  ## Wiki --------------------------------------------------------------------
  #
  # `<page>` is whatever handle you have: the code (W-31), the slug, or
  # board-code/slug. Reads print Markdown, because that is what an agent
  # edits and what a diff is taken of.

  # Filing. A folder is named by id, slug, name, or a path of names
  # ("Design/Decisions"), which is what a person would say out loud.

  def run("folder", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/folders", archived: archived_param(o))
    |> out(o, &Render.folders(&1["folders"], &1["pages"]))
  end

  # One level of the tree, as the browser's tree loads it: what opening the
  # root, a folder or a page shows, with how much is under each row.
  def run("folder", ["open", ref | folder], o) do
    query =
      case {folder, o[:page]} do
        {[], nil} -> []
        {[], page} -> [page: page]
        {words, _} -> [folder: Enum.join(words, " ")]
      end

    HTTP.get(
      "/boards/#{enc(ref)}/tree",
      query ++ [archived: if(o[:archived] || o[:all], do: "all")]
    )
    |> out(o, &Render.tree_rows(&1["rows"]))
  end

  def run("folder", ["new", ref | name_words], o) when name_words != [] do
    body =
      compact(%{
        "name" => Enum.join(name_words, " "),
        "parent" => o[:parent],
        "icon" => o[:icon],
        "color" => o[:color]
      })

    HTTP.post("/boards/#{enc(ref)}/folders", body) |> out(o, &Render.folder(&1["folder"]))
  end

  def run("folder", ["mv", ref, folder], o) do
    if is_binary(o[:board]), do: folder_to_board(ref, folder, o), else: folder_mv(ref, folder, o)
  end

  # One folder: its path, and the folders it is also filed in (#808).
  def run("folder", ["show", ref | folder], o) when folder != [] do
    HTTP.get("/boards/#{enc(ref)}/folders/#{path_enc(Enum.join(folder, " "))}")
    |> out(o, &Render.folder(&1["folder"]))
  end

  # Also filed in (#808): a folder has one home (its parent) and may be
  # filed in other folders as well, like a symbolic link — one folder, with
  # everything in it, in several places. --also and --not-in repeat.
  def run("folder", ["file", ref | folder], o) when folder != [] do
    also = Keyword.get_values(o, :also)
    not_in = Keyword.get_values(o, :not_in)

    if also == [] and not_in == [],
      do:
        fail("say where: --also PATH to file it in one more folder, --not-in PATH to take it out")

    "/boards/#{enc(ref)}/folders/#{path_enc(Enum.join(folder, " "))}"
    |> file_folder(Enum.map(also, &{"also", &1}) ++ Enum.map(not_in, &{"not_in", &1}), o[:board])
    |> out(o, &Render.folder(&1["folder"]))
  end

  def run("folder", ["rm", ref, folder], o) do
    folder_rm(ref, folder, o)
  end

  # Sort what is filed in a folder (#791): by date, tag, flattening, or the
  # AI's suggestions. --dry-run prints the plan and moves nothing.
  def run("folder", ["organise", ref | folder], o) when folder != [] do
    unless is_binary(o[:by]), do: fail("organise needs --by date|ai|tag|flatten")

    body =
      compact(%{
        "folder" => Enum.join(folder, " "),
        "mode" => o[:by],
        "parent" => if(o[:root], do: "", else: o[:parent]),
        "granularity" => o[:per],
        "source" => if(o[:added], do: "added"),
        "dry_run" => o[:dry_run]
      })

    HTTP.post("/boards/#{enc(ref)}/organise", body) |> out(o, &Render.organise/1)
  end

  def run("folder", _args, _o),
    do:
      fail(
        "usage: slipdock folder ls BOARD | show BOARD F | file BOARD F --also G|--not-in G [--board B] | open BOARD [F] [--page P] | new BOARD NAME [--parent F] [--icon I] [--color C] | mv BOARD F --parent G|--root|--name N|--icon I|--no-icon|--color C|--no-color|--board B [--contents] | rm BOARD F [--purge] | organise BOARD F --by date|ai|tag|flatten [--parent G|--root] [--per month|year|year_month|day] [--added] [--dry-run]"
      )

  # Every board's wiki at once: what the Wiki view on the web shows.
  def run("wiki", [], o),
    do: HTTP.get("/wiki") |> out(o, &Render.wiki(&1["boards"]))

  def run("wiki", _args, _o), do: fail("usage: slipdock wiki")

  def run("page", ["ls", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/pages",
      q: o[:q] || o[:search],
      archived: archived_param(o),
      template: if(o[:template], do: "true"),
      status: if(o[:draft], do: "draft"),
      parent: if(o[:root], do: "root", else: o[:parent]),
      folder: if(o[:no_folder], do: "none", else: o[:folder]),
      note_tag: o[:note_tag],
      recent: if(o[:recent], do: "true")
    )
    |> out(o, &Render.pages(&1["pages"]))
  end

  # The quick switcher from a shell: a few letters of a note's title, an
  # alias or its path, across the board's vault.
  def run("page", ["switch", ref | words], o) when words != [] do
    HTTP.get("/boards/#{enc(ref)}/pages/switch", q: Enum.join(words, " "), limit: o[:limit])
    |> out(o, fn
      %{"matches" => []} ->
        IO.puts(Render.dim("no note's title, alias or path matches"))

      %{"matches" => matches} ->
        Enum.each(matches, fn m ->
          via =
            case m["matched"] do
              "alias:" <> name -> Render.dim("  (alias #{name})")
              _ -> ""
            end

          IO.puts(
            String.pad_trailing(m["code"] || "", 8) <>
              " " <> m["title"] <> via <> "  " <> Render.dim("#{m["path"]} · #{m["board"]}")
          )
        end)
    end)
  end

  # The tags notes give themselves on a board in a vault: front matter `tags`
  # and inline `#tags`, apart from the board's card tags.
  def run("page", ["tags", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/pages/tags")
    |> out(o, fn
      %{"tags" => []} ->
        IO.puts(Render.dim("no note tags — they are read on boards that are in a vault"))

      %{"tags" => tags} ->
        Enum.each(tags, fn t ->
          IO.puts(String.pad_trailing("#" <> t["tag"], 32) <> " #{t["count"]}")
        end)
    end)
  end

  def run("page", ["tree", ref], o) do
    HTTP.get("/boards/#{enc(ref)}/pages", tree: "true", archived: archived_param(o))
    |> out(o, &Render.page_tree(&1["pages"]))
  end

  def run("page", ["read", ref], o),
    do: HTTP.get("/pages/#{enc(ref)}") |> out(o, &Render.page(&1["page"]))

  # Front matter: the YAML a page's file came with, kept exactly as it was
  # written. Printed bare, so it can be edited and sent back with --file.
  def run("page", ["props", ref], o) do
    yaml = page_body(o)

    cond do
      o[:clear] ->
        HTTP.patch("/pages/#{enc(ref)}", %{"front_matter" => ""})
        |> out(o, &page_ok("cleared the properties of", &1))

      yaml ->
        HTTP.patch("/pages/#{enc(ref)}", %{"front_matter" => yaml})
        |> out(o, &page_ok("saved the properties of", &1))

      true ->
        HTTP.get("/pages/#{enc(ref)}")
        |> out(o, fn %{"page" => page} ->
          case page["front_matter"] do
            nil -> IO.puts(:stderr, "#{page["code"]} has no front matter")
            yaml -> IO.puts(yaml)
          end
        end)
    end
  end

  # `read` is the source you would edit; `render` is what it says once every
  # reference has been followed. Answering a question wants the second.
  def run("page", ["render", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/render", format: o[:format])
    |> out(o, fn r -> IO.puts(r["body"] || "") end)
  end

  def run("page", ["sections", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/sections")
    |> out(o, &Render.sections(&1["sections"]))
  end

  def run("page", ["section", ref | path_words], o) when path_words != [] do
    path = path_words |> Enum.join(" ") |> section_path()

    cond do
      # Appending is the write that cannot conflict, so it is its own flag
      # rather than a mode of the replacing one.
      o[:append] ->
        HTTP.post(
          "/pages/#{enc(ref)}/section/#{path}",
          compact(%{
            "body" => o[:append],
            "message" => o[:message]
          })
        )
        |> out(o, &page_ok("appended to #{Enum.join(path_words, " ")} of", &1))

      body = page_body(o) ->
        HTTP.put(
          "/pages/#{enc(ref)}/section/#{path}",
          compact(%{
            "body" => body,
            "message" => o[:message],
            "base_hash" => o[:base_hash]
          })
        )
        |> out(o, &page_ok("replaced #{Enum.join(path_words, " ")} of", &1))

      true ->
        HTTP.get("/pages/#{enc(ref)}/section/#{path}")
        |> out(o, fn r -> IO.puts(r["body"] || "") end)
    end
  end

  def run("page", ["append", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should be added? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post(
          "/pages/#{enc(ref)}/append",
          compact(%{
            "body" => body,
            "message" => o[:message]
          })
        )
        |> out(o, &page_ok("appended to", &1))
    end
  end

  # Meld Encrypt (W-103 R6.8): done here, with the passphrase asked for on
  # this machine. The server is sent ciphertext, or with `decrypt
  # --in-place` the plaintext the person has chosen to put back.
  def run("page", ["encrypt", ref], o) do
    if hint_problem = Meld.check_hint(o[:hint]), do: fail(hint_problem)
    {page, text} = meld_text(ref, o)
    if refusal = Meld.refuse_encrypt(text), do: fail(refusal)

    passphrase = meld_passphrase(o, twice: true)
    encrypted = Meld.encrypt_text(text, passphrase, o[:hint] || "")
    saved = meld_save(ref, page, encrypted, o, "encrypted #{meld_where(o)}")
    page_ok("encrypted #{meld_where(o)} of", saved)
    meld_history(ref, saved["page"], String.trim(text), o)
  end

  def run("page", ["decrypt", ref], o) do
    {page, text} = meld_text(ref, o)
    if not Meld.encrypted?(text), do: fail("there is no encrypted text in #{meld_where(o)}")

    case Meld.decrypt_all(text, meld_passphrase(o, [])) do
      {:error, n} ->
        fail(
          "that passphrase doesn't open #{if n == 1, do: "it", else: "#{n} of the encrypted blocks"}"
        )

      {:ok, plain} ->
        if o[:in_place] do
          saved = meld_save(ref, page, plain, o, "removed the encryption from #{meld_where(o)}")
          page_ok("removed the encryption from #{meld_where(o)} of", saved)
        else
          IO.write(plain)
        end
    end
  end

  def run("page", ["links", ref], o),
    do: HTTP.get("/pages/#{enc(ref)}/links") |> out(o, &Render.page_links/1)

  def run("page", ["pin", ref], o) do
    target =
      cond do
        o[:card] -> %{"card" => o[:card]}
        o[:page] -> %{"page" => o[:page]}
        true -> fail("pin it to what? --card N or --page P")
      end

    HTTP.post("/pages/#{enc(ref)}/links", Map.put(target, "pinned", o[:off] != true))
    |> out(o, fn r ->
      IO.puts("#{if r["pinned"], do: "pinned", else: "unpinned"} #{r["page"]["code"]}")
    end)
  end

  # A live query block is answered when the page is *read*, with the reader's
  # own permissions. These two are how to get one right before writing it.
  # A page can sit in one of its board's lists and be dragged about like a
  # card. It stays where it is in the wiki either way.
  def run("page", ["place", ref | column_words], o) when column_words != [] do
    HTTP.post(
      "/pages/#{enc(ref)}/place",
      compact(%{"column" => Enum.join(column_words, " "), "before" => o[:before]})
    )
    |> out(o, fn r ->
      IO.puts("put #{r["page"]["code"]} #{r["page"]["title"]} in #{r["column"]["name"]}")
    end)
  end

  def run("page", ["unplace", ref], o) do
    HTTP.delete("/pages/#{enc(ref)}/place")
    |> out(o, fn r ->
      IO.puts("took #{r["page"]["code"]} #{r["page"]["title"]} off the board")
    end)
  end

  def run("page", ["publish", ref], o) do
    HTTP.post("/pages/#{enc(ref)}/publish", %{"published" => o[:off] != true})
    |> out(o, fn r ->
      if r["published"] do
        IO.puts("published #{r["page"]["code"]} at #{HTTP.base_url()}#{r["url"]}")
        IO.puts(Render.dim(r["note"]))
      else
        IO.puts("withdrew the link for #{r["page"]["code"]}")
      end
    end)
  end

  # Whole board trees out as one JSON document and back in again. The wiki's
  # own `page export`/`page import` below is the Markdown route and stays:
  # this one is for moving a board, that one is for reading your writing
  # somewhere else.
  def run("export", refs, o) do
    params =
      [archived: if(o[:archived] || o[:all], do: "all")] ++
        if refs == [], do: [], else: [boards: Enum.join(refs, ",")]

    HTTP.get("/export", params)
    |> out_raw(o, fn r ->
      json = Render.json_string(r["export"])

      case o[:out] do
        nil ->
          IO.puts(json)

        path ->
          File.write!(path, json)
          trees = length(r["export"]["boards"] || [])
          IO.puts("wrote #{trees} board tree(s) to #{path}")
          Enum.each(r["leaving_behind"] || [], &IO.puts(Render.dim("  " <> Render.scrub(&1))))
      end
    end)
  end

  def run("import", [path], o) do
    unless File.regular?(path), do: fail("#{path} is not a file")

    query = if o[:from], do: HTTP.encode_query(from: o[:from]), else: ""

    HTTP.post("/import" <> query, read_document(path))
    |> out(o, fn r ->
      report = r["imported"]
      from = if report["source"] in [nil, "slipdock"], do: "", else: " from #{report["source"]}"
      IO.puts("imported #{report["cards"]} card(s) and #{report["pages"]} page(s)#{from}")

      Enum.each(report["boards"] || [], fn b ->
        IO.puts("  #{b["code"]}  #{b["name"]}")
      end)

      # What could not come through. Said rather than swallowed: an import
      # that half-worked in silence is the worst of the outcomes.
      Enum.each(report["skipped"] || [], &IO.puts(Render.dim("  " <> &1)))
    end)
  end

  def run("import", _args, _o), do: fail("import <file.json> [--from trello]")

  # Out and back in: a wiki you cannot get your writing out of is one to think
  # twice about putting writing into.
  def run("page", ["export", ref], o) do
    dir = o[:dir] || fail("where should the files go? pass --dir D")

    HTTP.get("/boards/#{enc(ref)}/pages/export", archived: archived_param(o))
    |> out_raw(o, fn r ->
      # Every path is checked before anything is written, so a hostile entry
      # stops the export rather than leaving half of it on disk.
      files =
        Enum.map(r["files"], fn %{"path" => path, "body" => body} ->
          {contained!(dir, path), body}
        end)

      Enum.each(files, fn {full, body} ->
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, body)
      end)

      IO.puts("wrote #{length(r["files"])} file(s) into #{dir}")
    end)
  end

  def run("page", ["import", ref], o) do
    dir = o[:dir] || fail("where are the files? pass --dir D")
    unless File.dir?(dir), do: fail("#{dir} is not a folder")

    files =
      dir
      |> markdown_files()
      |> Enum.map(fn path ->
        %{"path" => Path.relative_to(path, dir), "body" => File.read!(path)}
      end)

    if files == [], do: fail("no .md files under #{dir}")

    HTTP.post("/boards/#{enc(ref)}/pages/import", %{
      "files" => files,
      "overwrite" => o[:overwrite] == true,
      "message" => o[:message] || "imported from #{Path.basename(dir)}"
    })
    |> out(o, fn r ->
      IO.puts("created #{length(r["created"])} page(s)")
      Enum.each(r["created"], fn p -> IO.puts("  #{p["code"]}  #{p["title"]}") end)

      if r["skipped"] != [] do
        IO.puts(Render.dim("skipped #{length(r["skipped"])}:"))

        Enum.each(r["skipped"], fn s -> IO.puts(Render.dim("  #{s["path"]} — #{s["reason"]}")) end)
      end
    end)
  end

  def run("page", ["query-help"], o),
    do: HTTP.get("/pages/query-vocabulary") |> out(o, &Render.query_help/1)

  def run("page", ["query", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should the block say? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post("/pages/query", %{"board" => ref, "body" => body})
        |> out(o, &Render.query_answer/1)
    end
  end

  def run("page", ["card", id], o),
    do: HTTP.get("/cards/#{enc(id)}/pages") |> out(o, &Render.card_pages(&1["pages"]))

  def run("page", ["from", ref, template], o) do
    HTTP.post(
      "/boards/#{enc(ref)}/pages/from-template",
      compact(%{
        "template" => template,
        "title" => o[:title],
        "card" => o[:card],
        "folder" => o[:folder],
        "values" => values_of(o),
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("wrote", &1))
  end

  def run("page", ["make-card", ref], o) do
    case page_body(o) do
      nil ->
        fail("what should the card say? pass --body TEXT, --file F, or --body - for stdin")

      body ->
        HTTP.post("/pages/#{enc(ref)}/cards", compact(%{"body" => body, "column" => o[:column]}))
        |> out(o, &card_ok("created", &1))
    end
  end

  # "Write it up": a page for a card, pinned to it. A top-level command
  # because it is a thing people ask for by name, not a mode of `page new`.
  def run("writeup", [id], o) do
    HTTP.post(
      "/cards/#{enc(id)}/pages",
      compact(%{
        "title" => o[:title],
        "template" => o[:template],
        "folder" => o[:folder],
        "summary" => o[:summary],
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("started", &1))
  end

  def run("page", ["wanted", ref], o),
    do: HTTP.get("/boards/#{enc(ref)}/pages/wanted") |> out(o, &Render.wanted(&1["wanted"]))

  def run("page", ["resolve", ref | words], o) when words != [] do
    HTTP.get("/pages/resolve", board: ref, title: Enum.join(words, " "))
    |> out(o, &Render.resolved/1)
  end

  def run("page", ["new", ref | title_words], o) when title_words != [] do
    body =
      compact(%{
        "title" => Enum.join(title_words, " "),
        "body" => page_body(o),
        "summary" => o[:summary],
        "parent" => o[:parent],
        "folder" => o[:folder],
        "status" => if(o[:draft], do: "draft"),
        "template" => o[:template] && true,
        "message" => o[:message]
      })

    HTTP.post("/boards/#{enc(ref)}/pages", body) |> out(o, &page_ok("wrote", &1))
  end

  def run("page", ["edit", ref], o) do
    flags = Keyword.get_values(o, :flag)

    body =
      compact(%{
        "title" => o[:title],
        "summary" => o[:summary],
        "body" => page_body(o),
        "status" =>
          cond do
            o[:draft] -> "draft"
            o[:publish] -> "published"
            true -> nil
          end,
        # The card facets. A page carries them so a doc on the board can be
        # grouped, filtered and sorted beside the work.
        "priority" => o[:priority],
        "folder" => if(o[:no_folder], do: "", else: o[:folder]),
        "add_flags" => if(flags != [] and o[:off] != true, do: flags),
        "remove_flags" => if(flags != [] and o[:off] == true, do: flags),
        "start_date" => if(o[:no_start], do: nil, else: o[:start]),
        "due_date" => if(o[:no_due], do: nil, else: o[:due]),
        "percent_complete" => if(o[:no_percent], do: nil, else: o[:percent]),
        "color" => if(o[:no_color], do: nil, else: o[:color]),
        "icon" => if(o[:no_icon], do: nil, else: o[:icon]),
        "assignee" => if(o[:no_assignee], do: "", else: o[:assignee]),
        "completed" => cond_bool(o[:done], o[:undone]),
        "message" => o[:message],
        "base_hash" => o[:base_hash]
      })
      |> then(fn b -> if o[:no_start], do: Map.put(b, "start_date", nil), else: b end)
      |> then(fn b -> if o[:no_due], do: Map.put(b, "due_date", nil), else: b end)
      |> then(fn b -> if o[:no_percent], do: Map.put(b, "percent_complete", nil), else: b end)
      |> then(fn b -> if o[:no_color], do: Map.put(b, "color", nil), else: b end)
      |> then(fn b -> if o[:no_icon], do: Map.put(b, "icon", nil), else: b end)

    if Map.drop(body, ["message", "base_hash"]) == %{},
      do: fail("nothing to change — pass --title, --body/--file, a facet, --draft or --publish")

    HTTP.patch("/pages/#{enc(ref)}", body) |> out(o, &page_ok("saved", &1))
  end

  # Filing a page that already exists. Separate from `mv`, which moves it in
  # the page tree: where a page is kept and what it is part of are two axes.
  # Also filed in: a page has one home folder (--folder) and may be filed in
  # others as well, like a symbolic link — one page, several places.
  def run("page", ["file", ref], o) do
    if o[:also] || o[:not_in], do: file_also(ref, o), else: file_home(ref, o)
  end

  def run("page", ["mv", ref], o) do
    if is_binary(o[:board]), do: move_to_board(ref, o), else: move_in_board(ref, o)
  end

  def run("page", ["rm", ref], o) do
    query = if o[:purge], do: [purge: "true"], else: []

    HTTP.delete("/pages/#{enc(ref)}", query)
    |> out(o, fn
      %{"deleted" => true} = r -> IO.puts("deleted #{r["code"]}")
      r -> page_ok("archived", r)
    end)
  end

  def run("page", ["restore", ref], o),
    do: HTTP.post("/pages/#{enc(ref)}/restore", %{}) |> out(o, &page_ok("restored", &1))

  def run("page", ["history", ref], o) do
    HTTP.get("/pages/#{enc(ref)}/revisions", limit: o[:limit])
    |> out(o, &Render.revisions(&1["revisions"]))
  end

  def run("page", ["diff", ref], o) do
    rev = o[:rev] || latest_revision(ref)

    # --against compares with any other version; without it, the one before.
    HTTP.get("/pages/#{enc(ref)}/revisions/#{enc(rev)}", diff: o[:against] || "previous")
    |> out(o, &Render.diff(&1["diff"] || []))
  end

  def run("page", ["revert", ref], o) do
    rev = o[:rev] || fail("which version? pass --rev N (see `slipdock page history`)")

    HTTP.post(
      "/pages/#{enc(ref)}/revert",
      compact(%{
        "revision_id" => rev,
        "message" => o[:message]
      })
    )
    |> out(o, &page_ok("reverted", &1))
  end

  def run("page", _args, _o),
    do:
      fail(
        "usage: slipdock page ls|tree|read|new|edit|file|mv|rm|restore|history|diff|revert|encrypt|decrypt (see --help)"
      )

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Wiki helpers ------------------------------------------------------------

  # The page, and the text to work on: the body, or one section without its
  # heading line.
  defp meld_text(ref, o) do
    page = fetch!("/pages/#{enc(ref)}")["page"]

    case o[:section] do
      nil ->
        {page, page["body"] || ""}

      section ->
        body = fetch!("/pages/#{enc(ref)}/section/#{section_path(section)}")["body"] || ""
        [_heading | rest] = String.split(body, "\n", parts: 2) ++ [""]
        {page, hd(rest)}
    end
  end

  defp meld_save(ref, page, text, o, message) do
    message = o[:message] || message
    hash = page["content_hash"]

    result =
      case o[:section] do
        nil ->
          HTTP.patch(
            "/pages/#{enc(ref)}",
            compact(%{"body" => text, "message" => message, "base_hash" => hash})
          )

        section ->
          heading = meld_heading(ref, section)

          HTTP.put(
            "/pages/#{enc(ref)}/section/#{section_path(section)}",
            compact(%{
              "body" => heading <> "\n" <> text,
              "message" => message,
              "base_hash" => hash
            })
          )
      end

    case result do
      {:ok, saved} -> saved
      error -> out(error, o, fn _ -> :ok end)
    end
  end

  defp meld_heading(ref, section) do
    body = fetch!("/pages/#{enc(ref)}/section/#{section_path(section)}")["body"] || ""
    body |> String.split("\n", parts: 2) |> hd()
  end

  defp meld_where(o), do: if(o[:section], do: "section #{o[:section]}", else: "the page")

  defp meld_passphrase(o, opts) do
    case Meld.passphrase(o, opts) do
      {:ok, passphrase} -> passphrase
      {:error, why} -> fail(why)
    end
  end

  # Encrypting text that was already on the page leaves it in the page's
  # earlier revisions. They are matched here, so the text is not sent; with
  # --purge-history (the board's owner only) they are deleted, otherwise
  # the count is said.
  defp meld_history(ref, page, plain, o) do
    held =
      case HTTP.get("/pages/#{enc(ref)}/revisions", bodies: "all") do
        {:ok, %{"revisions" => revisions}} ->
          revisions
          |> Enum.drop(-1)
          |> Enum.filter(&String.contains?(&1["body"] || "", plain))
          |> Enum.map(& &1["id"])

        _ ->
          []
      end

    cond do
      held == [] ->
        :ok

      o[:purge_history] ->
        HTTP.post("/pages/#{enc(ref)}/revisions/purge", %{"ids" => held})
        |> out(o, fn %{"purged" => n} ->
          IO.puts(
            "purged #{n} earlier #{if n == 1, do: "revision", else: "revisions"} of #{page["code"]} that held the text in plain"
          )
        end)

      true ->
        IO.puts(
          :stderr,
          "note: #{if length(held) == 1, do: "1 earlier revision", else: "#{length(held)} earlier revisions"} of #{page["code"]} " <>
            "#{if length(held) == 1, do: "still holds", else: "still hold"} the text in plain. " <>
            "The board's owner can delete them: run this again with --purge-history, or purge them from the web editor."
        )
    end
  end

  # The body can be given outright, read from a file, or piped in — the last
  # is how an agent writes a document without quoting a page of Markdown.
  defp page_body(o) do
    cond do
      o[:file] == "-" -> IO.read(:stdio, :eof) |> body_text()
      o[:file] -> File.read!(o[:file])
      o[:body] == "-" -> IO.read(:stdio, :eof) |> body_text()
      o[:body] -> o[:body]
      true -> nil
    end
  end

  defp body_text(:eof), do: ""
  defp body_text(text) when is_binary(text), do: text
  defp body_text(_), do: fail("could not read the body from stdin")

  defp latest_revision(ref) do
    case fetch!("/pages/#{enc(ref)}/revisions?limit=1") do
      %{"revisions" => [%{"id" => id} | _]} -> to_string(id)
      _ -> fail("that page has no history yet")
    end
  end

  # A section path is the rest of the route, so each level is its own segment.
  defp section_path(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("/", &HTTP.seg/1)
  end

  # `--set key=value`, repeatable, for a template's {{placeholders}}.
  defp values_of(o) do
    case Keyword.get_values(o, :set) do
      [] ->
        nil

      pairs ->
        Map.new(pairs, fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> {String.trim(k), v}
            [k] -> {String.trim(k), ""}
          end
        end)
    end
  end

  defp markdown_files(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        File.dir?(path) -> markdown_files(path)
        String.ends_with?(String.downcase(name), [".md", ".markdown"]) -> [path]
        true -> []
      end
    end)
  end

  defp archived_param(o) do
    cond do
      o[:all] -> "all"
      o[:archived] -> "true"
      true -> nil
    end
  end

  # A portable export, read off disk. Same shape of care as `decode_spec/1`:
  # say which of "missing", "not JSON" and "not an object" went wrong.
  defp read_document(path) do
    case :json.decode(File.read!(path)) do
      %{} = document -> document
      _ -> fail("#{path} does not hold a JSON object — an export is one")
    end
  rescue
    e in [File.Error] -> fail("couldn't read #{path}: #{Exception.message(e)}")
    _ -> fail("#{path} isn't valid JSON")
  end

  defp file_also(ref, o) do
    body =
      compact(%{
        "also" => o[:also],
        "not_in" => o[:not_in],
        "board" => o[:board],
        "folder" => o[:folder]
      })

    HTTP.post("/pages/#{enc(ref)}/folder", body)
    |> out(o, fn %{"page" => page} = r ->
      page_ok("filed", r)

      for f <- page["also_in"] || [],
          do: IO.puts("  also in " <> f["path"] <> "  " <> Render.dim(f["board"] || ""))
    end)
  end

  defp file_home(ref, o) do
    if is_nil(o[:folder]) and o[:no_folder] != true and o[:root] != true,
      do:
        fail(
          "say where: --folder PATH, --no-folder to take it out of one, " <>
            "or --also PATH / --not-in PATH for the folders it is also filed in"
        )

    body = %{"folder" => if(o[:no_folder] || o[:root], do: nil, else: o[:folder])}

    HTTP.post("/pages/#{enc(ref)}/folder", body) |> out(o, &page_ok("filed", &1))
  end

  @doc false
  # A folder moved to another board, or what moving it would do.
  def print_folder_move(%{"report" => r, "board" => board} = reply, folder) do
    dry? = reply["dry_run"] == true

    IO.puts(
      if dry?,
        do: "moving #{folder} to #{board} would move:",
        else: "moved #{folder} to #{board}:"
    )

    IO.puts("  #{r["folders"]} folder(s), #{r["pages"]} page(s), #{r["files"]} file(s)")

    for f <- r["per_folder"] || [], f["pages"] > 0, do: IO.puts("    #{f["path"]}: #{f["pages"]}")

    report_line("carry tags", r["tags"]["carried"])
    report_line("drop tags", r["tags"]["dropped"])
    report_line("carry fields", r["fields"]["carried"])
    report_line("drop field values", r["fields"]["dropped"])
    report_line("unpin cards", r["pins"]["dropped"])
    report_line("let go of assignees", r["assignees"]["dropped"])
    report_line("leave behind (under a page that stays)", r["left_behind"])
    report_line("land beside pages of the same title", r["title_clashes"])

    if r["filing_dropped"] > 0,
      do: IO.puts("  take away #{r["filing_dropped"]} filing(s) in folders across boards")
  end

  defp report_line(_what, []), do: :ok
  defp report_line(what, items), do: IO.puts("  #{what}: #{Enum.join(items, ", ")}")

  # To another board of the page's vault: it keeps its code, history and
  # comments; --dry-run says what its tags, fields, pins and so on would do.
  defp move_to_board(ref, o) do
    body = compact(%{"board" => o[:board], "folder" => o[:folder], "dry_run" => o[:dry_run]})

    HTTP.post("/pages/#{enc(ref)}/move", body)
    |> out(o, fn
      %{"dry_run" => true, "report" => r, "board" => board} ->
        IO.puts("moving it to #{board} would:")
        if r["pages"] > 1, do: IO.puts("  take #{r["pages"] - 1} page(s) under it along")
        report_line("carry tags", r["tags"]["carried"])
        report_line("drop tags", r["tags"]["dropped"])
        report_line("carry fields", r["fields"]["carried"])
        report_line("drop field values", r["fields"]["dropped"])
        report_line("unpin cards", r["pins"]["dropped"])
        report_line("let go of its assignee", List.wrap(r["assignee"]["dropped"]))
        report_line("leave its list", List.wrap(r["list"]))
        report_line("leave its parent page", List.wrap(r["parent"]))

      r ->
        page_ok("moved", r)
    end)
  end

  defp move_in_board(ref, o) do
    if is_nil(o[:parent]) and o[:root] != true and is_nil(o[:position]),
      do:
        fail("say where: --parent P, --root, --position N|top|bottom, or --board B [--folder F]")

    body =
      compact(%{
        "parent" => if(o[:root], do: "root", else: o[:parent]),
        "position" => o[:position]
      })

    HTTP.post("/pages/#{enc(ref)}/move", body) |> out(o, &page_ok("moved", &1))
  end

  defp folder_to_board(ref, folder, o) do
    body =
      compact(%{
        "to_board" => o[:board],
        "parent" => o[:parent],
        "contents" => o[:contents],
        "dry_run" => o[:dry_run]
      })

    HTTP.patch("/boards/#{enc(ref)}/folders/#{path_enc(folder)}", body)
    |> out(o, &print_folder_move(&1, folder))
  end

  defp folder_mv(ref, folder, o) do
    if is_nil(o[:parent]) and o[:root] != true and is_nil(o[:name]) and is_nil(o[:sort]) and
         Enum.all?([:icon, :no_icon, :color, :no_color], &is_nil(o[&1])),
       do:
         fail(
           "say what to change: --parent P, --root, --name N, --sort board|manual|name|modified|created, --icon I, --no-icon, --color C or --no-color"
         )

    body =
      compact(%{
        "name" => o[:name],
        "parent" => if(o[:root], do: "root", else: o[:parent]),
        "position" => o[:position],
        "sort" => o[:sort],
        "icon" => o[:icon],
        "color" => o[:color]
      })
      # Cleared is said as "": nil would be dropped as not sent.
      |> then(&if(o[:no_icon], do: Map.put(&1, "icon", ""), else: &1))
      |> then(&if(o[:no_color], do: Map.put(&1, "color", ""), else: &1))

    HTTP.patch("/boards/#{enc(ref)}/folders/#{path_enc(folder)}", body)
    |> out(o, &Render.folder(&1["folder"]))
  end

  @doc """
  Each `{"also" | "not_in", place}` change to the folder at `path`, in turn,
  stopping at the first refusal: the last answer, for `out/3`.
  """
  def file_folder(path, steps, board) do
    Enum.reduce_while(steps, nil, fn {key, place}, _last ->
      case HTTP.patch(path, compact(%{key => place, "in_board" => board})) do
        {:ok, _} = ok -> {:cont, ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp folder_rm(ref, folder, o) do
    query = if o[:purge], do: [purge: "true"], else: []

    HTTP.delete("/boards/#{enc(ref)}/folders/#{path_enc(folder)}", query)
    |> out(o, fn
      %{"purged" => purged} = r ->
        IO.puts(
          "deleted the folder #{r["deleted"]["path"]} and everything in it " <>
            "— #{purged["pages"]} page(s), #{purged["folders"]} subfolder(s)"
        )

      r ->
        IO.puts("deleted the folder #{r["deleted"]["path"]} — nothing in it was deleted")
    end)
  end
end
