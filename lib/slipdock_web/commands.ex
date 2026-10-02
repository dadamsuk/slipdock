defmodule SlipdockWeb.Commands do
  @moduledoc """
  The catalogue behind the command palette (`Ctrl-P`), and the matching that
  narrows it as you type.

  A command is a map of `:label`, `:group`, `:icon`, an optional `:key` (the
  keyboard shortcut that also does it, shown on the right), optional
  `:keywords` the filter should match but the label does not say, and a
  `:to` saying what following it does:

    * `{:navigate, path}` — a live navigation
    * `{:patch, path}` — a live patch
    * `{:href, path, method}` — an ordinary request (sign out is a `delete`)
    * `{:event, name, params}` — pushed to the server, closing the palette

  `SlipdockWeb.ShortcutsHook` builds the list for the page you are on and
  `SlipdockWeb.Layouts.shortcut_palette/1` draws it. The keys themselves are in
  `SlipdockWeb.Shortcuts`.
  """

  @doc """
  Everything reachable from this page: the places, the boards you can open,
  the views this page offers, and the things a key would otherwise do.
  """
  def build(boards, jumps, board) do
    places() ++ actions() ++ views(jumps) ++ board_pages(board) ++ boards(boards)
  end

  defp places do
    [
      %{
        label: "All boards",
        group: "Go",
        icon: "hero-view-columns",
        key: "h",
        to: {:navigate, "/"}
      },
      %{
        label: "My work",
        group: "Go",
        icon: "hero-user",
        keywords: ["assigned", "mine", "todo"],
        to: {:navigate, "/work"}
      },
      %{
        label: "Wiki",
        group: "Go",
        icon: "hero-book-open",
        keywords: ["docs", "documents", "pages", "folders", "notes", "everything written"],
        to: {:navigate, "/wiki"}
      },
      %{
        label: "Search everything…",
        group: "Go",
        icon: "hero-magnifying-glass-circle",
        keywords: ["deep", "semantic", "meaning", "comments", "across boards", "find anything"],
        to: {:navigate, "/search"}
      },
      %{
        label: "Ask about everything",
        group: "Go",
        icon: "hero-sparkles",
        keywords: ["ai", "chat", "assistant", "question", "research"],
        to: {:navigate, "/ask"}
      },
      %{
        label: "Favourites",
        group: "Go",
        icon: "hero-heart",
        keywords: ["starred", "pinned", "shortcuts", "bookmarks"],
        to: {:navigate, "/favourites"}
      },
      %{label: "Groups", group: "Go", icon: "hero-user-group", to: {:navigate, "/groups"}},
      %{
        label: "Templates",
        group: "Go",
        icon: "hero-squares-plus",
        keywords: ["lists", "new board"],
        to: {:navigate, "/templates"}
      },
      %{
        label: "Account",
        group: "Go",
        icon: "hero-user-circle",
        keywords: ["profile", "name", "quota", "cards left", "sign out"],
        to: {:navigate, "/account"}
      },
      %{
        label: "Settings",
        group: "Go",
        icon: "hero-adjustments-horizontal",
        keywords: ["preferences", "quick add", "ai key", "openrouter"],
        to: {:navigate, "/account/settings"}
      },
      %{
        label: "API tokens",
        group: "Go",
        icon: "hero-key",
        keywords: ["cli", "api", "token", "agent"],
        to: {:navigate, "/account/tokens"}
      },
      %{
        label: "Import & export",
        group: "Go",
        icon: "hero-arrows-right-left",
        keywords: ["download", "backup", "move boards", "json", "zip"],
        to: {:navigate, "/account/data"}
      }
    ]
  end

  defp actions do
    [
      %{
        label: "Find a card…",
        group: "Do",
        icon: "hero-magnifying-glass",
        key: "Ctrl-O",
        keywords: ["open", "search", "jump"],
        to: {:event, "shortcut_panel", %{"panel" => "find"}}
      },
      %{
        label: "Quick add a card",
        group: "Do",
        icon: "hero-plus",
        key: "q",
        keywords: ["new", "capture"],
        to: {:event, "toggle_quick_add", %{}}
      },
      %{
        label: "Alerts",
        group: "Do",
        icon: "hero-bell",
        key: "l",
        keywords: ["notifications", "automations"],
        to: {:event, "toggle_alerts", %{}}
      },
      %{
        label: "Keyboard shortcuts",
        group: "Do",
        icon: "hero-command-line",
        key: "?",
        keywords: ["keys", "help"],
        to: {:event, "shortcut_panel", %{"panel" => "help"}}
      },
      %{
        label: "Sign out",
        group: "Do",
        icon: "hero-arrow-right-start-on-rectangle",
        keywords: ["log out", "logout"],
        to: {:href, "/logout", "delete"}
      }
    ]
  end

  # The views this page offers, which are also what `v` lists.
  defp views(jumps) do
    for jump <- jumps do
      %{
        label: jump.label,
        group: "View",
        icon: jump.icon,
        key: jump[:key],
        current: jump[:current] == true,
        to: {:patch, jump.patch}
      }
    end
  end

  defp board_pages(nil), do: []

  defp board_pages(board) do
    for {label, icon, path, words} <- [
          {"Tags", "hero-tag", "/tags", ["labels"]},
          {"Activity", "hero-clock", "/activity", ["history", "log"]},
          {"Archive", "hero-archive-box", "/archive", ["archived"]},
          {"Automations", "hero-bolt", "/automations", ["rules", "alerts"]},
          {"Board settings", "hero-cog-6-tooth", "/settings", ["rename", "colour", "wip"]}
        ] do
      %{
        label: "#{label} — #{board.name}",
        group: "This board",
        icon: icon,
        keywords: words,
        to: {:navigate, "/boards/#{board.id}#{path}"}
      }
    end
  end

  defp boards(boards) do
    for board <- boards do
      %{
        label: board.name,
        group: "Boards",
        icon: "hero-view-columns",
        key: board.shortcut,
        keywords: [board.code],
        to: {:navigate, "/boards/#{board.id}"}
      }
    end
  end

  @doc """
  The commands matching `q`, best first. An empty query is everything, in the
  order the catalogue gives.

  Matching walks out from the exact to the vague: the start of the label, the
  start of a word in it, anywhere in it, anywhere in the words around it, and
  finally the letters in order but not together — so `bs` finds *Board
  settings* without listing everything with a b in it first.
  """
  def search(commands, q) when is_binary(q) do
    case String.downcase(String.trim(q)) do
      "" ->
        commands

      q ->
        commands
        |> Enum.map(&{rank(&1, q), &1})
        |> Enum.reject(&(elem(&1, 0) == nil))
        |> Enum.sort_by(fn {rank, c} -> {rank, c.label} end)
        |> Enum.map(&elem(&1, 1))
    end
  end

  defp rank(command, q) do
    label = String.downcase(command.label)
    around = Enum.join([command.group | command[:keywords] || []], " ") |> String.downcase()

    cond do
      String.starts_with?(label, q) -> 0
      word_start?(label, q) -> 1
      String.contains?(label, q) -> 2
      String.contains?(around, q) -> 3
      subsequence?(label, q) -> 4
      true -> nil
    end
  end

  defp word_start?(label, q) do
    label |> String.split(~r/[\s—·\-\/]+/, trim: true) |> Enum.any?(&String.starts_with?(&1, q))
  end

  # The query's letters in order, with anything between them.
  defp subsequence?(label, q) do
    q
    |> String.graphemes()
    |> Enum.reduce_while(label, fn char, rest ->
      case String.split(rest, char, parts: 2) do
        [_, after_it] -> {:cont, after_it}
        _ -> {:halt, nil}
      end
    end)
    |> is_binary()
  end
end
