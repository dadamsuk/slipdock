defmodule SlipdockWeb.AccountMachinesLiveTest do
  @moduledoc """
  The web door for machines (#2570): approving an enrolment by its code on
  `/account/machines/approve` (the machine's hostname, OS, architecture and
  fingerprint shown, the boards chosen), and Account › Machines, which
  lists them, revokes one and makes a one-time enrolment key.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Machines, Repo}
  alias Slipdock.Machines.Machine

  @about %{
    "hostname" => "build-box",
    "os" => "linux",
    "arch" => "arm64",
    "fingerprint" => "SHA256:fingerprint-shown"
  }

  setup %{user: user} do
    %{board: board_fixture(%{"name" => "Served board"}, owner: user)}
  end

  defp started do
    {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about, "192.0.2.10")
    {device_code, enrolment}
  end

  describe "approving a machine" do
    test "the code shows the machine, and approving with a board enrols it", ctx do
      {device_code, enrolment} = started()

      {:ok, view, html} =
        live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

      assert html =~ "build-box"
      assert html =~ "linux · arm64"
      assert html =~ "SHA256:fingerprint-shown"
      assert html =~ "192.0.2.10"
      assert has_element?(view, ~s{#machine-approve-form input[value="#{ctx.board.id}"]})

      # Opening the link decided nothing.
      assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}

      assert {:error, {:live_redirect, %{to: "/account/machines"}}} =
               view
               |> form("#machine-approve-form", %{"boards" => ["#{ctx.board.id}"]})
               |> render_submit()

      assert {:ok, {_, machine}} = Machines.poll_enrolment(device_code)
      assert machine.user_id == ctx.user.id
      assert machine.board_ids == [ctx.board.id]
    end

    test "approving with no board says why and decides nothing", ctx do
      {device_code, enrolment} = started()

      {:ok, view, _} =
        live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

      html = view |> form("#machine-approve-form", %{}) |> render_submit()
      assert html =~ "choose at least one board"
      assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}
    end

    test "refusing tells the machine", ctx do
      {device_code, enrolment} = started()

      {:ok, view, _} =
        live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

      view |> element("button", "Refuse") |> render_click()
      assert Machines.poll_enrolment(device_code) == {:error, :access_denied}
      refute has_element?(view, "#machine-enrolment")
    end

    test "a code decided elsewhere meanwhile is gone, not decided twice", ctx do
      {device_code, enrolment} = started()

      {:ok, view, _} =
        live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

      {:ok, _} = Machines.deny_enrolment(enrolment)

      html =
        view
        |> form("#machine-approve-form", %{"boards" => ["#{ctx.board.id}"]})
        |> render_submit()

      assert html =~ "decided or expired"
      assert Machines.poll_enrolment(device_code) == {:error, :access_denied}
    end

    test "typing the code looks it up; an unknown one says so", ctx do
      {_, enrolment} = started()
      {:ok, view, _} = live(ctx.conn, ~p"/account/machines/approve")
      refute has_element?(view, "#machine-enrolment")

      view |> form("#machine-code-form", %{"user_code" => enrolment.user_code}) |> render_submit()
      assert has_element?(view, "#machine-enrolment", "build-box")

      view |> form("#machine-code-form", %{"user_code" => "BBBB-CCCC"}) |> render_submit()
      assert has_element?(view, "#machine-code-unknown")
    end

    @tag :anonymous
    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      {_, enrolment} = started()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")
    end
  end

  describe "Account › Machines" do
    test "lists the machines and revokes one", ctx do
      {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.board.id])
      {:ok, {machine_key, machine}} = Machines.enrol_with_key(key, @about)

      {:ok, view, html} = live(ctx.conn, ~p"/account/machines")
      assert html =~ "build-box"
      assert html =~ "Served board"
      assert html =~ "SHA256:fingerprint-shown"

      view |> element("#machine-#{machine.id} button", "Revoke") |> render_click()

      assert Machine.revoked?(Repo.get!(Machine, machine.id))
      assert Machines.authenticate(machine_key) == nil
      assert has_element?(view, "#machine-#{machine.id}", "revoked")
      refute has_element?(view, "#machine-#{machine.id} button", "Revoke")
    end

    test "another person's machines aren't listed", ctx do
      stranger = user_fixture("stranger@example.com")
      board = board_fixture(%{}, owner: stranger)
      {:ok, key, _} = Machines.create_enrolment_key(stranger, [board.id])
      {:ok, _} = Machines.enrol_with_key(key, %{"hostname" => "their-box"})

      {:ok, view, html} = live(ctx.conn, ~p"/account/machines")
      refute html =~ "their-box"
      assert has_element?(view, "#machines-empty")
    end

    test "the enrolment key form is built from the form components (COMP-1)", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/account/machines")

      # `<.input>` wraps its field in a `.fieldset` and labels it by id; the
      # name stays `label`, which is what `create_key` reads.
      assert has_element?(
               view,
               "#enrolment-key-form-0 .fieldset label[for=enrolment-key-label-0] " <>
                 "input#enrolment-key-label-0.field[type=text][name=label][autocomplete=off]"
             )

      assert has_element?(
               view,
               "#enrolment-key-label-0[aria-label^='The name the machine enrols under']"
             )

      assert has_element?(view, "#enrolment-key-form-0 input[type=checkbox][name='boards[]']")
    end

    test "an enrolment key is shown once, with the init line, and needs a board", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/account/machines")

      html = view |> form("form[phx-submit=create_key]", %{"label" => "ci"}) |> render_submit()
      assert html =~ "choose at least one board"
      refute has_element?(view, "#new-enrolment-key")
      # A refusal keeps the name that was typed.
      assert has_element?(view, "form[phx-submit=create_key] input[name=label][value=ci]")

      view
      |> form("form[phx-submit=create_key]", %{"boards" => ["#{ctx.board.id}"], "label" => "ci"})
      |> render_submit()

      assert view |> element("#new-enrolment-key") |> render() =~
               "slipdock-runner init --key sde_"

      assert render(view) =~ "Unused: ci"
      # The form is made again, empty, for the next key.
      assert has_element?(
               view,
               "#enrolment-key-form-1 input[name=label][placeholder*='Machine name']"
             )

      refute has_element?(view, "input[name=label][value=ci]")

      # The name given is the name the machine enrols under (#2666).
      [key] = Regex.run(~r/sde_[A-Za-z0-9_-]+/, render(view))
      {:ok, {_, machine}} = Machines.enrol_with_key(key, @about)
      assert machine.name == "ci"

      view |> element("button", "Done") |> render_click()
      refute has_element?(view, "#new-enrolment-key")
    end
  end
end
