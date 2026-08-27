defmodule Vutuv.Posts.TopPosters do
  @moduledoc """
  Periodically cached "who to follow" candidate pool.

  `Posts.top_recent_posters/2` ranks the window's posters by the hearts their
  in-window posts collected — a whole-window aggregate over posts and likes
  that the profile page used to run on every single mount (including every
  crawler's dead render), although the ranking is identical for every viewer
  and moves only as fast as posts and likes land. One GenServer owns the slow
  path, exactly the `Vutuv.Social.PopularUsers` deal: it recomputes the pool
  every few minutes into a `read_concurrency` ETS table, and readers take
  their prefix from the snapshot with no database round trip. When the
  snapshot cannot answer (application boot, tests — the refresh timer is off
  under `config :vutuv, :refresh_top_posters, false` — or an unexpected
  window/limit), `top/2` returns `:miss` and `Posts.top_recent_posters/2`
  transparently falls back to the live query, so behaviour is unchanged, only
  cheaper. The per-viewer exclusions stay per-request in the profile.
  """

  use Vutuv.EtsCache.Snapshot,
    refresh_every: :timer.minutes(10),
    refresh_flag: :refresh_top_posters

  alias Vutuv.EtsCache

  # The one posting window the profile asks for; any other window is a :miss.
  @window_days 28
  @pool_size 100

  @doc "The snapshot's posting window in days (the profile rail's window)."
  def window_days, do: @window_days

  @doc "How many posters the snapshot ranks (the largest servable limit)."
  def pool_size, do: @pool_size

  @doc """
  The cached top `limit` posters of the `days` window as `{:ok, users}`, or
  `:miss` when the snapshot cannot answer (a different window, not seeded
  yet, table absent, or `limit` beyond the pool).
  """
  def top(days, limit, table \\ default_table())

  def top(days, limit, _table) when days != @window_days or limit > @pool_size, do: :miss

  def top(_days, limit, table) do
    with {:ok, users} <- EtsCache.fetch(table, :pool), do: {:ok, Enum.take(users, limit)}
  end

  @impl true
  def snapshot(table) do
    :ets.insert(
      table,
      {:pool, Vutuv.Posts.compute_top_recent_posters(@window_days, @pool_size)}
    )
  end
end
