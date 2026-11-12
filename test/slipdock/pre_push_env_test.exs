defmodule Slipdock.PrePushEnvTest do
  @moduledoc """
  `mix pre_push`'s steps run in `test` whatever `MIX_ENV` it was started
  with (#2903). `preferred_envs` makes `mix pre_push` itself `test` only while
  `MIX_ENV` is unset: set but empty, Mix reads it as `dev`, and a step passed
  that on dropped the dev database rather than the checkout's own test one.
  """
  # Sync: it sets `Mix.env/1`, which is global to the VM, and puts it back.
  use ExUnit.Case, async: false

  defp project, do: Mix.Project.get!()

  setup do
    env = Mix.env()
    on_exit(fn -> Mix.env(env) end)
  end

  for env <- [:dev, :prod, :staging] do
    test "started in #{env}, every app step still runs in test, on its own database" do
      Mix.env(unquote(env))
      env = project().pre_push_env([], "postgres://h/slipdock_test")

      assert {"MIX_ENV", "test"} in env
      assert {"MIX_TEST_PARTITION", project().pre_push_partition()} in env

      # `slipdock_test_pre_push_<hash>`, never `slipdock_dev`.
      assert {"TEST_DATABASE_URL", "postgres://h/slipdock_test" <> project().pre_push_partition()} in env
    end
  end

  test "the drop and the repo checks are among the steps that get it" do
    Mix.env(:dev)
    tasks = for {task, _argv} <- project().pre_push_steps(), do: task
    assert "ecto.drop" in tasks and "test" in tasks
    assert {"MIX_ENV", "test"} in project().pre_push_env([], nil)
  end

  test "the CLI's and the daemon's steps are left out of it, as before" do
    Mix.env(:dev)
    assert {"MIX_ENV", nil} in project().pre_push_env([cd: "cli"], nil)
    assert project().pre_push_env([cd: "daemon", exec: true], nil) == []
  end
end
