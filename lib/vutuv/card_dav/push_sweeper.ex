defmodule Vutuv.CardDav.PushSweeper do
  @moduledoc """
  Sends the WebDAV-Push notifications for the CardDAV address book (issue
  #1705): every two minutes it takes the least recently checked registrations,
  brings each owner's book up to date, and pushes the ones that actually moved.

  **Why a sweeper here, when the rest of `Vutuv.CardDav` deliberately computes
  on request.** Push inverts the question: the server has to notice a change
  with nobody asking. For the member's own actions — follow, unfollow, a mark,
  a level change — a hook would do. The case that matters is the other one: a
  *contact* changes their phone number, and that has to reach the device
  without the member touching anything. Detecting that would mean hooking every
  write path on every profile section, which is a dozen places to remember
  forever; recomputing the book is one place that cannot go stale.

  The cost is honest and named: one card render per contact per pass for every
  member who has a push registration. That is nothing for the handful of
  clients that speak this today (DAVx⁵), and if it ever stops being nothing the
  fix is a cheap change detector in front of `refresh/1`, not another
  architecture.

  Gated twice, like the Fediverse sweepers: the child starts only when
  `:carddav_push_sweeping` is on (off in tests, so it never reaches into the
  SQL sandbox from outside), and a pass is a no-op while either
  `:carddav_enabled` or Web Push is off.
  """

  use GenServer

  require Logger

  alias Vutuv.CardDav

  # Deliberately shorter than the due floor the query applies, so a
  # registration is picked up on the first pass after it falls due rather than
  # on the second (see `CardDav.push_due/1`). A pass with nothing due costs one
  # indexed query.
  @interval :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      case CardDav.push_due() do
        0 -> :ok
        count -> Logger.info("CardDAV push: notified #{count} device(s)")
      end
    rescue
      error -> Logger.error("CardDAV push sweep failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
