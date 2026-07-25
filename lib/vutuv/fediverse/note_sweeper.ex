defmodule Vutuv.Fediverse.NoteSweeper do
  @moduledoc """
  The hard ceiling under the stored replies from other networks (issue #1069).

  Everything else that deletes a remote reply depends on somebody doing
  something: the author withdrawing it, the member taking it down, a reader
  reporting it, the operator blocking the server, or the on-view freshness check
  noticing it is gone from its origin. Each of those can fail to happen — the
  `Delete` never arrives because the server was down or we defederated, and a
  copy nobody has opened in months is never checked at all.

  So once an hour this deletes every note whose `expires_at` has passed, and
  that is the promise the privacy page can actually make: six months from
  arrival at the very latest, whatever else does or does not happen. A note
  confirmed still published at its origin pushes that date forward
  (`Vutuv.Fediverse.refresh_note/1`), so a reply people keep reading tracks its
  original while an abandoned copy is collected.

  Nothing is logged per row — an expiry run can remove thousands and would
  drown the ledger, which exists for member takedowns. The count goes to the log
  in aggregate, the way `Vutuv.Fediverse.FollowerPruner` reports.

  Gated twice, like the pruner: the child starts only when
  `:fediverse_note_sweeping` is on (off in tests, so it never touches the SQL
  sandbox from outside), and it is a no-op while `:fediverse_enabled` is off.
  """

  use GenServer

  require Logger

  alias Vutuv.Fediverse

  @interval :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      if Fediverse.enabled?() do
        case Fediverse.expire_due_notes() do
          0 -> :ok
          count -> Logger.info("Fediverse note sweep: deleted #{count} expired remote reply(s)")
        end
      end
    rescue
      error -> Logger.error("Fediverse note sweep failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
