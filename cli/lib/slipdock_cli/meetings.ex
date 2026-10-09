defmodule SlipdockCLI.Meetings do
  @moduledoc false

  # `slipdock meetings` and `slipdock capture …`: meeting capture, which an
  # admin turns on per server. While it is off the server answers 404 with
  # "meeting mode is off on this server", and that sentence is what is printed.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(meetings capture)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("meetings", [], o), do: HTTP.get("/meetings") |> out(o, &render_mode/1)

  def run("capture", ["new", board], o) do
    request =
      if o[:audio] do
        audio = o[:audio]
        unless File.regular?(audio), do: fail("no file at #{audio}")

        files =
          [{"audio", Path.basename(audio), audio_type(audio), File.read!(audio)}] ++
            file_part("transcript", o[:transcript]) ++
            file_part("findings", o[:findings]) ++ file_part("ics", o[:ics])

        HTTP.post_multipart("/boards/#{enc(board)}/captures", fields(o), files)
      else
        unless o[:transcript], do: fail("capture new needs --transcript F, --audio F, or both")

        body =
          fields(o)
          |> Map.new()
          |> Map.put("transcript", read(o[:transcript]))
          |> put_if("ics", o[:ics] && read(o[:ics]))
          |> put_if("findings", o[:findings] && read(o[:findings]))

        HTTP.post("/boards/#{enc(board)}/captures", body)
      end

    out(request, o, &render_sent/1)
  end

  def run("capture", ["ls", board], o),
    do: HTTP.get("/boards/#{enc(board)}/captures") |> out(o, &render_list/1)

  def run("capture", ["show", id], o),
    do: HTTP.get("/captures/#{enc(id)}") |> out(o, &render_capture/1)

  def run("capture", ["resolve", id, question, answer], o) do
    body = compact(%{"question" => question, "answer" => answer, "replayed" => o[:replayed]})
    HTTP.post("/captures/#{enc(id)}/resolve", body) |> out(o, &render_capture/1)
  end

  def run("capture", ["include", id, finding], o),
    do:
      HTTP.post("/captures/#{enc(id)}/findings/#{enc(finding)}", %{"included" => true})
      |> out(o, &render_capture/1)

  def run("capture", ["leave-out", id, finding], o),
    do:
      HTTP.post("/captures/#{enc(id)}/findings/#{enc(finding)}", %{"included" => false})
      |> out(o, &render_capture/1)

  def run("capture", ["preview", id], o),
    do: HTTP.get("/captures/#{enc(id)}/preview") |> out(o, &render_preview/1)

  def run("capture", ["commit", id], o) do
    HTTP.post("/captures/#{enc(id)}/commit", compact(%{"preview" => o[:preview]}))
    |> out(o, fn %{"capture" => c} ->
      IO.puts("committed capture ##{c["id"]} “#{c["title"]}” — #{c["url"]}")
    end)
  end

  def run("capture", ["undo", id], o) do
    HTTP.post("/captures/#{enc(id)}/undo", if(o[:rest], do: %{"rest" => true}, else: %{}))
    |> out(o, fn %{"capture" => c} -> IO.puts("undid capture ##{c["id"]} “#{c["title"]}”") end)
  end

  def run("capture", ["retry", id], o),
    do: HTTP.post("/captures/#{enc(id)}/retry") |> out(o, &render_capture/1)

  def run("capture", ["discard", id], o) do
    HTTP.post("/captures/#{enc(id)}/discard")
    |> out(o, fn %{"capture" => c} ->
      IO.puts("discarded capture ##{c["id"]} “#{c["title"]}”: nothing from it was written")
    end)
  end

  def run("capture", ["schema"], o),
    do: HTTP.get("/meetings/findings-schema") |> out_raw(o, &IO.puts(HTTP.encode(&1)))

  def run("capture", _args, _o) do
    fail("""
    capture new <board> --transcript F | --audio F [--findings F] [--ics F] [--title T] [--when T] [--attendees A]
    capture ls <board> | show <id> | preview <id> | commit <id> [--preview D] | undo <id> [--rest]
    capture resolve <id> <question> <answer> [--replayed SPAN] | include|leave-out <id> <finding>
    capture retry <id> | discard <id> | schema
    """)
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Requests -------------------------------------------------------------------

  defp fields(o) do
    [
      {"title", o[:title]},
      {"when", o[:when]},
      {"attendees", o[:attendees]},
      {"format", o[:format]},
      {"parent", o[:with_parent] && "true"},
      {"source", "agent"}
    ]
    |> Enum.reject(fn {_, v} -> v in [nil, false] end)
  end

  defp file_part(_name, nil), do: []

  defp file_part(name, path),
    do: [{name, Path.basename(path), "application/octet-stream", read(path)}]

  # `-` reads stdin, so a transcript can be piped in.
  defp read("-"), do: IO.read(:stdio, :eof)

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _} -> fail("can't read #{path}")
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp audio_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".mp3" -> "audio/mpeg"
      ".wav" -> "audio/wav"
      ".m4a" -> "audio/mp4"
      ".flac" -> "audio/flac"
      ".ogg" -> "audio/ogg"
      ".webm" -> "audio/webm"
      ".aac" -> "audio/aac"
      _ -> "application/octet-stream"
    end
  end

  ## Output ---------------------------------------------------------------------

  defp render_mode(%{"meetings" => m}) do
    where =
      case m["visibility"] do
        "every_board" -> "on every board"
        _ -> "on boards that have had a capture (elsewhere, in the board's … menu)"
      end

    IO.puts("""
    Meeting mode: on
    Shown:        #{where}
    Hideable:     #{if m["hideable"], do: "yes#{if m["hidden"], do: " (you have hidden it)"}", else: "no"}\
    """)
  end

  defp render_sent(%{"capture" => c, "existing" => existing}) do
    open = get_in(c, ["counts", "open_questions"]) || 0

    IO.puts(
      "#{if existing, do: "already sent", else: "sent"}: capture ##{c["id"]} “#{c["title"]}” (#{c["state"]})\n" <>
        "  #{c["url"]}\n" <>
        "  questions: #{open}#{if c["state"] in ["receiving", "reading"], do: " so far — still reading; `slipdock capture show #{c["id"]}` when it is done", else: ""}"
    )
  end

  defp render_list(%{"captures" => []}), do: IO.puts("no meetings captured on this board yet")

  defp render_list(%{"captures" => list}) do
    Enum.each(list, fn c ->
      IO.puts(
        "##{c["id"]}  #{String.pad_trailing(c["state"], 12)} #{c["title"]}  #{c["started_at"] || c["received_at"]}"
      )
    end)
  end

  defp render_capture(%{"capture" => c}) do
    IO.puts(
      "capture ##{c["id"]} “#{c["title"]}” — #{c["state"]}#{if c["state_reason"], do: ": #{c["state_reason"]}", else: ""}"
    )

    IO.puts("  #{c["url"]}")

    kept = Enum.filter(c["findings"] || [], &(&1["status"] == "kept"))
    dropped = Enum.count(c["findings"] || [], &(&1["status"] == "dropped"))

    if kept != [] do
      IO.puts("\nfound:")

      Enum.each(kept, fn f ->
        mark = if f["included"], do: "[x]", else: "[ ]"
        IO.puts("  #{mark} #{f["id"]}  #{f["kind"]}: #{f["title"]}")
        if f["becomes"], do: IO.puts("        becomes → #{f["becomes"]}")

        for e <- f["evidence"] || [],
            do: IO.puts("        “#{e["quote"]}” — #{e["speaker"] || "?"}, #{e["line"]}")
      end)
    end

    if dropped > 0, do: IO.puts("\n#{dropped} dropped: their words are not in the transcript")

    open = Enum.filter(c["questions"] || [], &(&1["status"] in ["open", "waiting"]))

    if open != [] do
      IO.puts("\nto settle (slipdock capture resolve #{c["id"]} <question> <answer>):")

      Enum.each(open, fn q ->
        IO.puts(
          "  #{q["id"]}  #{q["prompt"]}#{if q["status"] == "waiting", do: " (asked the speaker)", else: ""}"
        )

        q["options"]
        |> Enum.with_index(1)
        |> Enum.each(fn {o, i} -> IO.puts("        #{i}. #{o["label"]}") end)
      end)
    end
  end

  defp render_preview(%{"preview" => p, "stale" => stale}) do
    Enum.each(p["changes"], fn c ->
      IO.puts("  " <> change_line(c))
    end)

    for l <- p["left_out"], do: IO.puts("  left out: #{l["title"]} (#{l["why"]})")

    case stale do
      [] ->
        IO.puts(
          "\nnothing has moved since the review read it. Commit with: slipdock capture commit <id> --preview #{p["digest"]}"
        )

      list ->
        Enum.each(list, &IO.puts("\nchanged since: #{&1["ref"] || &1["title"]} (#{&1["why"]})"))
    end
  end

  defp change_line(%{"op" => "create_card"} = c), do: "new card “#{c["title"]}” in #{c["list"]}"

  defp change_line(%{"op" => "update_card"} = c),
    do:
      "#{c["ref"]} “#{c["title"]}”: " <>
        Enum.map_join(Map.drop(c["fields"], ["column_id"]), "; ", fn {k, v} ->
          "#{k} #{inspect(v["from"])} → #{inspect(v["to"])}"
        end)

  defp change_line(%{"op" => "comment"} = c), do: "comment on #{c["ref"]} “#{c["title"]}”"

  defp change_line(%{"op" => "decision_entry"} = c),
    do: "#{length(c["lines_added"])} decision(s) on #{c["page_title"]}"

  defp change_line(c), do: c["op"]
end
