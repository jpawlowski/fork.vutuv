defmodule Vutuv.EtsCacheTest.Snapshot do
  @moduledoc false
  use Vutuv.EtsCache, access: :protected

  alias Vutuv.EtsCache

  @table __MODULE__

  def top(table \\ @table), do: EtsCache.fetch(table, :pool)

  def put(server, value), do: GenServer.call(server, {:put, value})

  @impl true
  def init(opts), do: {:ok, %{table: open_table(Keyword.get(opts, :table, @table))}}

  @impl true
  def handle_call({:put, value}, _from, state) do
    :ets.insert(state.table, {:pool, value})
    {:reply, :ok, state}
  end
end

defmodule Vutuv.EtsCacheTest.Counter do
  @moduledoc false
  use Vutuv.EtsCache, access: :public, created_by: :any_process

  @doc "The reader-side lazy create a `created_by: :any_process` cache leans on."
  def ensure(name \\ __MODULE__), do: open_table(name)

  # Nothing starts this one; the stub only satisfies the GenServer behaviour.
  @impl true
  def init(_opts), do: {:ok, %{}}
end

defmodule Vutuv.EtsCacheTest do
  use ExUnit.Case, async: true

  alias Vutuv.EtsCache
  alias Vutuv.EtsCacheTest.Counter
  alias Vutuv.EtsCacheTest.Snapshot

  defp unique_table(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  describe "reads without a table" do
    test "fetch/2 answers :miss instead of raising" do
      assert EtsCache.fetch(:vutuv_ets_cache_test_no_such_table, :pool) == :miss
    end

    test "lookup/2 answers [] instead of raising" do
      assert EtsCache.lookup(:vutuv_ets_cache_test_no_such_table, :pool) == []
    end
  end

  describe "reads with a table" do
    setup do
      table = :ets.new(unique_table("rows"), [:set])
      :ets.insert(table, {:pool, [1, 2, 3]})
      :ets.insert(table, {:stamped, :value, 42})
      %{table: table}
    end

    test "fetch/2 unwraps a {key, value} row", %{table: table} do
      assert EtsCache.fetch(table, :pool) == {:ok, [1, 2, 3]}
    end

    test "fetch/2 answers :miss for a key the table does not hold", %{table: table} do
      assert EtsCache.fetch(table, :absent) == :miss
    end

    test "lookup/2 hands a wider row back whole", %{table: table} do
      assert EtsCache.lookup(table, :stamped) == [{:stamped, :value, 42}]
    end
  end

  describe "the table an access level opens" do
    test "a public table carries both concurrency hints, a protected one only the read hint" do
      public = EtsCache.open(unique_table("hints_public"), :public)
      protected = EtsCache.open(unique_table("hints_protected"), :protected)

      assert :ets.info(public, :write_concurrency) == true
      assert :ets.info(protected, :write_concurrency) == false
      assert :ets.info(public, :protection) == :public
      assert :ets.info(protected, :protection) == :protected
    end
  end

  describe "the generated start_link/1" do
    test "registers the module's own name by default" do
      {:ok, pid} = start_supervised({Snapshot, table: unique_table("registered")})

      assert Process.whereis(Snapshot) == pid
    end

    test "`name: nil` starts an unregistered instance" do
      start_supervised!({Snapshot, name: nil, table: unique_table("isolated")})

      assert Process.whereis(Snapshot) == nil
    end

    test "the table `init/1` opens is the one it was handed" do
      table = unique_table("injected")
      pid = start_supervised!({Snapshot, name: nil, table: table})

      assert :ok = Snapshot.put(pid, [:one])
      assert Snapshot.top(table) == {:ok, [:one]}
      # The module-named table was never created, so its reader still misses.
      assert Snapshot.top() == :miss
    end
  end

  describe "created_by:" do
    test "the default owner refuses a second owner of the same table" do
      table = unique_table("owner")
      start_supervised!({Snapshot, name: nil, table: table})

      Process.flag(:trap_exit, true)
      # `:ets.new/2` refuses the taken name; Elixir spells that badarg
      # `ArgumentError` where it is rescued, but an exit reason carries it raw.
      assert {:error, {:badarg, _stack}} = Snapshot.start_link(name: nil, table: table)
    end

    test ":any_process reuses a table that is already there" do
      table = unique_table("any_process")

      assert Counter.ensure(table) == table
      assert Counter.ensure(table) == table
    end
  end

  describe "the use options are checked at compile time" do
    test "an unknown access is refused" do
      assert_raise ArgumentError, ~r/must be :public or :protected/, fn ->
        Code.eval_string("""
        defmodule Vutuv.EtsCacheTest.BadAccess do
          use Vutuv.EtsCache, access: :secret
        end
        """)
      end
    end

    test "a protected table may not be created by any process" do
      assert_raise ArgumentError, ~r/needs access: :public/, fn ->
        Code.eval_string("""
        defmodule Vutuv.EtsCacheTest.BadPolicy do
          use Vutuv.EtsCache, access: :protected, created_by: :any_process
        end
        """)
      end
    end
  end
end
