defmodule Vutuv.EtsCache.SnapshotTest.Counted do
  @moduledoc false
  use Vutuv.EtsCache.Snapshot,
    refresh_every: :timer.minutes(10),
    refresh_flag: :refresh_ets_cache_snapshot_test

  alias Vutuv.EtsCache

  @doc "How often `snapshot/1` has run against `table`, or `:miss` when never."
  def runs(table), do: EtsCache.fetch(table, :runs)

  @impl true
  def snapshot(table) do
    runs =
      case EtsCache.fetch(table, :runs) do
        {:ok, n} -> n
        :miss -> 0
      end

    :ets.insert(table, {:runs, runs + 1})
  end
end

defmodule Vutuv.EtsCache.SnapshotTest.Listening do
  @moduledoc false
  use Vutuv.EtsCache.Snapshot,
    refresh_every: :timer.minutes(10),
    refresh_flag: :refresh_ets_cache_snapshot_listening_test

  @impl true
  def snapshot(table), do: :ets.insert(table, {:runs, :snapshotted})

  # The clause the catch-all used to make impossible.
  @impl GenServer
  def handle_info(:heard_it, state) do
    :ets.insert(state.table, {:heard, true})
    {:noreply, state}
  end
end

defmodule Vutuv.EtsCache.SnapshotTest do
  use ExUnit.Case, async: true

  alias Vutuv.EtsCache.SnapshotTest.Counted
  alias Vutuv.EtsCache.SnapshotTest.Listening

  @flag :refresh_ets_cache_snapshot_test

  defp unique_table(prefix), do: :"snapshot_#{prefix}_#{System.unique_integer([:positive])}"

  # Polls until `fun` holds. The caches answer within milliseconds, so this only
  # ever spins on a real failure — and `refute eventually(…)` states "this never
  # happened" as a bounded window rather than a mailbox-ordering argument.
  defp eventually(fun, tries \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  defp with_flag(value) do
    previous = Application.fetch_env(:vutuv, @flag)
    Application.put_env(:vutuv, @flag, value)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(:vutuv, @flag, was)
        :error -> Application.delete_env(:vutuv, @flag)
      end
    end)
  end

  describe "the boot seed" do
    test "fires once at 0ms, so a reader is warm without waiting for the interval" do
      table = unique_table("seeded")
      start_supervised!({Counted, name: nil, table: table, refresh?: true})

      assert eventually(fn -> Counted.runs(table) == {:ok, 1} end)
    end

    test "`refresh?: false` starts cold, which is what every test wants" do
      table = unique_table("cold")
      start_supervised!({Counted, name: nil, table: table, refresh?: false})

      refute eventually(fn -> Counted.runs(table) != :miss end, 50)
    end

    test "the refresh_flag turns it off without touching the call site" do
      with_flag(false)
      table = unique_table("flagged_off")
      start_supervised!({Counted, name: nil, table: table})

      refute eventually(fn -> Counted.runs(table) != :miss end, 50)
    end

    test "an explicit `refresh?:` beats the flag" do
      with_flag(false)
      table = unique_table("opt_wins")
      start_supervised!({Counted, name: nil, table: table, refresh?: true})

      assert eventually(fn -> Counted.runs(table) == {:ok, 1} end)
    end
  end

  describe "refresh/1" do
    test "recomputes synchronously, so a test needs no sleep" do
      table = unique_table("manual")
      pid = start_supervised!({Counted, name: nil, table: table, refresh?: false})

      assert :ok = Counted.refresh(pid)
      assert Counted.runs(table) == {:ok, 1}
      assert :ok = Counted.refresh(pid)
      assert Counted.runs(table) == {:ok, 2}
    end
  end

  describe "the scheduled refresh" do
    test "schedules the next one, so the cache keeps ticking" do
      table = unique_table("ticking")

      start_supervised!({Counted, name: nil, table: table, refresh?: true, refresh_every: 5})

      assert eventually(fn ->
               match?({:ok, n} when n >= 3, Counted.runs(table))
             end)
    end
  end

  describe "the catch-all" do
    test "a stray message neither crashes the cache nor refreshes it" do
      table = unique_table("stray")
      pid = start_supervised!({Counted, name: nil, table: table, refresh?: false})

      send(pid, :something_else)
      send(pid, {:tagged, :tuple})

      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
      assert Counted.runs(table) == :miss
    end
  end

  describe "a cache may add handle_info clauses of its own" do
    test "its clause runs, and unknown messages still fall through the catch-all" do
      table = unique_table("listening")
      pid = start_supervised!({Listening, name: nil, table: table, refresh?: false})

      send(pid, :heard_it)
      send(pid, :never_heard_of_it)
      _ = :sys.get_state(pid)

      assert Process.alive?(pid)
      assert Vutuv.EtsCache.fetch(table, :heard) == {:ok, true}
    end
  end

  describe "default_table/0" do
    test "is the module's own name" do
      assert Counted.default_table() == Counted
    end
  end

  describe "the use options are checked at compile time" do
    test "a refresh_flag that is not an atom is refused" do
      assert_raise ArgumentError, ~r/refresh_flag: must be a literal atom/, fn ->
        Code.eval_string("""
        defmodule Vutuv.EtsCache.SnapshotTest.BadFlag do
          use Vutuv.EtsCache.Snapshot,
            refresh_every: 1_000,
            refresh_flag: "refresh_me"

          @impl true
          def snapshot(_table), do: :ok
        end
        """)
      end
    end
  end
end
