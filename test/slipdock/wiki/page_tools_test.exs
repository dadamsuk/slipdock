defmodule Slipdock.Wiki.PageToolsTest do
  @moduledoc "The AI tools over a wiki page (#1539)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.AIStub
  alias Slipdock.Wiki.PageTools

  @secret "🔐β 💡hint💡c2VjcmV0 🔐"

  setup do
    %{user: user_fixture()}
  end

  defp page(body), do: %{title: "Launch plan", body: body}

  defp sent do
    assert_receive {:ai_request, %{"messages" => messages}}
    Enum.map_join(messages, "\n", & &1["content"])
  end

  test "summarise gives the model's words, and sends the title and body", %{user: user} do
    AIStub.reply_with("  It is about the launch.  ")

    assert {:ok, answer} = PageTools.run("summarise", page("We launch on Friday."), user)
    assert answer.tool == "summarise"
    assert answer.text == "It is about the launch."
    assert answer.items == []
    refute answer.truncated
    refute answer.concealed

    prompt = sent()
    assert prompt =~ "Launch plan"
    assert prompt =~ "We launch on Friday."
    assert prompt =~ "not instructions"
  end

  test "actions come back as clean lines, and as Markdown", %{user: user} do
    AIStub.reply_with(%{
      "actions" => ["  Ring   the\nprinters ", "Ring the printers", "", 7, "Book the room"]
    })

    assert {:ok, answer} = PageTools.run("actions", page("Ring them."), user)
    assert answer.items == ["Ring the printers", "Book the room"]
    assert answer.text == "- Ring the printers\n- Book the room"
  end

  test "lists are held to their limits and a line to a card title's size", %{user: user} do
    AIStub.reply_with(%{"titles" => Enum.map(1..9, &"Title #{&1}")})
    assert {:ok, %{items: items}} = PageTools.run("titles", page("x"), user)
    assert length(items) == 5

    AIStub.reply_with(%{"actions" => [String.duplicate("a", 500)]})
    assert {:ok, %{items: [line]}} = PageTools.run("actions", page("x"), user)
    assert String.length(line) == 200
  end

  test "no actions is an answer, not a failure", %{user: user} do
    AIStub.reply_with(%{"actions" => []})
    assert {:ok, %{items: [], text: ""}} = PageTools.run("actions", page("A poem."), user)
  end

  test "a list of the wrong shape is an empty list", %{user: user} do
    AIStub.reply_with(%{"actions" => "ring them"})
    assert {:ok, %{items: []}} = PageTools.run("actions", page("x"), user)
  end

  test "an answer that isn't JSON says so", %{user: user} do
    AIStub.reply_with("I would rather not.")

    assert {:error, :unprocessable_entity, message} = PageTools.run("actions", page("x"), user)
    assert message =~ "JSON"
  end

  test "encrypted passages never reach the model, and the answer says so", %{user: user} do
    AIStub.reply_with("Summary.")

    assert {:ok, answer} = PageTools.run("summarise", page("Open words. #{@secret}"), user)
    assert answer.concealed

    prompt = sent()
    assert prompt =~ "Open words."
    refute prompt =~ "c2VjcmV0"
  end

  test "a page of nothing but ciphertext has nothing to work on", %{user: user} do
    assert {:error, :unprocessable_entity, message} =
             PageTools.run("summarise", page(@secret), user)

    assert message =~ "nothing on this page"
    refute_received {:ai_request, _}
  end

  test "a long page is cut, and the answer says so", %{user: user} do
    AIStub.reply_with("Summary.")
    body = String.duplicate("a", PageTools.page_chars()) <> "THE END"

    assert {:ok, %{truncated: true}} = PageTools.run("summarise", page(body), user)
    refute sent() =~ "THE END"
  end

  test "an empty page, a nil body and an unknown tool ask no model", %{user: user} do
    assert {:error, :unprocessable_entity, _} = PageTools.run("summarise", page("  \n"), user)
    assert {:error, :unprocessable_entity, _} = PageTools.run("summarise", page(nil), user)
    assert {:error, :bad_request, message} = PageTools.run("poem", page("x"), user)
    assert message =~ "summarise"
    assert {:error, :bad_request, _} = PageTools.run(nil, page("x"), user)
    refute_received {:ai_request, _}
  end

  test "a failing model's reason is passed on", %{user: user} do
    AIStub.fail_with(429, "slow down")

    assert {:error, :unprocessable_entity, message} =
             PageTools.run("summarise", page("x"), user)

    assert message =~ "rate-limited"
  end

  test "every tool has a prompt", %{user: user} do
    for name <- PageTools.names() do
      AIStub.reply_with(%{"actions" => [], "titles" => []})
      assert {:ok, %{tool: ^name}} = PageTools.run(name, page("x"), user)
    end
  end
end
