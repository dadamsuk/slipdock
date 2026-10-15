defmodule Slipdock.Wiki.DrawingSession do
  @moduledoc """
  A drawing that somebody has open (#821, W-1730): one process per drawing,
  found by `{:page, id}` or `{:file, id}` in `Slipdock.Wiki.DrawingRegistry`
  and started under `Slipdock.Wiki.DrawingSupervisor` by the first editor to
  join.

  It holds the scene. Editors send only the elements they changed (`push/3`);
  the session merges them by Excalidraw's rule (`Slipdock.Wiki.Excalidraw.Reconcile`)
  and sends the ones that won to every other editor, as

    * `{:drawing_session, :elements, elements, files}` — changes to apply;
    * `{:drawing_session, :saved, base}` — everything so far is saved;
    * `{:drawing_session, :warning, text}` / `{:drawing_session, :error, text}`.

  It saves by itself: `idle_ms` (2 s) after the last change, and at least
  every `max_ms` (15 s) while changes keep coming — `config :slipdock,
  :drawing_sessions`. A save goes through `Wiki.update_page/3` (a page keeps
  its encoding and prose) or `Files.replace/3` (a `.excalidraw` file), so a
  burst is one revision, attributed to the editor whose change was last and
  naming everybody who drew in it. Each save is made against the hash the
  session last saw; a write that got in first (a vault sync, the API, an
  agent) is merged in as one more set of incoming elements (`outside_write/1`)
  and the save made again, so neither side is lost. A write that is not a
  scene stays as the page's revision, editors are warned, and the next save
  puts the drawing back.

  Permission is checked when an editor joins and on every push: a reader
  gets the changes but may not send any. When the last editor leaves, the
  session saves what it has and stops. It is not restarted after a crash:
  the editors see it go, join again (which starts a fresh one from the last
  save), and send their whole scene, which the merge makes harmless.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Slipdock.{Config, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Wiki.{Drawings, Excalidraw, Files, Page, WikiFile}
  alias Slipdock.Wiki.Excalidraw.Reconcile

  @registry Slipdock.Wiki.DrawingRegistry
  @supervisor Slipdock.Wiki.DrawingSupervisor

  @type key :: {:page, pos_integer} | {:file, pos_integer}

  ## Client -------------------------------------------------------------------

  @doc """
  Joins the drawing `key` as `user`, from the calling process, starting its
  session if nobody else has it open. Returns the session (monitor it: if it
  goes, join again and push the whole scene), the scene as it now stands,
  and whether `user` may change it.
  """
  @spec join(key, User.t()) ::
          {:ok, pid, %{scene: map, base: String.t() | nil, can_write: boolean}}
          | {:error, :not_found | :forbidden | :unreadable}
  def join(key, %User{} = user), do: join(key, user, 5)

  defp join(key, user, tries) do
    with {:ok, pid} <- ensure_started(key) do
      try do
        case GenServer.call(pid, {:join, self(), user}) do
          {:ok, snapshot} -> {:ok, pid, snapshot}
          {:error, _} = error -> error
        end
      catch
        # Caught on its way out (saving as the last editor left, or just
        # gone and not yet out of the registry): a moment, then a new one.
        :exit, _ when tries > 1 ->
          Process.sleep(10 * (6 - tries))
          join(key, user, tries - 1)
      end
    end
  end

  defp ensure_started(key) do
    case whereis(key) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        callers = [self() | Process.get(:"$callers", [])]

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {key, callers}}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} when reason in [:not_found, :unreadable] ->
            {:error, reason}

          {:error, reason} ->
            Logger.error("Drawing #{inspect(key)} couldn't be opened: #{inspect(reason)}")
            {:error, :unreadable}
        end
    end
  end

  @doc "The session for `key`, if the drawing is open."
  def whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Sends the elements the caller changed, and any images (`files`, by id)
  they use that the session hasn't had yet. Replies with the elements the
  session already holds a newer version of, for the caller to take.
  """
  @spec push(pid, [map], map) :: {:ok, [map]} | {:error, :read_only | :not_joined}
  def push(pid, elements, files \\ %{}) when is_list(elements) and is_map(files),
    do: GenServer.call(pid, {:push, self(), elements, files})

  @doc "The scene as the session now holds it."
  def scene(pid), do: GenServer.call(pid, :scene)

  @doc "Leaves the drawing. The last to leave has it saved and the session stopped."
  def leave(pid), do: GenServer.call(pid, {:leave, self()})

  @doc "Saves now, if anything is unsaved. For tests, and for a flush on demand."
  def flush(pid), do: GenServer.call(pid, :flush)

  @doc """
  Tells the session for `key`, if there is one, that the drawing was written
  some other way, so it merges that in rather than saving over it.
  """
  def outside_write(key) do
    case whereis(key) do
      nil -> :ok
      pid -> GenServer.cast(pid, :outside_write)
    end
  end

  def start_link({key, callers}),
    do: GenServer.start_link(__MODULE__, {key, callers}, name: {:via, Registry, {@registry, key}})

  ## Server -------------------------------------------------------------------

  @impl true
  def init({key, callers}) do
    # What the joining process can reach (the test sandbox, a test's own
    # config), this process can too; elsewhere it changes nothing.
    Process.put(:"$callers", callers)

    case load(key) do
      {:ok, drawing, loaded} ->
        {:ok,
         Map.merge(loaded, %{
           key: key,
           drawing: drawing,
           editors: %{},
           dirty: false,
           drew: [],
           idle_timer: nil,
           max_timer: nil
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:join, pid, user}, _from, state) do
    drawing = refresh(state.drawing)

    if drawing && Drawings.readable?(drawing, user) do
      can_write = Drawings.writable?(drawing, user)
      ref = Process.monitor(pid)
      editors = Map.put(state.editors, pid, %{user: user, ref: ref})
      snapshot = %{scene: state.scene, base: state.base, can_write: can_write}
      {:reply, {:ok, snapshot}, %{state | editors: editors, drawing: drawing}}
    else
      {:reply, {:error, :forbidden}, state}
    end
  end

  def handle_call({:push, pid, elements, files}, _from, state) do
    with %{user: user} <- state.editors[pid],
         true <- Drawings.writable?(refresh(state.drawing) || state.drawing, user) do
      elements = Enum.filter(elements, &(is_map(&1) and is_binary(&1["id"])))
      held = Map.new(state.scene["elements"], &{&1["id"], &1})
      {merged, winners} = Reconcile.merge(state.scene["elements"], elements)
      stale = for el <- elements, Reconcile.keep_held?(held[el["id"]], el), do: held[el["id"]]
      new_files = new_files(state, files)

      if winners == [] and new_files == %{} do
        {:reply, {:ok, stale}, state}
      else
        state =
          state
          |> put_elements(merged)
          |> put_files(new_files)
          |> tell_others(pid, {:drawing_session, :elements, winners, new_files})
          |> changed_by(user)

        {:reply, {:ok, stale}, state}
      end
    else
      nil -> {:reply, {:error, :not_joined}, state}
      false -> {:reply, {:error, :read_only}, state}
    end
  end

  def handle_call({:leave, pid}, _from, state) do
    case Map.pop(state.editors, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {%{ref: ref}, editors} ->
        Process.demonitor(ref, [:flush])
        gone(%{state | editors: editors}, :ok)
    end
  end

  def handle_call(:flush, _from, state), do: {:reply, :ok, save(state)}
  def handle_call(:scene, _from, state), do: {:reply, state.scene, state}

  @impl true
  def handle_cast(:outside_write, state), do: {:noreply, absorb(state)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    case Map.pop(state.editors, pid) do
      {nil, _} -> {:noreply, state}
      {_, editors} -> gone(%{state | editors: editors})
    end
  end

  def handle_info(:save, state), do: {:noreply, save(state)}

  # The last one out saves and turns the light off.
  defp gone(state, reply \\ nil)

  defp gone(%{editors: editors} = state, reply) when map_size(editors) == 0 do
    state = save(state)
    if reply, do: {:stop, :normal, reply, state}, else: {:stop, :normal, state}
  end

  defp gone(state, nil), do: {:noreply, state}
  defp gone(state, reply), do: {:reply, reply, state}

  ## Loading ------------------------------------------------------------------

  defp load({:page, id}) do
    with %Page{} = page <- Repo.get(Page, id),
         true <- Excalidraw.page?(page) || :not_found,
         {:ok, %{scene: scene, links: links}} <- Excalidraw.parse_markdown(page.body) do
      {:ok, page,
       %{scene: scene, base: page.content_hash, good_body: page.body, linked: Map.keys(links)}}
    else
      nil -> {:error, :not_found}
      :not_found -> {:error, :not_found}
      :error -> {:error, :unreadable}
    end
  end

  defp load({:file, id}) do
    with %WikiFile{} = file <- Repo.get(WikiFile, id),
         true <- Excalidraw.name?(file.name) || :not_found,
         {:ok, json} <- File.read(Files.disk_path(file)),
         {:ok, scene} <- Excalidraw.parse_json(json) do
      {:ok, file, %{scene: scene, base: file.sha256, good_body: nil, linked: []}}
    else
      nil -> {:error, :not_found}
      :not_found -> {:error, :not_found}
      _ -> {:error, :unreadable}
    end
  end

  defp load({_kind, _id}), do: {:error, :not_found}

  defp refresh(%Page{id: id}), do: Repo.get(Page, id)
  defp refresh(%WikiFile{id: id}), do: Repo.get(WikiFile, id)

  ## Changing -----------------------------------------------------------------

  defp put_elements(state, elements), do: put_in(state.scene["elements"], elements)

  defp put_files(state, files) when files == %{}, do: state

  defp put_files(state, files),
    do: %{state | scene: Map.update(state.scene, "files", files, &Map.merge(&1 || %{}, files))}

  # Images are sent once each: only ids the scene hasn't got, carrying data,
  # and never one a note links rather than carries.
  defp new_files(state, files) do
    held = state.scene["files"] || %{}

    for {id, %{"dataURL" => "data:" <> _} = file} <- files,
        not Map.has_key?(held, id),
        id not in state.linked,
        into: %{},
        do: {id, file}
  end

  defp tell_others(state, from, message) do
    for {pid, _} <- state.editors, pid != from, do: send(pid, message)
    state
  end

  defp tell_all(state, message), do: tell_others(state, nil, message)

  # The debounce: a save `idle_ms` after the last change, and none later than
  # `max_ms` after the first unsaved one.
  defp changed_by(state, user) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    idle = Process.send_after(self(), :save, setting(:idle_ms, 2_000))
    max = state.max_timer || Process.send_after(self(), :save, setting(:max_ms, 15_000))
    drew = if user, do: [user | Enum.reject(state.drew, &(&1.id == user.id))], else: state.drew
    %{state | dirty: true, drew: drew, idle_timer: idle, max_timer: max}
  end

  defp setting(key, default), do: Config.get(:drawing_sessions, [])[key] || default

  ## Saving -------------------------------------------------------------------

  defp save(%{dirty: false} = state), do: clear_timers(state)

  defp save(state) do
    state = clear_timers(state)

    case write(state, 2) do
      {:ok, state} ->
        tell_all(%{state | dirty: false, drew: []}, {:drawing_session, :saved, state.base})

      {:error, state, message} ->
        Logger.warning("Drawing #{inspect(state.key)} wasn't saved: #{message}")
        tell_all(state, {:drawing_session, :error, message})
        # Try again in a while rather than losing it.
        %{state | max_timer: Process.send_after(self(), :save, setting(:max_ms, 15_000))}
    end
  end

  defp clear_timers(state) do
    for timer <- [state.idle_timer, state.max_timer], timer, do: Process.cancel_timer(timer)
    %{state | idle_timer: nil, max_timer: nil}
  end

  defp write(state, tries) do
    case write_once(state) do
      {:ok, base, drawing, body} ->
        {:ok, %{state | base: base, drawing: drawing, good_body: body || state.good_body}}

      # Written meanwhile, and not heard of yet: take it in and go again.
      :conflict when tries > 1 ->
        write(absorb(state), tries - 1)

      :conflict ->
        {:error, state, "This drawing kept changing elsewhere while it was being saved."}

      {:error, message} ->
        {:error, state, message}
    end
  end

  defp write_once(%{drawing: %Page{id: id}} = state) do
    current = Repo.get(Page, id)
    json = Jason.encode!(state.scene, pretty: true)
    source = if Excalidraw.parse_markdown(current && current.body) == :error, do: state.good_body

    with %Page{} <- current,
         {:ok, body} <- Excalidraw.write_markdown(source || current.body, json),
         {:ok, saved} <-
           Wiki.update_page(current, %{"body" => body},
             user: List.first(state.drew),
             via: "web",
             base_hash: state.base,
             message: drawn_by(state.drew),
             drawing_session: true
           ) do
      {:ok, saved.content_hash, saved, saved.body}
    else
      nil -> {:error, "The drawing is no longer there."}
      :error -> {:error, "The drawing couldn't be written back into its note."}
      {:error, :conflict, _} -> :conflict
      {:error, _status, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "The drawing couldn't be saved."}
    end
  end

  defp write_once(%{drawing: %WikiFile{id: id}} = state) do
    with %WikiFile{} = current <- Repo.get(WikiFile, id),
         true <- current.sha256 == state.base || :conflict do
      path = Path.join(System.tmp_dir!(), "drawing-#{System.unique_integer([:positive])}")
      File.write!(path, Jason.encode!(state.scene, pretty: true))

      try do
        case Files.replace(current, %{}, path, drawing_session: true) do
          {:ok, saved} -> {:ok, saved.sha256, saved, nil}
          {:error, _} -> {:error, "The drawing couldn't be saved."}
        end
      after
        File.rm(path)
      end
    else
      nil -> {:error, "The drawing is no longer there."}
      :conflict -> :conflict
    end
  end

  defp drawn_by(users) when length(users) < 2, do: nil

  defp drawn_by(users),
    do:
      "Drawn together: " <> (users |> Enum.reverse() |> Enum.map_join(", ", &User.display_name/1))

  ## Writes made some other way ----------------------------------------------

  # The drawing as it now stands on disk is merged in like any other incoming
  # elements: what it changed reaches the editors, and what the session holds
  # that it lacks goes into the next save. A write that is no scene is left as
  # it is (it is a revision now), the editors are warned, and the next save
  # — the next change anybody makes — draws the scene back into the last
  # note that held one.
  defp absorb(state) do
    case load(state.key) do
      {:ok, drawing, loaded} ->
        incoming = loaded.scene["elements"]
        {merged, winners} = Reconcile.merge(state.scene["elements"], incoming)
        files = Map.drop(loaded.scene["files"] || %{}, Map.keys(state.scene["files"] || %{}))

        state =
          %{state | drawing: drawing, base: loaded.base, linked: loaded.linked}
          |> Map.put(:good_body, loaded.good_body || state.good_body)
          |> put_elements(merged)
          |> put_files(files)

        if winners != [] or files != %{},
          do: tell_all(state, {:drawing_session, :elements, winners, files})

        # Anything only the session holds still has to be written, by
        # somebody who may.
        hand = last_hand(state)
        if hand && behind?(merged, incoming), do: changed_by(state, hand), else: state

      {:error, :unreadable} ->
        drawing = refresh(state.drawing)

        tell_all(
          state,
          {:drawing_session, :warning,
           "This drawing was overwritten elsewhere with something that isn't a drawing. That version is kept in its history; the next change here saves the drawing over it."}
        )

        # Left as it is until somebody draws (or had drawn and not yet saved):
        # then the scene goes back into the last note that held one.
        %{state | drawing: drawing || state.drawing, base: base(drawing) || state.base}

      {:error, :not_found} ->
        tell_all(state, {:drawing_session, :error, "This drawing has been deleted."})
        state
    end
  end

  defp behind?(merged, incoming) do
    on_disk = Map.new(incoming, &{&1["id"], {&1["version"], &1["versionNonce"]}})
    Enum.any?(merged, &(on_disk[&1["id"]] != {&1["version"], &1["versionNonce"]}))
  end

  # Who a save forced by an outside write is put down to: whoever drew last
  # here, or failing that anybody still in the drawing who may write.
  defp last_hand(%{drew: [user | _]}), do: user

  defp last_hand(state) do
    Enum.find_value(state.editors, fn {_, %{user: user}} ->
      if Drawings.writable?(state.drawing, user), do: user
    end)
  end

  defp base(%Page{content_hash: hash}), do: hash
  defp base(%WikiFile{sha256: hash}), do: hash
  defp base(nil), do: nil
end
