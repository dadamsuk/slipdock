defmodule Slipdock.RuntimeEnvFileTest do
  # The .env loader in config/runtime.exs (#2083): how a self-hosted server
  # gets its secrets. SLIPDOCK_ENV_FILE names a file of KEY=value lines, read
  # before anything else reads the environment; without it, `.env` in the
  # project directory and then in its parent. Read as prod reads it, in a
  # separate `elixir`, so nothing here is written to this VM's environment:
  # the child reports its own environment and the config it built.
  #
  # The child reads a copy of config/runtime.exs placed in the test's own
  # directory (<tmp>/parent/project/config/runtime.exs). The loader finds the
  # two `.env` files relative to itself, so the copy looks in the test's
  # directories and never at the .env of whoever runs the suite.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # Every variable a test's file or environment sets. Each is unset in the
  # child first, under its old KANBAN_* name too (which runtime.exs adopts
  # before it reads the file), so one exported in the shell running the suite,
  # or loaded into this VM from a developer's own .env, can't stand in for the
  # file.
  @names ~w(
    DATABASE_URL SECRET_KEY_BASE SLIPDOCK_ENV_FILE
    SLIPDOCK_SMTP_HOST SLIPDOCK_SMTP_PORT SLIPDOCK_SMTP_USER SLIPDOCK_SMTP_PASSWORD
    SLIPDOCK_SMTP_FROM SLIPDOCK_MAIL_FROM SLIPDOCK_MAIL_FROM_NAME
    SLIPDOCK_ENV_FILE_TEST_COMMENTED SLIPDOCK_ENV_FILE_TEST_INDENTED SLIPDOCK_ENV_FILE_TEST_BARE
  )

  @secret String.duplicate("k", 62) <> "=="

  defp read_runtime(dir, env) do
    script = ~S"""
    c = Config.Reader.read!(System.fetch_env!("RUNTIME_EXS_UNDER_TEST"), env: :prod)
    s = c[:slipdock]

    out = %{
      env: System.get_env(),
      database_url: s[Slipdock.Repo][:url],
      secret_key_base: s[SlipdockWeb.Endpoint][:secret_key_base],
      mailer: s[Slipdock.Mailer],
      seed_smtp: s[:seed_smtp]
    }

    IO.puts("RESULT " <> Base.encode64(:erlang.term_to_binary(out)))
    """

    # Through env(1), as the switch tests do: System.cmd drops a variable whose
    # value is empty, and set-but-blank is one of the cases here.
    unsets =
      Enum.flat_map(@names, fn name ->
        ["-u", name, "-u", String.replace_prefix(name, "SLIPDOCK_", "KANBAN_")]
      end)

    assigns =
      Enum.map([{"RUNTIME_EXS_UNDER_TEST", runtime_copy(dir)} | env], fn {name, value} ->
        "#{name}=#{value}"
      end)

    ebin = Application.app_dir(:slipdock, "ebin")

    {out, status} =
      System.cmd(
        "env",
        unsets ++ assigns ++ [System.find_executable("elixir"), "-pa", ebin, "-e", script],
        stderr_to_stdout: true
      )

    case Regex.run(~r/^RESULT (.*)$/m, out) do
      [_, encoded] -> {:ok, encoded |> Base.decode64!() |> :erlang.binary_to_term()}
      nil -> {:error, status, out}
    end
  end

  defp project(dir), do: Path.join([dir, "parent", "project"])

  defp runtime_copy(dir) do
    copy = Path.join([project(dir), "config", "runtime.exs"])
    File.mkdir_p!(Path.dirname(copy))
    File.cp!("config/runtime.exs", copy)
    copy
  end

  defp write_env(dir, body) do
    path = Path.join(dir, "server.env")
    File.write!(path, body)
    path
  end

  # A file that boots a server by itself: nothing but SLIPDOCK_ENV_FILE needs
  # to be in the environment.
  defp secrets do
    """
    DATABASE_URL=ecto://db.example.com/slipdock
    SECRET_KEY_BASE=#{@secret}
    """
  end

  describe "a file named by SLIPDOCK_ENV_FILE" do
    test "supplies the secrets a server boots on", %{tmp_dir: dir} do
      path = write_env(dir, secrets() <> "SLIPDOCK_SMTP_HOST=relay.example.com\n")

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["DATABASE_URL"] == "ecto://db.example.com/slipdock"
      assert result.database_url == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
      assert result.mailer[:relay] == "relay.example.com"
      assert result.seed_smtp[:host] == "relay.example.com"
    end

    test "skips blank lines, comments and lines with no =", %{tmp_dir: dir} do
      path =
        write_env(dir, """

        # SLIPDOCK_ENV_FILE_TEST_COMMENTED=1
           # SLIPDOCK_ENV_FILE_TEST_INDENTED=1
        \t
        SLIPDOCK_ENV_FILE_TEST_BARE
        #{secrets()}
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      # Nothing of the commented or bare lines reached the environment, under
      # any spelling of the name.
      assert Enum.filter(Map.keys(result.env), &(&1 =~ "SLIPDOCK_ENV_FILE_TEST")) == []
      refute Enum.any?(Map.keys(result.env), &String.starts_with?(&1, "#"))

      # ...and the lines after them were still read.
      assert result.database_url == "ecto://db.example.com/slipdock"
    end

    test "strips a leading `export `", %{tmp_dir: dir} do
      path =
        write_env(dir, """
        export DATABASE_URL=ecto://db.example.com/slipdock
        export SECRET_KEY_BASE=#{@secret}
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["DATABASE_URL"] == "ecto://db.example.com/slipdock"
      refute Map.has_key?(result.env, "export DATABASE_URL")
      assert result.database_url == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
    end

    test "splits on the first = only, so a value may hold one", %{tmp_dir: dir} do
      path =
        write_env(dir, """
        DATABASE_URL=ecto://db.example.com/slipdock?ssl=true&pool_size=5
        SECRET_KEY_BASE=#{@secret}
        SLIPDOCK_SMTP_HOST=relay.example.com
        SLIPDOCK_SMTP_USER=mailer
        SLIPDOCK_SMTP_PASSWORD=cGFzcz13b3Jk==
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["DATABASE_URL"] == "ecto://db.example.com/slipdock?ssl=true&pool_size=5"
      assert result.database_url == "ecto://db.example.com/slipdock?ssl=true&pool_size=5"
      # A base64 secret keeps its padding.
      assert result.secret_key_base == @secret
      assert String.ends_with?(result.secret_key_base, "==")
      assert result.env["SLIPDOCK_SMTP_PASSWORD"] == "cGFzcz13b3Jk=="
      assert result.mailer[:password] == "cGFzcz13b3Jk=="
    end

    test "strips surrounding double and single quotes", %{tmp_dir: dir} do
      path =
        write_env(dir, """
        DATABASE_URL="ecto://db.example.com/slipdock"
        SECRET_KEY_BASE='#{@secret}'
        SLIPDOCK_SMTP_HOST=relay.example.com
        SLIPDOCK_SMTP_USER="mailer"
        SLIPDOCK_SMTP_PASSWORD='it"s = quoted'
        SLIPDOCK_MAIL_FROM_NAME="The Board"
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["DATABASE_URL"] == "ecto://db.example.com/slipdock"
      assert result.database_url == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
      assert result.mailer[:username] == "mailer"
      # Only the quotes around the value go: one inside it stays.
      assert result.env["SLIPDOCK_SMTP_PASSWORD"] == ~s(it"s = quoted)
      assert result.mailer[:password] == ~s(it"s = quoted)
      assert result.seed_smtp[:from_name] == "The Board"
    end

    test "trims the space around a line, its name and its value", %{tmp_dir: dir} do
      path =
        write_env(dir, """
          DATABASE_URL = ecto://db.example.com/slipdock\t
        \texport SECRET_KEY_BASE =#{@secret}
        SLIPDOCK_SMTP_HOST=  relay.example.com
        SLIPDOCK_SMTP_PORT = 2525\r
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["DATABASE_URL"] == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
      assert result.mailer[:relay] == "relay.example.com"
      # A file with Windows line endings still gives a port that parses.
      assert result.mailer[:port] == 2525
    end

    test "a variable already in the environment wins over the file", %{tmp_dir: dir} do
      path =
        write_env(dir, """
        DATABASE_URL=ecto://file.example.com/from_file
        SECRET_KEY_BASE=#{@secret}
        SLIPDOCK_SMTP_HOST=file.example.com
        SLIPDOCK_SMTP_PORT=2525
        """)

      assert {:ok, result} =
               read_runtime(dir, [
                 {"SLIPDOCK_ENV_FILE", path},
                 {"DATABASE_URL", "ecto://process.example.com/from_process"},
                 {"SLIPDOCK_SMTP_HOST", "process.example.com"}
               ])

      assert result.env["DATABASE_URL"] == "ecto://process.example.com/from_process"
      assert result.database_url == "ecto://process.example.com/from_process"
      assert result.env["SLIPDOCK_SMTP_HOST"] == "process.example.com"
      assert result.mailer[:relay] == "process.example.com"

      # The file still fills in what the environment left unset.
      assert result.secret_key_base == @secret
      assert result.mailer[:port] == 2525
    end

    test "a variable set but blank in the environment is not filled in from the file",
         %{tmp_dir: dir} do
      path = write_env(dir, secrets() <> "SLIPDOCK_SMTP_HOST=file.example.com\n")

      assert {:ok, result} =
               read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}, {"SLIPDOCK_SMTP_HOST", ""}])

      assert result.env["SLIPDOCK_SMTP_HOST"] == ""
      assert result.mailer == nil
      assert result.seed_smtp == nil
    end

    test "the first line to name a variable wins over a later one", %{tmp_dir: dir} do
      path =
        write_env(dir, """
        DATABASE_URL=ecto://db.example.com/first
        DATABASE_URL=ecto://db.example.com/second
        SECRET_KEY_BASE=#{@secret}
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])
      assert result.database_url == "ecto://db.example.com/first"
    end

    test "an old KANBAN_* name in the file fills in its SLIPDOCK_* one, with the warning",
         %{tmp_dir: dir} do
      path =
        write_env(dir, """
        #{secrets()}
        SLIPDOCK_SMTP_HOST=relay.example.com
        KANBAN_MAIL_FROM_NAME=Old Name
        """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])

      assert result.env["SLIPDOCK_MAIL_FROM_NAME"] == "Old Name"
      assert result.seed_smtp[:from_name] == "Old Name"
    end

    test "the file is found under the old KANBAN_ENV_FILE name too", %{tmp_dir: dir} do
      path = write_env(dir, secrets())

      assert {:ok, result} = read_runtime(dir, [{"KANBAN_ENV_FILE", path}])

      assert result.env["SLIPDOCK_ENV_FILE"] == path
      assert result.database_url == "ecto://db.example.com/slipdock"
    end
  end

  describe "without SLIPDOCK_ENV_FILE" do
    test "reads .env in the project directory", %{tmp_dir: dir} do
      File.mkdir_p!(project(dir))
      File.write!(Path.join(project(dir), ".env"), secrets())

      assert {:ok, result} = read_runtime(dir, [])
      assert result.database_url == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
    end

    test "reads .env in the project's parent directory", %{tmp_dir: dir} do
      File.mkdir_p!(project(dir))
      File.write!(Path.join([dir, "parent", ".env"]), secrets())

      assert {:ok, result} = read_runtime(dir, [])
      assert result.database_url == "ecto://db.example.com/slipdock"
      assert result.secret_key_base == @secret
    end
  end

  describe "with more than one file" do
    test "the named file wins over the project's .env, and that over its parent's",
         %{tmp_dir: dir} do
      File.mkdir_p!(project(dir))

      named =
        write_env(dir, """
        DATABASE_URL=ecto://db.example.com/named
        """)

      File.write!(Path.join(project(dir), ".env"), """
      DATABASE_URL=ecto://db.example.com/project
      SECRET_KEY_BASE=#{@secret}
      SLIPDOCK_SMTP_HOST=project.example.com
      """)

      File.write!(Path.join([dir, "parent", ".env"]), """
      DATABASE_URL=ecto://db.example.com/parent
      SECRET_KEY_BASE=#{String.duplicate("p", 64)}
      SLIPDOCK_SMTP_HOST=parent.example.com
      SLIPDOCK_SMTP_PORT=2525
      """)

      assert {:ok, result} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", named}])

      assert result.database_url == "ecto://db.example.com/named"
      assert result.secret_key_base == @secret
      assert result.mailer[:relay] == "project.example.com"
      # Each file still fills in what the ones before it left unset.
      assert result.mailer[:port] == 2525
    end
  end

  describe "with no file to read" do
    test "a path that isn't a file is passed over: the environment alone boots the server",
         %{tmp_dir: dir} do
      for path <- [Path.join(dir, "missing.env"), dir] do
        assert {:ok, result} =
                 read_runtime(dir, [
                   {"SLIPDOCK_ENV_FILE", path},
                   {"DATABASE_URL", "ecto://db.example.com/slipdock"},
                   {"SECRET_KEY_BASE", @secret}
                 ])

        assert result.database_url == "ecto://db.example.com/slipdock"
        assert result.secret_key_base == @secret
      end
    end

    test "a secret in neither the file nor the environment stops the boot, by name",
         %{tmp_dir: dir} do
      path = write_env(dir, "DATABASE_URL=ecto://db.example.com/slipdock\n")

      assert {:error, status, out} = read_runtime(dir, [{"SLIPDOCK_ENV_FILE", path}])
      assert status != 0
      assert out =~ "environment variable SECRET_KEY_BASE is missing"
    end
  end
end
