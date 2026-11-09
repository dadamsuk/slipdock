defmodule Slipdock.Runners.Config do
  @moduledoc """
  A machine runner's configuration (#2571, W-2541, W-2544 §3): a closed,
  typed schema the server sends and the machine's daemon checks against its
  own ceiling (`Slipdock.Runners.Ceiling`).

  It is data, never code. There is no command field and no path to an
  executable: `agent` and the three hooks are *names*, which the machine's
  local file resolves (a name it doesn't define fails the job before the
  agent starts). A key the schema doesn't know, `command` included, is
  refused rather than dropped, so nobody can think they set one.

  Fields:

  - `agent`: `claude`, `codex` or the name of a custom command in the
    machine's local file
  - `directory`: the working directory, an absolute path with no `..`
  - `permission_mode`: one of `permission_modes/0`, weakest first
  - `timeout_minutes`: 1 to 1440
  - `model`: optional, a model name or alias
  - `worktree`: `auto` (a worktree per job when two runners share a
    directory), `on` or `off`
  - `verbosity`: `quiet`, `normal` or `verbose`
  - `instructions`: standing instructions appended to each prompt
  - `executor`: one of `executors/0` (W-2543)
  - `before_hook`, `after_hook`, `probe_hook`: hook names, optional
  - `image`: the container executor's image (#2577), required under it: a
    name only, which the machine runs only if it matches its own allow-list
    (`container_images` in its ceiling, which the server never sets)
  - `network`: `on` or `off`, whether a container job reaches the network
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_format ~r/^[a-z0-9][a-z0-9_-]{0,39}$/
  @model_format ~r/^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,79}$/
  @permission_modes ~w(plan default acceptEdits bypassPermissions)
  @executors ~w(me user confined container)
  @worktree ~w(auto on off)
  @verbosity ~w(quiet normal verbose)
  @network ~w(on off)
  # An image reference as Docker and Podman read one (the daemon's
  # `executor.ValidImage`): it starts with a letter or digit, so it never
  # reads as an option.
  @image_format ~r/\A(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*(?::[0-9]{1,5})?\/)?[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(?:@sha256:[a-f0-9]{64})?\z/
  @max_timeout 1440
  @max_instructions 4000

  @primary_key false
  embedded_schema do
    field :agent, :string, default: "claude"
    field :directory, :string
    field :permission_mode, :string, default: "acceptEdits"
    field :timeout_minutes, :integer, default: 60
    field :model, :string
    field :worktree, :string, default: "auto"
    field :verbosity, :string, default: "normal"
    field :instructions, :string
    field :executor, :string, default: "user"
    field :before_hook, :string
    field :after_hook, :string
    field :probe_hook, :string
    field :image, :string
    field :network, :string, default: "on"
  end

  @fields ~w(agent directory permission_mode timeout_minutes model worktree verbosity
             instructions executor before_hook after_hook probe_hook image network)a

  @doc "Every field, in order: the whole schema, which is closed."
  def fields, do: @fields

  @doc "The permission modes a runner may be given, weakest first."
  def permission_modes, do: @permission_modes

  @doc "The executors a runner may run its jobs under (W-2543)."
  def executors, do: @executors

  @doc "Whether a container job reaches the network."
  def networks, do: @network

  @doc "What an agent or a hook may be called."
  def name_format, do: @name_format

  @doc "The longest timeout anything may ask for, in minutes."
  def max_timeout, do: @max_timeout

  @doc """
  The config `attrs` describe, laid over `base` (a config map already
  stored, or nil for a new runner), as a map with string keys. Returns
  `{:ok, map}` or `{:error, message}` naming what is wrong: an unknown key,
  `command` included, a missing directory, or a value out of its type.
  """
  def build(attrs, base \\ nil)

  def build(attrs, base) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known_keys(attrs) do
      (base || %{})
      |> load()
      |> changeset(attrs)
      |> apply_action(:validate)
      |> case do
        {:ok, config} -> {:ok, dump(config)}
        {:error, changeset} -> {:error, message(changeset)}
      end
    end
  end

  def build(_attrs, _base), do: {:error, "config must be an object of fields"}

  defp known_keys(attrs) do
    known = Enum.map(@fields, &Atom.to_string/1)

    case attrs |> Map.keys() |> Enum.reject(&Enum.member?(known, &1)) |> Enum.sort() do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown config field#{if length(unknown) > 1, do: "s"}: #{Enum.join(unknown, ", ")}. " <>
           "A runner's config is data: a command or a script lives only in the machine's " <>
           "own local file, named by agent or hook"}
    end
  end

  @doc "A stored config map as the struct, with each missing field at its default."
  def load(map) when is_map(map) do
    Enum.reduce(@fields, %__MODULE__{}, fn field, config ->
      case Map.fetch(map, Atom.to_string(field)) do
        {:ok, value} -> Map.put(config, field, value)
        :error -> config
      end
    end)
  end

  @doc "The struct as a map with string keys, every field present."
  def dump(%__MODULE__{} = config),
    do: Map.new(@fields, &{Atom.to_string(&1), Map.get(config, &1)})

  defp changeset(config, attrs) do
    config
    |> cast(attrs, @fields)
    |> update_change(:directory, &trim/1)
    |> update_change(:model, &blank/1)
    |> update_change(:instructions, &blank/1)
    |> update_change(:before_hook, &blank/1)
    |> update_change(:after_hook, &blank/1)
    |> update_change(:probe_hook, &blank/1)
    |> update_change(:image, &blank/1)
    |> validate_required(
      [:agent, :directory, :permission_mode, :timeout_minutes] ++
        [:worktree, :verbosity, :executor, :network]
    )
    |> validate_format(:agent, @name_format,
      message: "must be a name: lower case, digits, - or _"
    )
    |> validate_directory()
    |> validate_inclusion(:permission_mode, @permission_modes,
      message: "must be one of #{Enum.join(@permission_modes, ", ")}"
    )
    |> validate_number(:timeout_minutes, greater_than: 0, less_than_or_equal_to: @max_timeout)
    |> validate_format(:model, @model_format, message: "must be a model name or alias")
    |> validate_inclusion(:worktree, @worktree, message: "must be auto, on or off")
    |> validate_inclusion(:verbosity, @verbosity, message: "must be quiet, normal or verbose")
    |> validate_length(:instructions, max: @max_instructions)
    |> validate_inclusion(:executor, @executors,
      message: "must be one of #{Enum.join(@executors, ", ")}"
    )
    |> validate_format(:before_hook, @name_format, message: "must be a hook name")
    |> validate_format(:after_hook, @name_format, message: "must be a hook name")
    |> validate_format(:probe_hook, @name_format, message: "must be a hook name")
    |> validate_length(:image, max: 255)
    |> validate_format(:image, @image_format,
      message: "must be an image name: registry/path:tag or @sha256:digest"
    )
    |> validate_inclusion(:network, @network, message: "must be on or off")
    |> validate_image_for_container()
  end

  # The container executor runs nothing without an image.
  defp validate_image_for_container(changeset) do
    if get_field(changeset, :executor) == "container" and is_nil(get_field(changeset, :image)),
      do: add_error(changeset, :image, "is required when executor is container"),
      else: changeset
  end

  defp validate_directory(changeset) do
    validate_change(changeset, :directory, fn :directory, dir ->
      cond do
        String.length(dir) > 500 -> [directory: "is too long (at most 500 characters)"]
        String.match?(dir, ~r/[[:cntrl:]]/u) -> [directory: "may not hold control characters"]
        not absolute?(dir) -> [directory: "must be an absolute path"]
        Enum.member?(segments(dir), "..") -> [directory: "may not contain .."]
        true -> []
      end
    end)
  end

  @doc "Whether `path` is absolute: `/…`, `~/…`, or a Windows drive `C:\\…`."
  def absolute?(path) when is_binary(path),
    do: String.match?(path, ~r{^(/|~/|~$|[A-Za-z]:[\\/])})

  def absolute?(_), do: false

  @doc "A path's segments, whichever separator it uses."
  def segments(path), do: path |> String.split(["/", "\\"]) |> Enum.reject(&(&1 == ""))

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank(value), do: value

  defp message(changeset) do
    changeset
    |> traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
