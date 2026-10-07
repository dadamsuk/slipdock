defmodule Slipdock.SharedAIKeyTest do
  @moduledoc """
  Who may spend the server-wide OpenRouter key.

  On a private instance, everybody — that is what it is for. On one run for
  other people it is an open tab on the operator's card, so there is a lever.
  It is off by default, and this is the test that says what both positions do.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, AI}

  defp admins_only(value),
    do: Slipdock.TestConfig.merge(:ai, shared_key_for_admins_only: value)

  setup do
    %{
      user: user_fixture("someone@example.com"),
      admin: elem(Accounts.promote(user_fixture("admin@example.com")), 1)
    }
  end

  test "by default everybody falls back to the shared key", %{user: user} do
    admins_only(false)

    assert {:ok, "test-key"} = AI.api_key(user: user)
    assert AI.configured?(user)
  end

  test "with the lever pulled, only admins do", %{user: user, admin: admin} do
    admins_only(true)

    assert {:ok, "test-key"} = AI.api_key(user: admin)
    assert AI.configured?(admin)

    # Everybody else brings their own key or gets no AI features at all.
    assert {:error, message} = AI.api_key(user: user)
    assert message =~ "OpenRouter"
    refute AI.configured?(user)
  end

  test "somebody's own key still works whichever way the lever is set", %{user: user} do
    admins_only(true)
    :ok = AI.Keys.put(user, "sk-or-their-own")
    on_exit(fn -> AI.Keys.delete(user) end)

    assert {:ok, "sk-or-their-own"} = AI.api_key(user: user)
    assert AI.configured?(user)
  end

  test "an explicit key passed in beats everything", %{user: user} do
    admins_only(true)
    assert {:ok, "sk-or-explicit"} = AI.api_key(user: user, api_key: "sk-or-explicit")
  end
end
