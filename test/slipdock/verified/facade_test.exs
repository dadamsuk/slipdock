defmodule Slipdock.Verified.FacadeTest do
  @moduledoc """
  `Slipdock.Verified` is the door to the modules under it (#2842): every
  function it exported before its code moved out is still exported, at the
  same arities, and a module under it holds the code.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Boards.Card
  alias Slipdock.Verified

  # `Slipdock.Verified.__info__(:functions)` as it was before the split.
  @exported [
    already_merged?: 1,
    assigned: 4,
    audit_every: 1,
    audit_prompt: 2,
    audit_sampled?: 2,
    bar_pickup_check: 0,
    builder_mutants: 1,
    check_create: 3,
    check_done_move: 3,
    check_move: 3,
    check_update: 3,
    clear_audit_alerts: 1,
    cut: 3,
    dash?: 1,
    decide: 5,
    defect_profiles: 0,
    defect_review?: 2,
    defect_review_step: 1,
    docs_places: 0,
    docs_places_builder: 0,
    docs_places_rule: 0,
    docs_places_scope: 2,
    docs_places_step: 2,
    docs_places_step: 3,
    docs_places_step: 4,
    epic?: 1,
    epic_note: 1,
    every_instance_sentence: 0,
    evidence?: 1,
    evidence?: 2,
    evidence_text: 1,
    finishing_kinds: 0,
    fit_prompt: 3,
    fit_prompt: 4,
    gated?: 1,
    held_purpose: 0,
    hold_for_a_person?: 2,
    limit_purpose: 0,
    may_close_wait: 2,
    merge_finished: 2,
    merge_kind: 0,
    merge_pool: 1,
    merge_pool: 2,
    merge_status: 1,
    moot_bar_sentence: 0,
    moved: 2,
    mutation_profiles: 0,
    mutation_review?: 2,
    mutation_step: 1,
    mutation_step: 2,
    neutral?: 1,
    neutral_pr_title: 1,
    no_code?: 1,
    no_code_note: 1,
    not_verified?: 1,
    nothing_to_merge?: 1,
    open_rework: 1,
    open_subcards: 1,
    person: 1,
    pr_branch: 1,
    pre_existing_sentence: 0,
    pre_push_checks: 1,
    previous_verdict: 1,
    profile_message: 3,
    profile_raise: 3,
    profiles_note: 1,
    prompt_cuts: 1,
    queue_merge: 1,
    queue_merge: 2,
    queue_merge: 3,
    raise_text: 1,
    rebase_fixes?: 1,
    recent_audit_misses: 1,
    recent_audit_misses: 2,
    recent_audit_misses: 3,
    rejection: 1,
    rejection_limit: 1,
    released?: 1,
    released?: 2,
    reopen_message: 2,
    reopen_move_message: 3,
    requeue_verify: 1,
    rework_title: 2,
    rule_proposal_sentence: 0,
    rule_rejection_sentence: 0,
    same_actor?: 2,
    saved: 3,
    server_actor: 0,
    ship_instructions: 1,
    spike_note: 1,
    suite_text: 1,
    switches: 1,
    unverified_profiles: 0,
    urgent_disagreement?: 1,
    verify_kind: 0,
    verify_prompt: 2,
    verify_prompt: 3,
    wait_closed: 2,
    who: 1
  ]

  # The modules the code moved to.
  @holders [
    Verified.Actors,
    Verified.Audits,
    Verified.Decisions,
    Verified.DocsPlaces,
    Verified.Epics,
    Verified.Evidence,
    Verified.Gate,
    Verified.Jobs,
    Verified.Merging,
    Verified.Prompts,
    Verified.Rejections,
    Verified.Shipping
  ]

  test "every function exported before the split is still exported" do
    assert @exported -- Verified.__info__(:functions) == []
  end

  test "the door exports nothing the module didn't before" do
    assert Verified.__info__(:functions) -- @exported == []
  end

  test "each function's code is in exactly one module under Slipdock.Verified" do
    for {name, arity} <- @exported do
      holders = Enum.filter(@holders, &Enum.member?(&1.__info__(:functions), {name, arity}))

      assert [_one] = holders, "#{name}/#{arity} is held by #{inspect(holders)}"
    end
  end

  test "a default argument still fills in: the shorter call answers as the full one" do
    card = %Card{id: 7, evidence: "ran the suite"}

    assert Verified.evidence?(card)
    assert Verified.evidence?(card) == Verified.evidence?(card, %{})
    refute Verified.evidence?(%Card{id: 7})

    assert Verified.docs_places_step("origin/main", "abc1234") ==
             Verified.docs_places_step("origin/main", "abc1234", :in, [])

    assert Verified.fit_prompt(card, [], fn _ -> "short" end) == "short"
  end
end
