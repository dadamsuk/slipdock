defmodule SlipdockCLI.VocabularyTest do
  @moduledoc "`slipdock automation-help`: the vocabulary as the server sends it, runner action and all."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  test "lists every action with its keys, the runner action included" do
    vocabulary = %{
      "vocabulary" => %{
        "triggers" => [
          %{
            "type" => "card_entered",
            "required" => [],
            "optional" => ["column"],
            "description" => "a card arrives in a list"
          }
        ],
        "condition_fields" => ["priority"],
        "condition_ops" => ["is"],
        "actions" => [
          %{
            "type" => "runner",
            "required" => ["pool"],
            "optional" => ["kind", "prompt"],
            "description" => "send the card to a coding agent"
          }
        ],
        "placeholders" => ["{{card.title}}"]
      },
      "example" => %{"name" => "x"}
    }

    out = capture_io(fn -> Render.vocabulary(vocabulary) end)
    assert out =~ ~r/runner\s+send the card to a coding agent/
    assert out =~ "keys: pool*, kind, prompt"
  end
end
