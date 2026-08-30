defmodule Vutuv.Fediverse.QuoteResolver do
  @moduledoc """
  Finishes the quote resolutions whose first attempt never got to the end
  (issue #1609).

  `Vutuv.Fediverse.resolve_quote/1` runs off the inbox on
  `Vutuv.TaskSupervisor`, fire and forget, because it makes up to three requests
  to two other servers and the inbox owes its 202 long before those answer. What
  that shape has no answer for is the attempt that dies: a blue/green deploy
  stops the slot mid-fetch, a crash takes the task with it, a node goes away
  between the insert and the task's first line. Nothing is logged, because
  nothing failed as far as the inbox is concerned — and the row then keeps a
  `quote_uri` nobody ever went back to, so a quote that would have drawn a card
  stays a plain link for as long as the cached copy lives.

  So the unfinished work is a row and this is the thing whose standing job is to
  find it and run it again, the shape `Vutuv.Fediverse.MediaRefetcher` and
  `Vutuv.Newsletters.BroadcastResumer` use. It is cheap because the queue is
  almost always empty: `Vutuv.Fediverse.due_quote_resolutions/1` is a partial
  index lookup that matches nothing in a healthy minute.

  **One retry per row, not a ladder.** Every finished resolution stamps
  `quote_checked_at` whatever it decided, so a row leaves this queue by being
  tried rather than by succeeding — a quote of a post that is gone cannot come
  back on the next tick and hold the front of every batch, which is the
  starvation issue #1316 cost us. A consent stamp that is granted *later* never
  needs this path either: it arrives as an `Update`, which resolves the quote
  again by itself.

  Gated like the other fediverse sweepers: the child starts only when
  `:fediverse_quote_resolve` is on (off in tests, where it would reach outside
  the SQL sandbox, and off on an installation that must not call out at all),
  and a run is a no-op while `:fediverse_enabled` is off.
  """

  use GenServer

  require Logger

  alias Vutuv.Fediverse

  # Deliberately shorter than the grace a row waits before it counts as
  # abandoned (5 min), so ticks cannot beat against that wait and run the queue
  # at half speed — the interval trap `Vutuv.Fediverse.CountsRefresher` records.
  @interval :timer.minutes(2)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      case sweep() do
        0 -> :ok
        count -> Logger.info("Fediverse quotes: resumed #{count} unfinished resolution(s)")
      end
    rescue
      error -> Logger.error("Fediverse quote resume failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp sweep do
    if Fediverse.enabled?(), do: Fediverse.resume_quote_resolutions(), else: 0
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
