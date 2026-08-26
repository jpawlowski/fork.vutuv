defmodule Vutuv.EtsCache do
  @moduledoc """
  The shell every ETS-backed cache in this application shares: a GenServer that
  owns one named table, and reads that answer a **miss** rather than crashing
  when the table is not there.

  `use Vutuv.EtsCache, access: :protected` generates the `start_link/1` (whose
  `name: nil` starts an unregistered instance, which is how a test runs one
  beside the application singleton) and the private `open_table/1` that the
  module's own `init/1` calls with the table it wants. The reads are the plain
  functions `fetch/2` and `lookup/2` here. What stays with each cache is what
  actually differs: its payload, its refresh policy, and what it does with a
  miss.

  ## Two questions, two options

  **`access:` is the ETS access level — who may write.** `:protected` means the
  owning GenServer writes and every process reads (what a snapshot cache wants);
  `:public` means any process writes, which is also why a public table is
  created with both concurrency hints and a protected one with only the read
  hint.

  **`created_by:` is who calls `:ets.new/2`, and it is a separate question.**
  The default `:owner` creates the table outright, so a second owner of the same
  name raises at `init/1` instead of quietly sharing a table it may not be able
  to write. `:any_process` (public tables only) is race-tolerant — an existing
  table is reused and a lost creation race counts as success — which is what
  lets `Vutuv.RateLimiter`'s readers open the table before, or without, the
  owner process. Most public caches do **not** want this: `VutuvWeb.Live.MountHandoff`
  is written only from its own module, so it keeps the duplicate-owner check.

  ## Why a miss and not a crash

  Reading a table that does not exist raises `ArgumentError`, so a cold cache
  (application boot, a test that never started the owner, a script running
  without the supervision tree) would turn into a 500 at the reader. `fetch/2`
  and `lookup/2` answer `:miss` and `[]` instead; every caller already owns the
  fallback a cold cache needs — the direct query the cache exists to spare. A
  cache that writes from outside its own process, or reads with something other
  than `:ets.lookup/2`, still rescues at that call site (see `MountHandoff`).
  """

  @doc """
  The value stored under `key` as `{:ok, value}`, or `:miss` when the row is
  absent or the table does not exist. For the `{key, value}` rows a snapshot
  cache stores; reach for `lookup/2` when the row carries more than that.
  """
  def fetch(table, key) do
    case lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @doc """
  `:ets.lookup/2`, except that a table which does not exist answers `[]` the
  same way an empty one does. For rows the caller has to read itself — an
  expiry stamp beside the value, say.
  """
  def lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  # The two openers `open_table/1` is bound to; public only because generated
  # code calls them across the module boundary. The way in is `use`, so that a
  # cache cannot quietly open its table on terms of its own.
  @doc false
  def open(name, access), do: :ets.new(name, options(access))

  @doc false
  def ensure(name, access) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, options(access))
        rescue
          # Lost the race to another process creating it, which is the point.
          ArgumentError -> name
        end

      _tid ->
        name
    end
  end

  # Only the owner writes a protected table, so there is no write concurrency
  # to buy there; a public one is written by whoever holds the caller's process.
  defp options(:protected), do: [:named_table, :protected, :set, read_concurrency: true]

  defp options(:public),
    do: [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]

  defmacro __using__(opts) do
    access = Keyword.fetch!(opts, :access)
    created_by = Keyword.get(opts, :created_by, :owner)

    if access not in [:public, :protected] do
      raise ArgumentError, "access: must be :public or :protected, got: #{inspect(access)}"
    end

    if created_by not in [:owner, :any_process] do
      raise ArgumentError,
            "created_by: must be :owner or :any_process, got: #{inspect(created_by)}"
    end

    if created_by == :any_process and access == :protected do
      raise ArgumentError,
            "created_by: :any_process needs access: :public — a process that may not " <>
              "write the table has no business creating it"
    end

    opener = if created_by == :any_process, do: :ensure, else: :open

    quote do
      use GenServer

      @doc """
      Starts the cache. `name: nil` starts it unregistered, which is half of how
      a test runs an isolated instance beside the application singleton — the
      other half is a `table:` of its own, and only a cache whose `init/1` reads
      that option has one. Every other option is passed on to `init/1`.
      """
      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        gen_opts = if name, do: [name: name], else: []
        GenServer.start_link(__MODULE__, opts, gen_opts)
      end

      # Opens the cache's table and returns it: the module's own name, unless
      # `init/1` was handed another one (an isolated test instance).
      defp open_table(name \\ __MODULE__) do
        unquote(__MODULE__).unquote(opener)(name, unquote(access))
      end
    end
  end
end
