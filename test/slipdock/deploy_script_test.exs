defmodule Slipdock.DeployScriptTest do
  @moduledoc """
  deploy/deploy.sh, the script the release workflow runs on the production
  server over SSH, run here under `sh` against a stand-in `docker` that writes
  down what it was asked to do.

  What matters is what it refuses (anything but a pinned tag reaches neither
  docker nor .env), that it only ever touches the app's service, and that a
  rollback is the same command with the previous tag.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../deploy/deploy.sh", __DIR__)

  @docker """
  #!/bin/sh
  echo "$* | SLIPDOCK_TAG=${SLIPDOCK_TAG:-}" >> "$STUB_DIR/docker.log"
  case "$1" in
    login) cat > "$STUB_DIR/login-stdin" ;;
    compose)
      case "$2" in
        pull) [ -z "${STUB_FAIL_PULL:-}" ] || exit 1 ;;
        up) [ -z "${STUB_FAIL_UP:-}" ] || exit 1 ;;
        ps) echo cid123 ;;
      esac
      ;;
    inspect) echo sha256:imageid ;;
    image) echo ghcr.io/dadamsuk/slipdock@sha256:feedface ;;
  esac
  """

  setup do
    root = Path.join(System.tmp_dir!(), "slipdock-deploy-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    dirs = %{
      app: Path.join(root, "slipdock"),
      state: Path.join(root, "deploy"),
      stub: Path.join(root, "bin")
    }

    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    File.write!(Path.join(dirs.stub, "docker"), @docker)
    File.chmod!(Path.join(dirs.stub, "docker"), 0o755)

    Map.put(dirs, :env, Path.join(dirs.app, ".env"))
  end

  defp deploy(ctx, args, extra_env \\ []) do
    env =
      [
        {"PATH", ctx.stub <> ":" <> System.get_env("PATH")},
        {"STUB_DIR", ctx.stub},
        {"SLIPDOCK_DIR", ctx.app},
        {"DEPLOY_STATE_DIR", ctx.state},
        {"GHCR_CREDENTIALS", Path.join(ctx.state, "ghcr.env")}
      ] ++ extra_env

    System.cmd("sh", [@script | args], env: env, stderr_to_stdout: true)
  end

  defp docker_calls(ctx) do
    case File.read(Path.join(ctx.stub, "docker.log")) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp read(path), do: File.read!(path)
  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  describe "the tag" do
    @refused [
      "",
      "latest",
      "main",
      "1.2",
      "v1.2.3",
      "sha-abc12",
      "sha-ABC1234",
      "sha-abc1234; rm -rf /",
      "sha-abc1234\nlatest",
      "sha-abc1234 latest",
      "$(id)",
      "../sha-abc1234",
      "1.2.3-",
      "1.2.3-rc_1",
      "1.0.0-" <> String.duplicate("a", 60)
    ]

    test "anything but a pinned tag is refused before docker or .env is touched", ctx do
      File.write!(ctx.env, "PHX_HOST=board.example.com\nSLIPDOCK_TAG=sha-0000000\n")

      for tag <- @refused do
        {out, status} = deploy(ctx, [tag])
        assert status != 0, "accepted #{inspect(tag)}"
        assert out =~ "not a pinned image tag", "#{inspect(tag)}: #{out}"
      end

      assert docker_calls(ctx) == []
      assert read(ctx.env) == "PHX_HOST=board.example.com\nSLIPDOCK_TAG=sha-0000000\n"
      refute File.exists?(Path.join(ctx.state, "previous-tag"))
    end

    test "exactly one argument", ctx do
      for args <- [[], ["sha-abc1234", "sha-def5678"]] do
        {out, status} = deploy(ctx, args)
        assert status != 0
        assert out =~ "usage: deploy.sh <image-tag>"
      end

      assert docker_calls(ctx) == []
    end

    test "commit tags short or full, and release versions, are accepted", ctx do
      for tag <- ["sha-abc1234", "sha-" <> String.duplicate("a1", 20), "1.2.3", "2.0.1-rc.1"] do
        assert {_, 0} = deploy(ctx, [tag])
        assert read(ctx.env) =~ "SLIPDOCK_TAG=#{tag}\n"
      end
    end
  end

  describe "a deploy" do
    test "pulls then recreates the app alone, pinning the tag in .env", ctx do
      File.write!(ctx.env, "PHX_HOST=board.example.com\nSLIPDOCK_TAG=sha-0000000\nPOOL_SIZE=5\n")

      {out, 0} = deploy(ctx, ["sha-abc1234"])

      assert docker_calls(ctx) == [
               "compose pull slipdock | SLIPDOCK_TAG=sha-abc1234",
               "compose up -d --no-deps slipdock | SLIPDOCK_TAG=sha-abc1234",
               "compose ps -q slipdock | SLIPDOCK_TAG=",
               "inspect --format {{.Image}} cid123 | SLIPDOCK_TAG=",
               "image inspect --format {{range .RepoDigests}}{{println .}}{{end}} sha256:imageid | SLIPDOCK_TAG="
             ]

      refute Enum.any?(docker_calls(ctx), &(&1 =~ "postgres"))

      # Every other setting kept, the tag replaced rather than added to.
      assert read(ctx.env) ==
               "PHX_HOST=board.example.com\nPOOL_SIZE=5\nSLIPDOCK_TAG=sha-abc1234\n"

      assert read(Path.join(ctx.state, "previous-tag")) == "sha-0000000\n"
      assert out =~ "deploy: deploying sha-abc1234 (was sha-0000000)"
      assert out =~ "deploy: digest ghcr.io/dadamsuk/slipdock@sha256:feedface"
      assert out =~ "deploy: to roll back: deploy.sh sha-0000000"

      assert read(Path.join(ctx.state, "deploy.log")) =~
               ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ sha-0000000 -> sha-abc1234 ghcr.io\/dadamsuk\/slipdock@sha256:feedface\n$/
    end

    test "keeps .env's owner-only mode, and makes a new one owner-only", ctx do
      File.write!(ctx.env, "SECRET_KEY_BASE=x\n")
      File.chmod!(ctx.env, 0o640)
      {_, 0} = deploy(ctx, ["sha-abc1234"])
      assert mode(ctx.env) == 0o640

      File.rm!(ctx.env)
      {_, 0} = deploy(ctx, ["sha-abc1234"])
      assert mode(ctx.env) == 0o600
      assert read(ctx.env) == "SLIPDOCK_TAG=sha-abc1234\n"
    end

    test "rolling back is the same command with the previous tag", ctx do
      File.write!(ctx.env, "SLIPDOCK_TAG=sha-1111111\n")

      {_, 0} = deploy(ctx, ["sha-2222222"])
      previous = ctx.state |> Path.join("previous-tag") |> read() |> String.trim()
      assert previous == "sha-1111111"

      {out, 0} = deploy(ctx, [previous])
      assert read(ctx.env) == "SLIPDOCK_TAG=sha-1111111\n"
      assert out =~ "to roll back: deploy.sh sha-2222222"
    end

    test "redeploying the same tag keeps the real previous one", ctx do
      File.write!(ctx.env, "SLIPDOCK_TAG=sha-1111111\n")
      {_, 0} = deploy(ctx, ["sha-2222222"])
      {_, 0} = deploy(ctx, ["sha-2222222"])
      assert read(Path.join(ctx.state, "previous-tag")) == "sha-1111111\n"
    end

    test "with no tag pinned before, says the previous one cannot be rolled back to", ctx do
      File.write!(ctx.env, "PHX_HOST=board.example.com\n")
      {out, 0} = deploy(ctx, ["1.2.3"])

      assert out =~ "deploying 1.2.3 (was latest)"
      assert out =~ "the previous tag (latest) was not pinned"
      refute out =~ "to roll back: deploy.sh"
    end

    test "a pull that fails changes nothing and starts nothing", ctx do
      File.write!(ctx.env, "SLIPDOCK_TAG=sha-1111111\n")
      {out, status} = deploy(ctx, ["sha-2222222"], [{"STUB_FAIL_PULL", "1"}])

      assert status != 0
      assert out =~ "pull of sha-2222222 failed; nothing changed"
      assert read(ctx.env) == "SLIPDOCK_TAG=sha-1111111\n"
      refute File.exists?(Path.join(ctx.state, "previous-tag"))
      refute Enum.any?(docker_calls(ctx), &(&1 =~ "compose up"))
    end

    test "an up that fails exits non-zero and says how to go back", ctx do
      File.write!(ctx.env, "SLIPDOCK_TAG=sha-1111111\n")
      {out, status} = deploy(ctx, ["sha-2222222"], [{"STUB_FAIL_UP", "1"}])

      assert status != 0
      assert out =~ "starting sha-2222222 failed; to go back: deploy.sh sha-1111111"
    end

    test "a missing compose project is refused", ctx do
      File.rm_rf!(ctx.app)
      {out, status} = deploy(ctx, ["sha-abc1234"])
      assert status != 0
      assert out =~ "no compose project at #{ctx.app}"
      assert docker_calls(ctx) == []
    end
  end

  describe "logging in to GHCR" do
    test "uses the server's credentials file, the token on stdin and never in argv or output",
         ctx do
      File.write!(Path.join(ctx.state, "ghcr.env"), "GHCR_USER=deployer\nGHCR_TOKEN=ghp_s3cret\n")

      {out, 0} = deploy(ctx, ["sha-abc1234"])

      assert hd(docker_calls(ctx)) ==
               "login ghcr.io --username deployer --password-stdin | SLIPDOCK_TAG="

      assert read(Path.join(ctx.stub, "login-stdin")) == "ghp_s3cret"
      refute Enum.any?(docker_calls(ctx), &(&1 =~ "ghp_s3cret"))
      refute out =~ "ghp_s3cret"
      assert out =~ "logged in to ghcr.io as deployer"
    end

    test "a credentials file missing its token stops before the pull", ctx do
      File.write!(Path.join(ctx.state, "ghcr.env"), "GHCR_USER=deployer\n")

      {out, status} = deploy(ctx, ["sha-abc1234"])
      assert status != 0
      assert out =~ "needs both GHCR_USER= and GHCR_TOKEN="
      assert docker_calls(ctx) == []
    end

    test "is not sourced, so a line of shell in it does not run", ctx do
      marker = Path.join(ctx.state, "ran")

      File.write!(
        Path.join(ctx.state, "ghcr.env"),
        "touch #{marker}\nGHCR_USER=deployer\nGHCR_TOKEN=t\n"
      )

      {_, 0} = deploy(ctx, ["sha-abc1234"])
      refute File.exists?(marker)
    end

    test "without a credentials file, pulls with docker's own login", ctx do
      {out, 0} = deploy(ctx, ["sha-abc1234"])
      assert out =~ "pulling with docker's existing login"
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "login"))
    end
  end
end
