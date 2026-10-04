defmodule SlipdockCLI.Util do
  @moduledoc false

  # What every command module shares: printing an API answer (or failing on
  # it), encoding path segments, and the small map/option helpers the request
  # bodies are built with. Imported by each area module.

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  def bad_usage(cmd) do
    fail("bad usage for '#{cmd}' (or unknown command). Run `slipdock --help`.")
  end

  # For the commands whose answer is written to disk as it came: an export,
  # a wiki's Markdown. Only what is printed is scrubbed.
  def out_raw({:ok, data}, o, render),
    do: if(o[:json], do: Render.json(data), else: render.(data))

  def out_raw(error, o, render), do: out(error, o, render)

  def out({:ok, data}, o, render) do
    if o[:json], do: Render.json(data), else: render.(Render.scrub(data))
  end

  def out({:error, :connect, reason}, _o, _render) do
    fail(
      "could not reach #{HTTP.base_url()} (#{inspect(reason)}). Is the server running? Set SLIPDOCK_URL or --url."
    )
  end

  # Tokens are kept per server, so a fresh address starts signed out.
  def out({:error, 401, _}, _o, _render) do
    fail(
      "not signed in to #{HTTP.origin(HTTP.base_url())}. Run `slipdock auth`, or create an API token under Account in the web UI and run: slipdock auth <token>"
    )
  end

  # A wiki save that would have landed on someone else's. Say what to do about
  # it rather than just refusing: the hash to re-base on, and where to read the
  # version that got there first.
  def out({:error, 409, %{"current" => current}}, _o, _render) do
    IO.puts(:stderr, "error: this page changed since you read it. Nothing was overwritten.")

    IO.puts(
      :stderr,
      "  it now reads #{current["title"] |> inspect()}, hash #{String.slice(to_string(current["content_hash"]), 0, 12)}"
    )

    IO.puts(:stderr, "  read it again, merge, then save with --base-hash <the new hash>")
    System.halt(1)
  end

  def out({:error, status, %{"error" => msg} = data}, _o, _render) do
    details =
      if data["details"], do: " " <> IO.iodata_to_binary(:json.encode(data["details"])), else: ""

    fail(Render.scrub("#{msg}#{details} (HTTP #{status})"))
  end

  def out({:error, status, data}, _o, _render), do: fail("HTTP #{status}: #{inspect(data)}")

  def enc(s), do: HTTP.seg(s)

  # A folder may be named by a path, and the slashes in it are part of the
  # route rather than part of one segment.
  def path_enc(s),
    do: s |> to_string() |> String.split("/", trim: true) |> Enum.map_join("/", &enc/1)

  def cond_bool(true, _), do: true
  def cond_bool(_, true), do: false
  def cond_bool(_, _), do: nil

  def nonblank(""), do: nil
  def nonblank(s), do: s

  def compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  def nonempty([]), do: nil
  def nonempty(list), do: list

  def fail(msg) do
    IO.puts(:stderr, "error: " <> msg)
    System.halt(1)
  end

  def card_ok(verb, %{"card" => c}), do: IO.puts("#{verb} " <> Render.card_line(c, true))
  def card_ok(verb, %{"page" => p}), do: page_ok(verb, %{"page" => p})

  def page_ok(verb, %{"page" => p}) do
    IO.puts("#{verb} #{p["code"]} #{p["title"]}  " <> Render.dim(p["url"]))
  end

  # Like `out/3`, but hands the body back instead of printing it; errors are
  # reported and halt exactly as they would there.
  def fetch!(path) do
    case HTTP.get(path) do
      {:ok, data} -> data
      error -> out(error, [], fn _ -> :ok end)
    end
  end

  # Where a server-supplied relative path lands under `dir`, or a refusal if
  # it would land anywhere else. The server names the files, and a server (or
  # a collaborator who titled a page `..`) must not choose where on this
  # machine they are written.
  @doc false
  def contained(dir, path) do
    root = Path.expand(dir)
    full = Path.expand(Path.join(root, to_string(path)))

    if Path.type(to_string(path)) == :relative and String.starts_with?(full, root <> "/"),
      do: {:ok, full},
      else: :error
  end

  def contained!(dir, path) do
    case contained(dir, path) do
      {:ok, full} -> full
      :error -> fail("refusing to write #{inspect(path)}: it is outside #{dir}")
    end
  end
end
