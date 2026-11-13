[
  %{
    id: "writing",
    steps: [],
    title: "Writing the card",
    actors: [:person],
    person: true,
    gist: "You write the ask and a bar that can be met."
  },
  %{
    id: "claimed",
    steps: ["Writing code", "Reworking after verify failed"],
    title: "Queued and claimed",
    actors: [:board, :builder],
    person: false,
    gist: "A rule queues a job; a runner pulls it; the bar locks."
  },
  %{
    id: "building",
    steps: ["Waiting for human"],
    title: "Building",
    actors: [:builder],
    person: true,
    gist: "Keeps to the handbook's rules, runs the pre-push checks. Waits on you if stuck."
  },
  %{
    id: "shipping",
    steps: [],
    title: "Shipping",
    actors: [:builder, :ci],
    person: false,
    gist: "Pushes main, or opens a pull request whose CI is the full test run."
  },
  %{
    id: "submitting",
    steps: ["Verifying", "Waiting for human to accept"],
    title: "Submitting",
    actors: [:builder],
    person: false,
    gist: "Completes with evidence, a Handbook line and Findings."
  },
  %{
    id: "verifying",
    steps: [
      "Verify failed; queued for rework",
      "Waiting for human (rejection limit)",
      "Waiting for human (held before merge)",
      "Accepted; merging",
      "Merged",
      "Done"
    ],
    title: "Verifying",
    actors: [:verifier, :person],
    person: true,
    gist: "A second agent accepts or rejects. You decide without one, or past the limit."
  },
  %{
    id: "afterwards",
    steps: ["Shipped to production", "Reopened"],
    title: "Afterwards",
    actors: [:ci, :person],
    person: true,
    gist: "Deploy, then you triage findings and apply the gardener's proposals."
  }
]
