defmodule SlipdockCLI.RegistryTest do
  @moduledoc """
  `slipdock registry …` (#2072): what each command sends and shows. A usage
  error and a server refusal end in `System.halt/1`, so the usage errors are
  checked on `plan/3`, which decides them, and the refusals on
  `send_request/1`, which hands back what `out/3` would print.
  """
  # Sync: sets the SLIPDOCK_* variables, which are one environment for the
  # whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Registry}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))
  defp run(args, o \\ []), do: capture_io(fn -> Registry.run("registry", args, o) end)

  @grilling %{
    "id" => 11,
    "name" => "grilling",
    "description" => "Asks hard questions.",
    "path" => "grilling/SKILL.md",
    "version" => "0123456",
    "licence" => "MIT",
    "content_hash" => "abc123def4567890",
    "fetched_at" => "2026-11-08T02:00:00Z"
  }
  @source %{
    "id" => 4,
    "url" => "https://github.com/octo/skills",
    "kind" => "github",
    "name" => "octo/skills",
    "licence" => "MIT",
    "version" => "0123456",
    "fetched_at" => "2026-11-08T02:00:00Z",
    "report" => ["big/SKILL.md is larger than 256 KB, so it was skipped."],
    "seed" => false,
    "can_manage" => true,
    "entries" => [@grilling]
  }
  @plans %{"id" => 7, "code" => "plan", "name" => "Plans"}

  describe "sources" do
    test "registry lists them, a seed marked" do
      serve([{200, JSON.encode!(%{sources: [@source, %{@source | "id" => 5, "seed" => true}]})}])
      out = run([])

      assert_received {:request, "GET", "/api/skill-sources", _}
      assert out =~ ~r/4\s+octo\/skills\s+1\s+MIT/
      assert out =~ ~r/5\s+octo\/skills\s+1\s+MIT\s+\S+\s+seed/
    end

    test "with none says how to add one" do
      serve([{200, JSON.encode!(%{sources: []})}])
      assert run(["sources"]) =~ "no skill sources yet"
    end

    test "add sends the URL and shows the skills and what was left out" do
      serve([{201, JSON.encode!(%{source: @source})}])
      out = run(["add", "https://github.com/octo/skills"])

      assert_received {:request, "POST", "/api/skill-sources", body}
      assert JSON.decode!(body) == %{"url" => "https://github.com/octo/skills"}
      assert out =~ "added octo/skills (4): 1 skill"
      assert out =~ ~r/11\s+grilling\s+grilling\/SKILL.md\s+Asks hard questions./
      assert out =~ "left out: big/SKILL.md is larger than 256 KB"
    end

    test "add --seed asks for a seed, which the server refuses unless an admin" do
      assert {:ok, {:added, {:post, "/skill-sources", %{"url" => "u", "seed" => true}}}} =
               Registry.plan("registry", ["add", "u"], seed: true)

      assert {:ok, {:added, {:post, "/skill-sources", %{"url" => "u"} = body}}} =
               Registry.plan("registry", ["add", "u"], [])

      refute Map.has_key?(body, "seed")

      message = "forbidden: Only an admin can add a source for everyone."
      serve([{403, JSON.encode!(%{error: message})}])
      {:ok, {:added, request}} = Registry.plan("registry", ["add", "u"], seed: true)
      assert Registry.send_request(request) == {:error, 403, %{"error" => message}}
    end

    test "a refused fetch is the server's 422 and its sentence" do
      message = "https://intranet.test/SKILL.md is not a public address."
      serve([{422, JSON.encode!(%{error: message})}])

      {:ok, {:added, request}} =
        Registry.plan("registry", ["add", "https://intranet.test/SKILL.md"], [])

      assert Registry.send_request(request) == {:error, 422, %{"error" => message}}
    end

    test "refresh says what changed, and nothing when nothing did" do
      changes = %{added: ["c"], changed: ["a"], removed: [], unchanged: ["b"]}
      serve([{200, JSON.encode!(%{source: @source, changes: changes})}])
      out = run(["refresh", "4"])

      assert_received {:request, "POST", "/api/skill-sources/4/refresh", _}
      assert out =~ "refreshed octo/skills: added c; changed a"

      serve([
        {200, JSON.encode!(%{source: @source, changes: %{added: [], changed: [], removed: []}})}
      ])

      assert run(["refresh", "4"]) =~ "refreshed octo/skills: nothing changed"
    end

    test "source and rm reach the source by id" do
      serve([{200, JSON.encode!(%{source: @source})}])
      assert run(["source", "4"]) =~ "octo/skills"
      assert_received {:request, "GET", "/api/skill-sources/4", _}

      serve([{200, JSON.encode!(%{deleted: %{id: 4, name: "octo/skills", url: "x"}})}])
      assert run(["rm", "4"]) =~ "removed octo/skills and its skills"
      assert_received {:request, "DELETE", "/api/skill-sources/4", _}
    end

    test "somebody else's source is the server's 404" do
      serve([{404, ~s({"error":"skill source not found"})}])
      {:ok, {:removed, request}} = Registry.plan("registry", ["rm", "9"], [])

      assert Registry.send_request(request) ==
               {:error, 404, %{"error" => "skill source not found"}}
    end
  end

  describe "an entry" do
    test "prints the whole file, its hash, where it is enabled and which stages name it" do
      entry =
        Map.merge(@grilling, %{
          "body" => "---\nname: grilling\n---\n\nAsk one question at a time.\n",
          "source" => %{"id" => 4, "name" => "octo/skills", "url" => "x"},
          "enabled_on" => [%{"board" => @plans, "status" => "changed"}],
          "stages" => [%{"board" => @plans, "stage" => "Grill", "enabled" => true}]
        })

      serve([{200, JSON.encode!(%{entry: entry})}])
      out = run(["entry", "11"])

      assert_received {:request, "GET", "/api/skill-entries/11", _}
      assert out =~ "content_hash abc123def4567890"
      assert out =~ "enabled on Plans (plan): changed"
      assert out =~ "named by Plans (plan) · Grill"
      assert out =~ "Ask one question at a time."
    end
  end

  describe "a board's skills" do
    test "enable sends the entry and the hash read" do
      pinned = %{
        "name" => "grilling",
        "source_name" => "octo/skills",
        "pinned_hash" => "abc123def4567890"
      }

      serve([{201, JSON.encode!(%{skill: pinned})}])
      out = run(["enable", "11"], board: "plan", hash: "abc123def4567890")

      assert_received {:request, "POST", "/api/boards/plan/skills", body}
      assert JSON.decode!(body) == %{"entry" => "11", "hash" => "abc123def4567890"}
      assert out =~ "pinned grilling from octo/skills to abc123def456"
    end

    test "repin and disable name the skill on the board" do
      pinned = %{"name" => "grilling", "source_name" => "octo/skills", "pinned_hash" => "fff000"}
      serve([{200, JSON.encode!(%{skill: pinned})}])
      run(["repin", "grilling"], board: "plan", hash: "fff000")
      assert_received {:request, "PATCH", "/api/boards/plan/skills/grilling", body}
      assert JSON.decode!(body) == %{"hash" => "fff000"}

      serve([{200, JSON.encode!(%{disabled: %{name: "grilling", board: "plan"}})}])
      assert run(["disable", "grilling"], board: "plan") =~ "disabled grilling on plan"
      assert_received {:request, "DELETE", "/api/boards/plan/skills/grilling", _}
    end

    test "a reader is the server's 403" do
      message = "you only have read access to this board"
      serve([{403, JSON.encode!(%{error: message})}])

      {:ok, {:disabled, request}} =
        Registry.plan("registry", ["disable", "grilling"], board: "plan")

      assert Registry.send_request(request) == {:error, 403, %{"error" => message}}
    end

    test "no --board, or no --hash, is a usage error, and the hash is never guessed" do
      assert {:error, "--board is required" <> _} =
               Registry.plan("registry", ["enable", "11"], hash: "h")

      assert {:error, "--board is required" <> _} =
               Registry.plan("registry", ["disable", "x"], [])

      assert {:error, message} = Registry.plan("registry", ["enable", "11"], board: "plan")
      assert message =~ "--hash is required: read the skill first (slipdock registry entry 11)"

      assert {:error, "--hash is required" <> _} =
               Registry.plan("registry", ["repin", "grilling"], board: "plan")
    end
  end

  test "stages lists each board's stages and what each gets" do
    boards = [
      %{
        "board" => @plans,
        "stages" => [
          %{
            "stage" => "Grill",
            "skill" => "grilling",
            "enabled" => %{"source_name" => "octo/skills", "status" => "current"},
            "shipped" => false,
            "flagged" => false
          },
          %{
            "stage" => "Spec",
            "skill" => "slipdock-plan",
            "enabled" => nil,
            "shipped" => true,
            "flagged" => false
          },
          %{
            "stage" => "Cards",
            "skill" => "nowhere",
            "enabled" => nil,
            "shipped" => false,
            "flagged" => true
          }
        ]
      }
    ]

    serve([{200, JSON.encode!(%{boards: boards})}])
    out = run(["stages"])

    assert_received {:request, "GET", "/api/skill-stages", _}
    assert out =~ ~r/Plans \(plan\)\s+Grill\s+grilling\s+enabled, from octo\/skills/
    assert out =~ "a skill Slipdock ships"
    assert out =~ "nothing: not enabled here, not shipped"

    serve([{200, JSON.encode!(%{boards: []})}])
    assert run(["stages"]) =~ "no Playbook on a board you can read names a skill"
  end

  test "a missing argument or an unknown command is a usage error" do
    for sub <- ~w(add source refresh rm entry enable repin disable) do
      assert {:error, "usage: slipdock registry " <> _} = Registry.plan("registry", [sub], [])
    end

    assert {:error, "usage: " <> _} = Registry.plan("registry", ["frobnicate"], [])
  end

  test "--json passes the answer through" do
    serve([{200, JSON.encode!(%{sources: [@source]})}])
    json = run([], json: true)
    assert %{"sources" => [%{"name" => "octo/skills"}]} = JSON.decode!(json)
  end
end
