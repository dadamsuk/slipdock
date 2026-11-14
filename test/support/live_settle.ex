defmodule SlipdockWeb.LiveSettle do
  @moduledoc """
  Wait for a LiveView to have handled what was sent to it, before looking
  (#3163, after #2961).

  `render/1` and `has_element?/2` send the view one ping. A broadcast the
  test caused (an API call, a context function that publishes) may still be
  in the view's mailbox behind it, and the view often answers a broadcast by
  sending itself a `send_update` or a message, which lands behind the ping:
  the look sees the page from before (#2961, #2982, #2986, #2984, #2994).

  `settled/1` takes the two hops: `:sys.get_state/1` from the test comes
  after anything the test's own process sent or broadcast, so when it
  returns the view has handled that and queued its follow-up; the `render/1`
  after it then comes behind the follow-up. Call it between the change and
  the look:

      {:ok, _} = Machines.rename(machine, "new name")
      view |> LiveSettle.settled() |> has_element?("#machine-1", "new name")

  A change broadcast from another process (a job, a GenServer) isn't ordered
  by this: wait for that process first (`assert_receive` the broadcast on a
  topic the test subscribed to, or `:sys.get_state/1` on it).
  """

  @doc "Waits for `view` to handle what was sent before, and its follow-up; returns `view`."
  def settled(view) do
    _ = :sys.get_state(view.pid)
    _ = Phoenix.LiveViewTest.render(view)
    view
  end
end
