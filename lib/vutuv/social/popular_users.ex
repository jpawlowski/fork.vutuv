defmodule Vutuv.Social.PopularUsers do
  @moduledoc """
  Periodically cached "most followed members" pool.

  `Social.most_followed_users/1` used to run a GROUP BY over the whole
  `follows` table on every call — and it is called from hot paths: the
  profile's "Who to follow" card and the `/listings/most_followed_users` page.
  (The feed rail was the third and hottest caller until it became the "New
  here" welcome card, which draws from the newest members instead.) The ranking
  moves slowly — it takes many follows to change a top spot — and the card
  shuffles its slice anyway, so freshness within a few minutes is plenty.

  One GenServer owns the slow path: it recomputes the top 1000 every few
  minutes into a `read_concurrency` ETS table; readers take their prefix from
  the snapshot with no database round trip. When the table is missing or not
  yet seeded (application boot, tests — the refresh timer is off under
  `config :vutuv, :refresh_popular_users, false`), `top/2` returns `:miss`
  and `Social.most_followed_users/1` transparently falls back to the query,
  so behaviour is unchanged, only cheaper.
  """

  use Vutuv.EtsCache.Snapshot,
    refresh_every: :timer.minutes(10),
    refresh_flag: :refresh_popular_users

  alias Vutuv.EtsCache

  @pool_size 1000

  @doc "How many members the snapshot ranks (the largest servable limit)."
  def pool_size, do: @pool_size

  @doc """
  The cached top `limit` as `{:ok, users}`, or `:miss` when the snapshot
  cannot answer (not seeded yet, table absent, or `limit` beyond the pool).
  """
  def top(limit, table \\ default_table())

  def top(limit, _table) when limit > @pool_size, do: :miss

  def top(limit, table) do
    with {:ok, users} <- EtsCache.fetch(table, :pool), do: {:ok, Enum.take(users, limit)}
  end

  @impl true
  def snapshot(table) do
    :ets.insert(table, {:pool, Vutuv.Social.compute_most_followed(@pool_size)})
  end
end
