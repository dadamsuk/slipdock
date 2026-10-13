defmodule SlipdockCLI.Sync.State do
  @moduledoc false

  alias SlipdockCLI.FS

  # A mirror's memory, in `<dir>/.slipdock/state.json` (W-103 R2.3): which
  # server and vault the folder is bound to, the change feed's cursor, and for
  # every file the id of what it is on the server and the hash both sides
  # last agreed on. That hash is what tells "changed here", "changed there"
  # and "changed on both" apart, and the id is what makes a rename the same
  # page rather than a delete and a create. Front matter is never used for
  # identity, so the files themselves stay the writer's own.

  alias SlipdockCLI.HTTP

  @dir ".slipdock"
  @file_name "state.json"

  def dir_name, do: @dir

  def path(root), do: Path.join([root, @dir, @file_name])

  @doc "The mirror `dir` is in: it, or the nearest folder above it with a `.slipdock`."
  def find_root(dir) do
    dir = Path.expand(dir)

    cond do
      FS.exists?(path(dir)) -> {:ok, dir}
      Path.dirname(dir) == dir -> :error
      true -> find_root(Path.dirname(dir))
    end
  end

  def new(url, vault, host) do
    %{
      "version" => 1,
      "url" => url,
      "vault" => %{"id" => vault["id"], "name" => vault["name"]},
      "host" => host,
      "cursor" => nil,
      "entries" => %{},
      "conflicts" => [],
      "errors" => [],
      "last_run" => nil,
      "last_result" => nil
    }
  end

  def load(root) do
    case FS.read(path(root)) do
      {:ok, text} ->
        {state, _, ""} = :json.decode(text, :ok, %{null: nil})
        {:ok, state}

      error ->
        error
    end
  rescue
    _ -> {:error, :corrupt}
  end

  @doc "Written whole to a temp file and renamed over, so a crash never leaves half a state."
  def save(root, state) do
    FS.mkdir_p!(Path.join(root, @dir))
    target = path(root)
    tmp = target <> ".#{System.unique_integer([:positive])}.tmp"
    FS.write!(tmp, HTTP.encode(state))
    FS.rename!(tmp, target)
    state
  end
end
