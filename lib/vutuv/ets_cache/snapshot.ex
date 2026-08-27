defmodule Vutuv.EtsCache.Snapshot do
  @moduledoc """
  The shell every *periodically rebuilt* ETS cache in this application shares: a
  `Vutuv.EtsCache` whose owner recomputes the whole table on a timer.

  `Vutuv.EtsCache` answers who owns the table and what a read does when it is
  missing. That leaves a second question it deliberately does not answer — when
  the contents are recomputed — and three caches were spelling out the same
  answer by hand: `refresh/1`, an `init/1` that reads `refresh_every:` and fires
  a `refresh?`-gated 0ms seed, `handle_call(:refresh, …)`,
  `handle_info(:refresh, …)`, the `handle_info(_other, …)` catch-all,
  `schedule/1` and `enabled?/0`. Only the config key and the body of
  `snapshot/1` ever differed.

      use Vutuv.EtsCache.Snapshot,
        refresh_every: :timer.minutes(10),
        refresh_flag: :refresh_popular_users

  The module then implements the one callback, and nothing else:

      @impl true
      def snapshot(table) do
        :ets.insert(table, {:pool, Vutuv.Social.compute_most_followed(@pool_size)})
      end

  `refresh_flag:` must be a **literal** atom — it is read at compile time, so a
  module attribute does not work there. Naming it is mandatory rather than
  defaulted because it is the switch that stops the timer under test, and a
  cache that forgets it would query the Repo from a process owning no sandbox
  connection.

  ## Why a separate module and not another option on `use Vutuv.EtsCache`

  Not because the others have no timer — **all** of this application's ETS
  caches tick. The difference is what the tick does. A snapshot's contents are a
  pure function of the database, so the whole table can be thrown away and
  rebuilt, which is exactly what `snapshot/1` does. The rest *sweep*:
  `Vutuv.RateLimiter` and `VutuvWeb.Live.MountHandoff` hold rows written by
  other processes, and `Vutuv.SocialFeed.Cache` fills per entry on demand and
  expires by TTL — for all three a wholesale rebuild would destroy the very
  rows they exist to keep. They also must keep working under test, so they want
  neither the `refresh_flag:` kill switch nor a synchronous `refresh/1`.

  Folding "rebuild me every N" into the ownership `use` would hand those three
  options they must decline, which is the mistake `Vutuv.EtsCache` avoided when
  it kept `access:` and `created_by:` apart. A cache that owns a table takes
  `Vutuv.EtsCache`; one that also rebuilds it wholesale on a clock takes this.

  ## Why `:protected`, and why the seed is a message

  A snapshot has exactly one writer — the owning GenServer, from `snapshot/1` —
  so the table is always `access: :protected`. That is the shape, not a choice
  left open: a value written from outside would be thrown away by the next
  rebuild anyway.

  The seed is a 0ms `Process.send_after/3` rather than an inline call in
  `init/1`, because the recompute is the expensive scan the cache exists to
  amortise and it must not block the supervisor at boot. Until it lands, reads
  miss and every caller falls back to the direct query — exactly the pre-cache
  behaviour, which is also what tests get: `refresh_flag:` names the
  `config :vutuv, <flag>` that is `false` in `config/test.exs`, so the
  application singleton never ticks under test and an isolated instance is
  started with `refresh?: false` and driven by `refresh/1` by hand.

  The `handle_info(_other, …)` catch-all is emitted after the using module's own
  code, so a cache that needs to listen for something else (a PubSub event that
  should re-rank early, say) can still add its own clauses.
  """

  @doc """
  Recomputes the cache's contents into `table`. Called in the owning
  GenServer, both for the boot seed and for every scheduled refresh; its return
  value is ignored. Raising takes the cache process down with it, which is the
  supervisor's problem to solve — the readers meanwhile miss and fall back.
  """
  @callback snapshot(:ets.table()) :: any()

  defmacro __using__(opts) do
    refresh_every = Keyword.fetch!(opts, :refresh_every)
    refresh_flag = Keyword.fetch!(opts, :refresh_flag)

    if not is_atom(refresh_flag) do
      raise ArgumentError,
            "refresh_flag: must be a literal atom, got: #{inspect(refresh_flag)}"
    end

    quote do
      # A snapshot is written only by its owner, from snapshot/1.
      use Vutuv.EtsCache, access: :protected

      @behaviour unquote(__MODULE__)
      @before_compile unquote(__MODULE__)

      @doc "The ETS table the application-wide snapshot lives in."
      def default_table, do: __MODULE__

      @doc "Recompute the snapshot now (synchronous; used by tests)."
      def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

      @impl GenServer
      def init(opts) do
        table = open_table(Keyword.get(opts, :table, default_table()))
        interval = Keyword.get(opts, :refresh_every, unquote(refresh_every))

        # The seed is a 0ms refresh rather than an inline recompute: the scan
        # must not block the supervisor at boot. Until it lands, readers miss
        # and fall back to the direct query — exactly the pre-cache behaviour.
        if Keyword.get(opts, :refresh?, enabled?()), do: schedule(0)

        {:ok, %{table: table, interval: interval}}
      end

      @impl GenServer
      def handle_call(:refresh, _from, state) do
        snapshot(state.table)
        {:reply, :ok, state}
      end

      @impl GenServer
      def handle_info(:refresh, state) do
        snapshot(state.table)
        schedule(state.interval)
        {:noreply, state}
      end

      defp schedule(interval), do: Process.send_after(self(), :refresh, interval)

      defp enabled?, do: Application.get_env(:vutuv, unquote(refresh_flag), true)
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    # Last, so a cache may define handle_info clauses of its own in between.
    quote do
      @impl GenServer
      def handle_info(_other, state), do: {:noreply, state}
    end
  end
end
