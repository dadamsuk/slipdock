defmodule Slipdock.AttentionTest do
  @moduledoc """
  Who clears a flag (#2624): `person` when nobody but a person will,
  `auto` when the board's own processes will, `none` for a bookmark.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Attention, Boards, CardState, Repo}
  alias Slipdock.Boards.Card

  defp card(attrs), do: struct(Card, Map.merge(%{flags: [], blocked_by: []}, attrs))
  defp open_blocker(id), do: %Card{id: id, completed: false, archived_at: nil}
  defp verifier, do: %CardState{verifier: true}

  describe "of/2" do
    test "waiting, flagged and stuck always need a person" do
      for flag <- ~w(waiting flagged stuck) do
        assert {"person", why} = Attention.of(flag, card(%{flags: [flag]}))
        assert why =~ ~r/\w/
      end
    end

    test "starred asks nothing of anyone" do
      assert {"none", "A bookmark" <> _} = Attention.of("starred", card(%{}))
    end

    test "blocked clears itself while a blocker card is open, naming it" do
      assert {"auto", "Clears itself when #12, #13 is done."} =
               Attention.of("blocked", card(%{blocked_by: [open_blocker(12), open_blocker(13)]}))
    end

    test "blocked with no open blocker card needs a person" do
      done = %Card{id: 4, completed: true, archived_at: nil}
      released = %Card{id: 5, completed: false, archived_at: nil, verify_released: true}

      for blockers <- [[], [done], [released], %Ecto.Association.NotLoaded{}] do
        assert {"person", "Blocked on something outside the board" <> _} =
                 Attention.of("blocked", card(%{blocked_by: blockers}))
      end
    end

    test "review pending with a verifier clears itself; without one, a person decides" do
      assert {"auto", "A verifier agent" <> _} =
               Attention.of("review", card(%{verify_state: "pending", state: verifier()}))

      assert {"person", "Awaiting verification: no verifier agent" <> _} =
               Attention.of("review", card(%{verify_state: "pending", state: %CardState{}}))

      assert {"person", _} = Attention.of("review", card(%{verify_state: "pending", state: nil}))
    end

    test "review being merged clears itself; held for a merge, or by hand, needs a person" do
      assert {"auto", "Accepted: the merge runner" <> _} =
               Attention.of("review", card(%{verify_state: "merging"}))

      assert {"person", "Accepted, and held for a person" <> _} =
               Attention.of("review", card(%{verify_state: "held", state: verifier()}))

      for state <- [nil, "accepted", "rejected"] do
        assert {"person", "Flagged for review by hand" <> _} =
                 Attention.of("review", card(%{verify_state: state, state: verifier()}))
      end
    end

    test "a flag it doesn't know falls to a person" do
      assert {"person", _} = Attention.of("later", card(%{}))
    end
  end

  describe "map/1" do
    test "every flag on the card, with its attention and why" do
      c = card(%{flags: ["starred", "waiting"]})

      assert %{
               "starred" => %{"attention" => "none", "why" => _},
               "waiting" => %{"attention" => "person", "why" => "Waits on a person's answer."}
             } = Attention.map(c)

      assert Attention.map(card(%{})) == %{}
      assert Attention.map(%{}) == %{}
    end

    test "person?/2 and attention/2 read the same answer" do
      c = card(%{blocked_by: [open_blocker(1)]})
      assert Attention.attention("blocked", c) == "auto"
      refute Attention.person?("blocked", c)
      assert Attention.person?("waiting", c)
    end
  end

  describe "CardState's verifier" do
    setup do
      board = board_fixture()
      %{board: board, card: card_fixture(hd(board.columns), %{"title" => "Submitted"})}
    end

    test "is on only with verified work and a verify pool", %{board: board, card: card} do
      refute CardState.verifier?(board)
      refute CardState.verifier?(%{board | verify_work: true, verify_pool: nil})
      refute CardState.verifier?(%{board | verify_work: true, verify_pool: ""})
      refute CardState.verifier?(%{board | verify_work: false, verify_pool: "verify"})
      assert CardState.verifier?(%{board | verify_work: true, verify_pool: "verify"})

      [plain] = CardState.put([card], board)
      refute plain.state.verifier

      board =
        board |> Ecto.Changeset.change(verify_work: true, verify_pool: "verify") |> Repo.update!()

      [pooled] = CardState.put([card], board)
      assert pooled.state.verifier
    end

    test "a pending card read with its state clears itself on a pool board", %{
      board: board,
      card: card
    } do
      board |> Ecto.Changeset.change(verify_work: true, verify_pool: "verify") |> Repo.update!()
      card |> Ecto.Changeset.change(verify_state: "pending", flags: ["review"]) |> Repo.update!()

      assert {"auto", _} =
               Attention.of("review", Boards.with_state(Boards.Cards.get_card!(card.id)))
    end
  end
end
