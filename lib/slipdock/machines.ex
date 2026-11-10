defmodule Slipdock.Machines do
  @moduledoc """
  Machines (#2570, epic #2569, W-2544 §1): computers running the runner
  daemon, each bound to the one account that approved it (W-2541).

  **Enrolment.** A machine is made one of two ways, and each hands the
  daemon its **machine key** exactly once:

  - by device code: `request_enrolment/1` (anonymous: the daemon names the
    machine), a signed-in person approves it with `approve_enrolment/3`,
    choosing the boards it may serve, and the daemon's polling
    (`poll_enrolment/1`) collects the key, consuming the request;
  - by a one-time enrolment key the owner made (`create_enrolment_key/3`),
    which `enrol_with_key/2` spends.

  **The key.** `sdm_` and 32 random bytes; only its SHA-256 is kept.
  `authenticate/2` is the only thing that accepts one, and refuses a revoked
  machine's at once. It is never an API token: the API's token lookup only
  reads `users_tokens`, so a machine key there is unknown.

  The boards a machine serves are top-level boards its owner can reach,
  checked when they are chosen.
  """

  import Ecto.Query

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Machines.{Enrolment, EnrolmentKey, Machine}

  @machine_prefix "sdm_"
  @enrolment_key_prefix "sde_"

  ## What a machine says about itself ------------------------------------------

  @doc """
  Cleans what a daemon says about its machine: `hostname` (required), `os`,
  `arch` and `fingerprint`. Control characters go and each is cut to its
  column, since an anonymous caller chooses them and a person reads them on
  the approval page. Returns `{:ok, map}` or `{:error, :invalid, message}`.
  """
  def describe(attrs) when is_map(attrs) do
    about = %{
      hostname: clean(attrs["hostname"] || attrs[:hostname], 100),
      os: clean(attrs["os"] || attrs[:os], 40),
      arch: clean(attrs["arch"] || attrs[:arch], 40),
      fingerprint: clean(attrs["fingerprint"] || attrs[:fingerprint], 128)
    }

    if about.hostname,
      do: {:ok, about},
      else: {:error, :invalid, "hostname is required: the name the approval page shows"}
  end

  def describe(_), do: describe(%{})

  defp clean(value, max) when is_binary(value) do
    case value |> String.replace(~r/[[:cntrl:]]/u, "") |> String.trim() |> String.slice(0, max) do
      "" -> nil
      text -> text
    end
  end

  defp clean(_, _), do: nil

  ## Boards --------------------------------------------------------------------

  @doc """
  The ids of the boards `refs` name (ids, or board codes), when every one is
  a top-level board `user` can reach. `{:error, :invalid, message}` names
  the first that isn't, and an empty choice is refused: a machine serving no
  board has nothing to do.
  """
  def servable_board_ids(%User{} = user, refs) do
    refs = refs |> List.wrap() |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1)
    refs = Enum.reject(refs, &(&1 == ""))
    boards = Access.list_boards(user, archived: :all)

    {found, missing} =
      Enum.reduce(refs, {[], []}, fn ref, {found, missing} ->
        case Enum.find(boards, &(Integer.to_string(&1.id) == ref or &1.code == ref)) do
          nil -> {found, [ref | missing]}
          board -> {[board.id | found], missing}
        end
      end)

    cond do
      refs == [] ->
        {:error, :invalid, "choose at least one board for the machine to serve"}

      missing != [] ->
        {:error, :invalid,
         "not a top-level board you're a member of: #{missing |> Enum.reverse() |> Enum.join(", ")}"}

      true ->
        {:ok, found |> Enum.reverse() |> Enum.uniq()}
    end
  end

  @doc "The boards a machine may serve that `user` can still reach, for showing."
  def boards_for(%Machine{board_ids: ids}, %User{} = user) do
    user |> Access.list_boards(archived: :all) |> Enum.filter(&Enum.member?(ids, &1.id))
  end

  ## Enrolment by device code --------------------------------------------------

  @doc """
  Starts a device-code enrolment for the machine `attrs` describe (see
  `describe/1`). Returns `{:ok, {plaintext_device_code, enrolment}}`.
  """
  def request_enrolment(attrs, client_ip \\ nil) do
    purge_expired()

    with {:ok, about} <- describe(attrs) do
      {device_code, enrolment} =
        Enrolment.build(Map.put(about, :client_ip, clean(client_ip, 255)))

      {:ok, {device_code, Repo.insert!(enrolment)}}
    end
  end

  @doc """
  The pending enrolment a person's typed code refers to, or nil. A code
  that was decided, or has expired, is not found: it is good once.
  """
  def enrolment_by_user_code(input) do
    case Slipdock.Accounts.DeviceAuthorization.normalise_code(input) do
      "" -> nil
      code -> Enrolment.pending() |> where([e], e.user_code == ^code) |> Repo.one()
    end
  end

  @doc """
  Approves a pending enrolment for `user`, who becomes the machine's owner,
  with the boards it may serve. Decided once: a second decision, racing or
  late, gets `{:error, :expired}`.
  """
  def approve_enrolment(%Enrolment{} = enrolment, %User{} = user, board_refs) do
    with {:ok, board_ids} <- servable_board_ids(user, board_refs) do
      decide(enrolment,
        approved_at: DateTime.utc_now(:second),
        user_id: user.id,
        board_ids: board_ids
      )
    end
  end

  @doc "Refuses a pending enrolment; the daemon's polling is told."
  def deny_enrolment(%Enrolment{} = enrolment),
    do: decide(enrolment, denied_at: DateTime.utc_now(:second))

  defp decide(enrolment, changes) do
    query = Enrolment.pending() |> where([e], e.id == ^enrolment.id)

    case Repo.update_all(query, set: changes) do
      {1, _} -> {:ok, Repo.get!(Enrolment, enrolment.id)}
      _ -> {:error, :expired}
    end
  end

  @doc """
  What the polling daemon gets: `{:ok, {machine_key, machine}}` once the
  enrolment is approved, consuming it in the same transaction, so a device
  code polled twice can't make two machines. Otherwise
  `{:error, :authorization_pending | :access_denied | :expired_token | :invalid}`,
  an unknown code answered as a wrong one is.
  """
  def poll_enrolment(plaintext) do
    with {:ok, hashed} <- Enrolment.hash_device_code(plaintext),
         %Enrolment{} = enrolment <- Repo.get_by(Enrolment, device_code: hashed) do
      cond do
        enrolment.denied_at -> {:error, :access_denied}
        Enrolment.expired?(enrolment) -> {:error, :expired_token}
        is_nil(enrolment.approved_at) -> {:error, :authorization_pending}
        true -> mint_from_enrolment(enrolment)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp mint_from_enrolment(enrolment) do
    Repo.transaction(fn ->
      # Whoever deletes the row is the one who gets to mint.
      case Repo.delete_all(from(e in Enrolment, where: e.id == ^enrolment.id)) do
        {1, _} ->
          Map.take(enrolment, [:hostname, :os, :arch, :fingerprint, :user_id, :board_ids])
          |> insert_machine("device_code")

        _ ->
          Repo.rollback(:invalid)
      end
    end)
  end

  @doc "Clears enrolments nobody finished. Safe at any time."
  def purge_expired do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(e in Enrolment, where: e.expires_at <= ^now))
    count
  end

  ## Enrolment by one-time key -------------------------------------------------

  @doc """
  Makes a one-time enrolment key for `user`, naming the boards the machine
  it enrols will serve. Its `label`, when given, is the name the machine
  enrols under (#2666); without one the machine is named by its hostname.
  Returns `{:ok, plaintext_key, record}`; the key is shown this once.
  """
  def create_enrolment_key(%User{} = user, board_refs, label \\ nil) do
    with {:ok, board_ids} <- servable_board_ids(user, board_refs) do
      key = new_key(@enrolment_key_prefix)

      record =
        Repo.insert!(%EnrolmentKey{
          user_id: user.id,
          key_hash: hash(key),
          label: clean(label, 60),
          board_ids: board_ids,
          expires_at:
            DateTime.utc_now(:second) |> DateTime.add(EnrolmentKey.validity_hours(), :hour)
        })

      {:ok, key, record}
    end
  end

  @doc "`user`'s enrolment keys not yet used and not lapsed, newest first."
  def list_enrolment_keys(%User{} = user) do
    now = DateTime.utc_now()

    Repo.all(
      from(k in EnrolmentKey,
        where: k.user_id == ^user.id and is_nil(k.used_at) and k.expires_at > ^now,
        order_by: [desc: k.id]
      )
    )
  end

  @doc """
  Enrols the machine `attrs` describe with a one-time key, spending it.
  `{:ok, {machine_key, machine}}`, or `{:error, :invalid}` for a key that is
  unknown, used or lapsed (one answer for all three, so trying keys teaches
  nothing), or `{:error, :invalid, message}` for a machine described badly.
  """
  def enrol_with_key(key, attrs) do
    with {:ok, about} <- describe(attrs),
         {:ok, hashed} <- hash_presented(key, @enrolment_key_prefix) do
      Repo.transaction(fn -> spend_key(hashed, about) end)
    end
  end

  # In the caller's transaction: marks the key used only if it is still
  # unused and in date, and makes the machine from it.
  defp spend_key(hashed, about) do
    now = DateTime.utc_now(:second)

    spend =
      from(k in EnrolmentKey,
        where: k.key_hash == ^hashed and is_nil(k.used_at) and k.expires_at > ^now,
        select: k
      )

    case Repo.update_all(spend, set: [used_at: now]) do
      {1, [record]} ->
        {machine_key, machine} =
          about
          |> Map.merge(%{user_id: record.user_id, board_ids: record.board_ids})
          |> Map.put(:name, record.label)
          |> insert_machine("enrolment_key")

        Repo.update_all(from(k in EnrolmentKey, where: k.id == ^record.id),
          set: [machine_id: machine.id]
        )

        {machine_key, machine}

      _ ->
        Repo.rollback(:invalid)
    end
  end

  defp insert_machine(attrs, via) do
    key = new_key(@machine_prefix)

    machine =
      Repo.insert!(%Machine{
        user_id: attrs.user_id,
        name: Map.get(attrs, :name) || attrs.hostname,
        hostname: attrs.hostname,
        os: attrs.os,
        arch: attrs.arch,
        fingerprint: attrs.fingerprint,
        board_ids: attrs.board_ids,
        enrolled_via: via,
        key_hash: hash(key)
      })

    {key, machine}
  end

  ## The machine key -----------------------------------------------------------

  @doc """
  The live machine `key` belongs to, with its last-seen time (and address)
  brought up to date, or nil: an unknown key, any other kind of token, and a
  revoked machine's key are all nil.
  """
  def authenticate(key, ip \\ nil) do
    with {:ok, hashed} <- hash_presented(key, @machine_prefix),
         %Machine{} = machine <-
           Repo.one(from(m in Machine, where: m.key_hash == ^hashed and is_nil(m.revoked_at))) do
      now = DateTime.utc_now(:second)
      ip = clean(ip, 255)

      Repo.update_all(from(m in Machine, where: m.id == ^machine.id),
        set: [last_seen_at: now, last_seen_ip: ip]
      )

      %{machine | last_seen_at: now, last_seen_ip: ip}
    else
      _ -> nil
    end
  end

  # Only a string with the right prefix is hashed and looked up, so an API
  # token or a runner token presented here is refused before the database.
  defp hash_presented(key, prefix) when is_binary(key) do
    key = String.trim(key)
    if String.starts_with?(key, prefix), do: {:ok, hash(key)}, else: {:error, :invalid}
  end

  defp hash_presented(_, _), do: {:error, :invalid}

  defp new_key(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp hash(key), do: :crypto.hash(:sha256, key)

  ## The owner's machines ------------------------------------------------------

  @doc "`user`'s machines, live ones first, newest first within each."
  def list_machines(%User{} = user) do
    Repo.all(
      from(m in Machine,
        where: m.user_id == ^user.id,
        order_by: [asc: not is_nil(m.revoked_at), desc: m.id]
      )
    )
  end

  # The daemon asks for its config every 25 seconds or so (#2571), and
  # each ask brings `last_seen_at` up to date.
  @online_within_seconds 120

  @doc """
  Whether the machine's daemon has been heard from in the last two minutes
  (it long-polls its config, so a running one is seen every half minute).
  A revoked machine is never online.
  """
  def online?(machine, now \\ DateTime.utc_now())

  def online?(%Machine{revoked_at: nil, last_seen_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) <= @online_within_seconds

  def online?(%Machine{}, _now), do: false

  @doc "One of `user`'s machines, by id."
  def get_machine(%User{} = user, id) do
    case Repo.get_by(Machine, id: id, user_id: user.id) do
      nil -> {:error, :not_found, "machine"}
      machine -> {:ok, machine}
    end
  end

  @doc """
  The live machines `user` doesn't own but may see (#2572): those serving a
  board `user` is a member of. They are shown read-only; only the owner
  changes a machine. Newest first.
  """
  def list_shared_machines(%User{} = user) do
    board_ids = user |> Access.list_boards(archived: :all) |> Enum.map(& &1.id)

    Repo.all(
      from(m in Machine,
        where:
          m.user_id != ^user.id and is_nil(m.revoked_at) and
            fragment("? && ?", m.board_ids, ^board_ids),
        order_by: [desc: m.id],
        preload: [:user]
      )
    )
  end

  @doc """
  A machine `user` may see, by id, and whether they may change it:
  `{:ok, machine, :owner}` for its owner, `{:ok, machine, :member}` for a
  member of a board it serves (see `list_shared_machines/1`), else
  `{:error, :not_found, "machine"}`, so a machine you can't see isn't told
  apart from one that doesn't exist.
  """
  def get_visible_machine(%User{} = user, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:owner, {:error, _, _}} <- {:owner, get_machine(user, id)},
         %Machine{} = machine <- Enum.find(list_shared_machines(user), &(&1.id == id)) do
      {:ok, machine, :member}
    else
      {:owner, {:ok, machine}} -> {:ok, machine, :owner}
      _ -> {:error, :not_found, "machine"}
    end
  end

  @machine_name_max 60

  @doc """
  Renames a machine (#2666): `name` is what the pages, the CLI and the
  board show; its hostname, as the daemon reported it, stays as it was.
  Control characters are dropped and the name is trimmed to
  #{@machine_name_max} characters; a blank one is refused. A revoked
  machine can be renamed too: its row is the record of what it was.
  """
  def rename_machine(%Machine{} = machine, name) do
    case clean(name, @machine_name_max) do
      nil ->
        {:error, :invalid, "give the machine a name"}

      name ->
        machine |> Ecto.Changeset.change(name: name) |> Repo.update()
    end
  end

  @doc """
  Revokes a machine: its key stops working at once. Revoking one already
  revoked leaves it as it was.
  """
  def revoke_machine(%Machine{revoked_at: nil} = machine) do
    machine |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()
  end

  def revoke_machine(%Machine{} = machine), do: {:ok, machine}
end
