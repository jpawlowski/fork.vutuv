defmodule Vutuv.Uploads.AvatarCache do
  @moduledoc """
  The table behind `Vutuv.Avatar.binary/2`'s memo.

  It caches the base64 avatar that goes **inside** a document — the vCard
  `PHOTO` line CardDAV renders per card, and the same picture in a CV.

  `Vutuv.Avatar.binary/2` does not read a derived file: it opens the *original*
  and runs the whole libvips pipeline (pixel-budget check, EXIF autorotate,
  crop, thumbnail, JPEG encode) before base64-ing the result. That is the right
  thing to do once and the wrong thing to do per card per request — a member
  with three hundred contacts whose phone asks for the whole book pays three
  hundred image pipelines, and pays them again on the next sync that touches
  the cards, forever.

  **The key is exact, not a guess at freshness.** `users.avatar_fingerprint` is
  already the sha256 of the original (it is what the CardDAV ETag hashes as its
  photo proxy), so a member who changes their picture changes the key and the
  old entry is simply never asked for again. The moderation state rides in the
  key too: a picture waiting for the AI scan renders as the placeholder without
  the fingerprint changing, so a key without it would keep serving the
  placeholder after the scan passed.

  There is deliberately **no TTL**. A time-based entry can only ever be stale
  or wastefully cold; a content-addressed one is neither. What bounds the table
  is the entry count: past `max_entries/0` it is emptied and refills, which is
  a cliff rather than an eviction policy, and that is the honest trade for a
  cache whose miss costs one image pipeline and never a wrong answer.

  Like `Vutuv.Social.PopularUsers`, a missing table is a **miss**, not a crash:
  before the supervisor has started this (boot, an isolated test) every call
  derives exactly as it did before the cache existed.

  The bound is entry count rather than bytes: a 192px q62 JPEG base64'd runs to
  roughly 8-16 KB, so the ceiling is on the order of 16 MB of refcounted binary.
  """

  use GenServer

  @table __MODULE__
  @max_entries 1_000

  @doc "The remembered URI for `key`, or `:miss`."
  def lookup(key, table \\ @table) do
    case :ets.lookup(table, key) do
      [{^key, uri}] -> {:ok, uri}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Remember `uri` under `key`, emptying the table first if it is full."
  def put(key, uri, table \\ @table) do
    if :ets.info(table, :size) >= @max_entries, do: :ets.delete_all_objects(table)
    :ets.insert(table, {key, uri})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drop every entry — the size cliff, and tests."
  def reset(table \\ @table) do
    :ets.delete_all_objects(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    # Public: every request process writes its own misses. Single-flight would
    # buy nothing here — a duplicated miss costs exactly what every call cost
    # before this module existed, and never a wrong answer.
    table =
      :ets.new(Keyword.get(opts, :table, @table), [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # No callbacks: this process exists only to own the table.
    {:ok, table}
  end
end
