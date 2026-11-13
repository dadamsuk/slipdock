defmodule Slipdock.MachinesTest do
  @moduledoc """
  Machines and their enrolment (#2570): the device-code path and the
  one-time key, each handing out one machine key once; the boards a machine
  may serve; and the key itself, refused at once when the machine is
  revoked and never mistaken for an API or runner token.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Machines, Repo, Runners}
  alias Slipdock.Machines.{Enrolment, EnrolmentKey, Machine}

  @about %{
    "hostname" => "build-box",
    "os" => "linux",
    "arch" => "amd64",
    "fingerprint" => "SHA256:abc"
  }

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Served"}, owner: user)
    %{user: user, board: board}
  end

  defp approved_key(ctx, boards \\ nil) do
    {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about)
    {:ok, _} = Machines.approve_enrolment(enrolment, ctx.user, boards || [ctx.board.id])
    {:ok, {key, machine}} = Machines.poll_enrolment(device_code)
    {key, machine}
  end

  describe "describe/1" do
    test "keeps what a person reads, cleaned and cut to size" do
      assert {:ok, about} =
               Machines.describe(%{
                 "hostname" => "  box\u0007\n ",
                 "os" => String.duplicate("x", 100),
                 "arch" => "",
                 "fingerprint" => 42
               })

      assert about.hostname == "box"
      assert String.length(about.os) == 40
      assert about.arch == nil
      assert about.fingerprint == nil
    end

    test "a hostname is required" do
      assert {:error, :invalid, "hostname is required" <> _} =
               Machines.describe(%{"os" => "linux"})

      assert {:error, :invalid, _} = Machines.describe(nil)
    end
  end

  describe "enrolment by device code" do
    test "pending until approved, then one key, bound to the approver and the boards", ctx do
      {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about, "203.0.113.9")
      assert enrolment.client_ip == "203.0.113.9"
      assert enrolment.user_code =~ ~r/^[A-Z2-9]{8}$/

      assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}

      # The person finds it by the code as typed, dashes and case forgiven.
      typed =
        String.downcase(String.slice(enrolment.user_code, 0, 4)) <>
          "-" <> String.slice(enrolment.user_code, 4, 4)

      assert %Enrolment{id: id} = Machines.enrolment_by_user_code(typed)
      assert id == enrolment.id

      {:ok, _} = Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.code])
      assert {:ok, {"sdm_" <> _ = key, machine}} = Machines.poll_enrolment(device_code)

      assert machine.user_id == ctx.user.id
      assert machine.board_ids == [ctx.board.id]
      assert machine.hostname == "build-box"
      assert machine.name == "build-box"
      assert machine.fingerprint == "SHA256:abc"
      assert machine.enrolled_via == "device_code"
      # Only the hash is kept.
      assert machine.key_hash == :crypto.hash(:sha256, key)
      refute Repo.exists?(from(m in Machine, where: m.key_hash == ^key))

      # Consumed: a second poll makes no second machine.
      assert Machines.poll_enrolment(device_code) == {:error, :invalid}
      assert Repo.aggregate(Machine, :count) == 1
      refute Machines.enrolment_by_user_code(enrolment.user_code)
    end

    test "refused: the daemon is told, and the code can't be approved after", ctx do
      {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about)
      {:ok, _} = Machines.deny_enrolment(enrolment)

      assert Machines.poll_enrolment(device_code) == {:error, :access_denied}
      assert Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.id]) == {:error, :expired}
      assert Repo.aggregate(Machine, :count) == 0
    end

    test "decided once: a second approval loses", ctx do
      {:ok, {_, enrolment}} = Machines.request_enrolment(@about)
      other = user_fixture("other@example.com")
      other_board = board_fixture(%{}, owner: other)

      assert {:ok, _} = Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.id])
      assert Machines.approve_enrolment(enrolment, other, [other_board.id]) == {:error, :expired}
      assert Repo.get!(Enrolment, enrolment.id).user_id == ctx.user.id
    end

    test "expired: not findable, and polling says so", ctx do
      {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about)
      past = DateTime.add(DateTime.utc_now(:second), -1, :second)
      Repo.update_all(from(e in Enrolment, where: e.id == ^enrolment.id), set: [expires_at: past])

      refute Machines.enrolment_by_user_code(enrolment.user_code)
      assert Machines.poll_enrolment(device_code) == {:error, :expired_token}
      assert Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.id]) == {:error, :expired}

      # And the next request clears it away.
      {:ok, _} = Machines.request_enrolment(@about)
      refute Repo.get(Enrolment, enrolment.id)
    end

    test "unknown and malformed device codes are invalid" do
      assert Machines.poll_enrolment("nope!") == {:error, :invalid}
      assert Machines.poll_enrolment(Base.url_encode64("x", padding: false)) == {:error, :invalid}
      assert Machines.poll_enrolment(nil) == {:error, :invalid}
    end

    test "a request with no hostname is refused before anything is stored" do
      assert {:error, :invalid, _} = Machines.request_enrolment(%{"os" => "linux"})
      assert Repo.aggregate(Enrolment, :count) == 0
    end
  end

  describe "the boards a machine may serve" do
    test "only top-level boards the approver can reach, and at least one", ctx do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Not yours"}, owner: stranger)
      {:ok, {_, enrolment}} = Machines.request_enrolment(@about)

      assert {:error, :invalid, "not a top-level board you can write to: " <> named} =
               Machines.approve_enrolment(enrolment, ctx.user, [ctx.board.id, theirs.id])

      assert named == Integer.to_string(theirs.id)

      assert {:error, :invalid, "choose at least one board" <> _} =
               Machines.approve_enrolment(enrolment, ctx.user, [])

      assert {:error, :invalid, _} = Machines.approve_enrolment(enrolment, ctx.user, ["", " "])

      # Still pending after the refusals: nothing was decided.
      assert Machines.enrolment_by_user_code(enrolment.user_code)
    end

    test "duplicates collapse, and ids and codes both name a board", ctx do
      assert Machines.servable_board_ids(ctx.user, [
               ctx.board.id,
               ctx.board.code,
               "#{ctx.board.id}"
             ]) ==
               {:ok, [ctx.board.id]}
    end
  end

  describe "enrolment by one-time key" do
    test "enrols once, bound to the key's maker and boards", ctx do
      {:ok, "sde_" <> _ = key, record} =
        Machines.create_enrolment_key(ctx.user, [ctx.board.id], "ci")

      assert record.label == "ci"
      assert record.key_hash == :crypto.hash(:sha256, key)
      assert [%EnrolmentKey{}] = Machines.list_enrolment_keys(ctx.user)

      assert {:ok, {"sdm_" <> _, machine}} = Machines.enrol_with_key(key, @about)
      assert machine.user_id == ctx.user.id
      assert machine.board_ids == [ctx.board.id]
      assert machine.enrolled_via == "enrolment_key"
      # The key's label names the machine; the hostname is kept as reported.
      assert machine.name == "ci"
      assert machine.hostname == "build-box"
      assert Repo.get!(EnrolmentKey, record.id).machine_id == machine.id

      # Spent.
      assert Machines.enrol_with_key(key, @about) == {:error, :invalid}
      assert Machines.list_enrolment_keys(ctx.user) == []
      assert Repo.aggregate(Machine, :count) == 1
    end

    test "a lapsed key, an unknown one and another kind of token are one refusal", ctx do
      {:ok, key, record} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      past = DateTime.add(DateTime.utc_now(:second), -1, :second)
      Repo.update_all(from(k in EnrolmentKey, where: k.id == ^record.id), set: [expires_at: past])

      {api_token, _} = Accounts.create_api_token(ctx.user, "t")

      for presented <- [key, "sde_unknown", api_token, nil] do
        assert Machines.enrol_with_key(presented, @about) == {:error, :invalid}
      end

      assert Repo.aggregate(Machine, :count) == 0
    end

    test "a key without a label, or a blank one, names the machine by its hostname", ctx do
      for label <- [nil, "  \n "] do
        {:ok, key, record} = Machines.create_enrolment_key(ctx.user, [ctx.board.id], label)
        assert record.label == nil
        assert {:ok, {_, machine}} = Machines.enrol_with_key(key, @about)
        assert machine.name == "build-box"
      end
    end

    test "a machine described badly doesn't spend the key", ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      assert {:error, :invalid, _} = Machines.enrol_with_key(key, %{"os" => "linux"})
      assert {:ok, _} = Machines.enrol_with_key(key, @about)
    end

    test "a key needs boards the maker can reach", ctx do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{}, owner: stranger)
      assert {:error, :invalid, _} = Machines.create_enrolment_key(ctx.user, [theirs.id])
      assert {:error, :invalid, _} = Machines.create_enrolment_key(ctx.user, [])
      assert Repo.aggregate(EnrolmentKey, :count) == 0
    end

    test "keys last a day" do
      assert EnrolmentKey.validity_hours() == 24
    end
  end

  describe "the machine key" do
    test "authenticates its machine and records when and where it was seen", ctx do
      {key, machine} = approved_key(ctx)
      assert machine.last_seen_at == nil

      assert %Machine{id: id, last_seen_ip: "198.51.100.4"} =
               Machines.authenticate(key, "198.51.100.4")

      assert id == machine.id
      assert Repo.get!(Machine, id).last_seen_at
      # Whitespace round a pasted key is forgiven.
      assert %Machine{} = Machines.authenticate(" " <> key <> "\n")
    end

    test "revoked: refused at once, and the row stays", ctx do
      {key, machine} = approved_key(ctx)
      {:ok, revoked} = Machines.revoke_machine(machine)
      assert Machine.revoked?(revoked)

      assert Machines.authenticate(key) == nil
      assert Repo.get!(Machine, machine.id).revoked_at

      # Revoking again changes nothing.
      assert {:ok, again} = Machines.revoke_machine(revoked)
      assert again.revoked_at == revoked.revoked_at
    end

    test "is not an API token, and no other token is a machine key", ctx do
      {key, _} = approved_key(ctx)
      assert Accounts.get_user_by_api_token(key) == nil
      assert Runners.authenticate(key) == nil

      {api_token, _} = Accounts.create_api_token(ctx.user, "t")

      {:ok, _runner, runner_token} =
        Runners.create_runner(ctx.board, %{"name" => "r", "pool" => "dev"})

      for other <- [api_token, runner_token, "sdm_unknown", "", nil, 7] do
        assert Machines.authenticate(other) == nil
      end
    end
  end

  describe "the owner's machines" do
    test "listed and fetched for their owner only, live before revoked", ctx do
      {_, first} = approved_key(ctx)
      {_, second} = approved_key(ctx)
      {:ok, _} = Machines.revoke_machine(second)

      assert Enum.map(Machines.list_machines(ctx.user), & &1.id) == [first.id, second.id]
      assert {:ok, %Machine{}} = Machines.get_machine(ctx.user, first.id)

      stranger = user_fixture("stranger@example.com")
      assert Machines.list_machines(stranger) == []
      assert Machines.get_machine(stranger, first.id) == {:error, :not_found, "machine"}
    end

    test "rename_machine/2 renames it, cleaned, and leaves the hostname (#2666)", ctx do
      {_, machine} = approved_key(ctx)
      assert machine.name == "build-box"

      assert {:ok, renamed} = Machines.rename_machine(machine, "  Silver\tbox  ")
      assert renamed.name == "Silverbox"
      assert renamed.hostname == "build-box"
      assert Repo.get!(Machine, machine.id).name == "Silverbox"

      long = String.duplicate("x", 80)
      assert {:ok, %{name: name}} = Machines.rename_machine(renamed, long)
      assert name == String.duplicate("x", 60)

      for blank <- ["", "   ", "\n", nil, 7] do
        assert {:error, :invalid, "give the machine a name"} =
                 Machines.rename_machine(renamed, blank)
      end

      assert Repo.get!(Machine, machine.id).name == name

      # A revoked machine keeps its row, and can still be renamed.
      {:ok, revoked} = Machines.revoke_machine(Repo.get!(Machine, machine.id))
      assert {:ok, %{name: "old box"}} = Machines.rename_machine(revoked, "old box")
    end

    test "rename_machine/2 tells the machine's followers, from any door; a refusal doesn't (#2764)",
         ctx do
      {_, machine} = approved_key(ctx)
      id = machine.id
      version = machine.config_version
      Slipdock.Runners.MachineRunners.subscribe(machine)

      assert {:ok, _} = Machines.rename_machine(machine, "Silverbox")
      assert_receive {:config_changed, ^id}

      assert {:error, :invalid, _} = Machines.rename_machine(machine, "  ")
      refute_receive {:config_changed, ^id}, 50

      # It wakes the daemon's long-poll without a new config to fetch.
      assert Repo.get!(Machine, id).config_version == version
    end

    test "boards_for/2 names only the boards the owner can still reach", ctx do
      {_, machine} = approved_key(ctx)
      assert [%{id: id}] = Machines.boards_for(machine, ctx.user)
      assert id == ctx.board.id
      assert Machines.boards_for(%{machine | board_ids: [-1]}, ctx.user) == []
    end
  end

  describe "who sees a machine (#2572)" do
    test "a member of a board it serves sees it, read-only; others don't", ctx do
      {_key, machine} = approved_key(ctx)
      member = user_fixture("member@example.com")
      stranger = user_fixture("stranger@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, member, "read", ctx.user)

      assert [%Machine{id: id, user: %{id: owner_id}}] = Machines.list_shared_machines(member)
      assert id == machine.id
      assert owner_id == ctx.user.id
      assert Machines.list_shared_machines(stranger) == []
      # Your own machines are yours, not shared with you.
      assert Machines.list_shared_machines(ctx.user) == []

      assert {:ok, %Machine{id: ^id}, :owner} = Machines.get_visible_machine(ctx.user, id)

      assert {:ok, %Machine{id: ^id}, :member} =
               Machines.get_visible_machine(member, to_string(id))

      assert {:error, :not_found, "machine"} = Machines.get_visible_machine(stranger, id)
      assert {:error, :not_found, "machine"} = Machines.get_visible_machine(member, "nope")
      assert {:error, :not_found, "machine"} = Machines.get_visible_machine(member, id + 1000)

      # A revoked machine is no longer shown to members; its owner keeps it.
      {:ok, _} = Machines.revoke_machine(machine)
      assert Machines.list_shared_machines(member) == []
      assert {:error, :not_found, _} = Machines.get_visible_machine(member, id)
      assert {:ok, _, :owner} = Machines.get_visible_machine(ctx.user, id)
    end

    test "online means heard from in the last two minutes, and never once revoked", ctx do
      {_key, machine} = approved_key(ctx)
      now = DateTime.utc_now(:second)

      refute Machines.online?(%{machine | last_seen_at: nil})
      assert Machines.online?(%{machine | last_seen_at: DateTime.add(now, -120)}, now)
      refute Machines.online?(%{machine | last_seen_at: DateTime.add(now, -121)}, now)
      refute Machines.online?(%{machine | last_seen_at: now, revoked_at: now}, now)
    end
  end
end
