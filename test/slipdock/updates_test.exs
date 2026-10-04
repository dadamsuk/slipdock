defmodule Slipdock.UpdatesTest do
  @moduledoc """
  Whether a newer image has been published, asked of a stub registry. The
  comparison is by commit, with the build time deciding which way round.
  """
  use ExUnit.Case, async: false

  alias Slipdock.{Build, Updates, UpdatesStub}

  test "the same commit is up to date" do
    UpdatesStub.publish(Build.sha())
    assert {:ok, %{status: :current, latest: %{revision: sha}}} = Updates.check()
    assert sha == Build.sha()
  end

  test "a different commit built later is a newer image" do
    UpdatesStub.publish("abcdef1234567890", "2099-01-01T00:00:00Z")

    assert {:ok, %{status: :available, image: "ghcr.io/dadamsuk/slipdock:latest", latest: latest}} =
             Updates.check()

    assert latest.revision == "abcdef1234567890"
    assert latest.created == ~U[2099-01-01 00:00:00Z]
  end

  test "a different commit built earlier is not offered as an upgrade" do
    UpdatesStub.publish("abcdef1234567890", "2000-01-01T00:00:00Z")
    assert {:ok, %{status: :ahead}} = Updates.check()
  end

  test "a build that does not know its own commit cannot be compared" do
    latest = %{revision: "abc", created: ~U[2099-01-01 00:00:00Z]}
    assert Updates.compare(%{revision: "unknown", created: Build.timestamp()}, latest) == :unknown
  end

  test "a registry that refuses is an error, not an answer" do
    UpdatesStub.publish({:status, 503})
    assert {:error, "the registry answered HTTP 503"} = Updates.check()
  end

  test "switched off, it asks nobody" do
    # test.exs leaves it off, and no stub is set: a request would raise.
    assert {:ok, %{status: :disabled, latest: nil}} = Updates.check()
  end
end
