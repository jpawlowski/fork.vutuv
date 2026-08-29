defmodule Vutuv.Posts.SummaryQueue do
  @moduledoc """
  Decides **when** a link preview's teaser sentence gets written, and nothing
  else. The work itself is `Vutuv.Posts.Screenshots.write_link_summary/3`,
  which owns the row; this process owns the ordering.

  ## Why it is not on the capture worker (issue #1742)

  `Vutuv.Posts.ScreenshotWorker` drains one job at a time, five per poll, and
  the model gets 30 seconds for one sentence. Running the call inside the
  capture therefore spent up to two and a half minutes of a single drain on
  teasers — the worker blocked throughout, so every member who had just typed a
  link sat on the composer's placeholder while somebody else's *teaser* was
  being written. Doing it after `mark_ready/2` protected that one job's picture
  and nothing behind it.

  Nobody is waiting for this sentence: the card is already on the page with its
  picture and its headline. So it belongs off the path where somebody *is*
  waiting — and behind everything else that talks to the same model.

  ## Rank: last, and it yields

  Two mechanisms, and they do different jobs.

  **One at a time**, because this installation has one Ollama by default
  (`Vutuv.Ollama.concurrency/0` holds the last endpoint in reserve rather than
  working it), and handing it a drain's five captures at once makes five
  requests that each take five times as long.

  **Behind the image scans**, because serialising your own calls only stops you
  being five callers instead of one — it never puts you *behind* anybody. A
  member whose avatar is in moderation limbo sees nothing at all until the
  verdict lands, so `Vutuv.Moderation.ImageScans.busy?/0` stands this queue
  down entirely while any scan is open, exactly as
  `Vutuv.Translations.Worker` stands its background sweep down. Fail-open: if
  that check itself breaks, teasers keep being written, because a teaser
  running at an awkward moment is a far smaller problem than a queue that
  stops.

  ## What it holds, and what it drops

  A job is `{id, url, text}` — the row's id, the page's URL, and the prose the
  capture already reduced the page to (`LinkSummary.page_text/1`), measured at
  ~12 KB and provably free of any reference to the 512 KB document it came
  from. A capture with no page body queues no job at all; that decision belongs
  to `Screenshots.queue_summary/2`, which knows why the body is missing.

  The list is **in memory and bounded** at `max_queued/0`, and both halves are
  deliberate.

  Bounded, because captures arrive faster than sentences are written (five per
  15 s poll against at most two a minute), so an unbounded queue would grow
  without limit. At the cap the **oldest** job is dropped, not the newest: the
  arithmetic says a busy installation sits at the cap permanently, and refusing
  new work there would spend the one Ollama entirely on links nobody has looked
  at since lunch while the card a member is watching right now never gets a
  teaser. Same model spend either way — this is only about aim. (The cap counts
  the list, not the mailbox: casts that arrive during a 30 s call queue up
  behind it, bounded in practice by the capture worker's own drain rate.)

  **What a dropped job costs, exactly.** Nothing is lost that a reader would
  have seen: the preview is already stored and announced, `summary` simply
  stays `nil`, and `PostScreenshot.teaser/1` then renders the card with its
  picture and headline and no second line — the same card an installation with
  `:summarize_links` off shows every time. The drop is **logged** (`Logger.info`
  naming the URL), not silent, so an operator watching a busy instance can see
  the cap biting.

  It is never a page's own `og:description` that goes missing, because such a
  page is never queued in the first place: `Screenshots.summarize/2` skips the
  model entirely when the page published a description, and `teaser/1` prefers
  that column anyway. The two can therefore never race — the publisher's blurb
  wins where it exists, and this queue only ever fills a line that would
  otherwise be empty.

  In memory, because this is best-effort by construction — `Vutuv.LinkSummary`
  makes one attempt and nothing retries it — so a restart losing the queue
  costs exactly what a failed model call already costs: a card that shows its
  headline and picture and no second line. A durable queue would also have
  nothing to work from: `Screenshots.carry_html/2` deliberately keeps the page
  body off the row, so a sweeper picking the job up later would have to
  download every page a second time, which is the regression this branch
  removed. The row is one column away from making it durable if that ever
  changes — the payload is already the shape of one.

  Gated by the `:link_summary_queue` config flag (off in tests, where
  `enqueue/3` casts into the void and the per-job work is called directly); the
  model call is additionally gated by `:summarize_links`.
  """

  use GenServer

  require Logger

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts.Screenshots

  # Roughly ten minutes of work at the model's 30 s ceiling. Deep enough to
  # absorb a burst of link posts, shallow enough that nothing in it is stale
  # beyond use by the time it runs.
  @max_queued 20

  # How long to stand down while an image scan is open. A member is waiting for
  # that verdict and nobody is waiting for this sentence.
  @yield_for :timer.seconds(30)

  @doc "How many summaries may wait at once before the oldest is dropped."
  def max_queued, do: @max_queued

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Queue one preview's teaser. `text` is the page already reduced to prose.

  A cast, and a cast to an unstarted queue is a harmless no-op — same as
  `ScreenshotWorker.nudge/0`, and for the same reason: a release `eval` starts
  no supervision tree, and a teaser is not what such a script is for.
  """
  def enqueue(id, url, text) when is_binary(id) and is_binary(url) and is_binary(text),
    do: GenServer.cast(__MODULE__, {:summarize, {id, url, text}})

  @doc """
  Run every queued job now, ignoring the yield, and answer when the queue is
  empty.

  The synchronisation point for the queue's own tests — everything cast before
  this call has been dealt with by the time it returns, because the queue and
  its work live in this one process. Assumes a short queue: a full one would
  take `max_queued/0` model calls, so raise `timeout` if you ever flush one.
  """
  def flush(timeout \\ :timer.seconds(60)), do: GenServer.call(__MODULE__, :flush, timeout)

  @impl GenServer
  def init(_opts), do: {:ok, %{queue: []}}

  @impl GenServer
  def handle_cast({:summarize, {_id, url, _text} = job}, %{queue: queue} = state) do
    # Exactly one `:run` per accepted job, so the messages can never run out
    # before the queue does and the queue can never stall with work in it. A
    # dropped job's `:run` is harmless — it no-ops on an empty queue later.
    send(self(), :run)
    {:noreply, %{state | queue: accept(queue, job, url)}}
  end

  @impl GenServer
  def handle_call(:flush, _from, %{queue: queue} = state) do
    Enum.each(queue, &run/1)
    {:reply, :ok, %{state | queue: []}}
  end

  @impl GenServer
  def handle_info(:run, %{queue: []} = state), do: {:noreply, state}

  def handle_info(:run, %{queue: [job | rest]} = state) do
    if image_moderation_busy?() do
      # Leave the job at the head and come back. One `:run` consumed, one sent,
      # so the invariant above still holds.
      Process.send_after(self(), :run, @yield_for)
      {:noreply, state}
    else
      run(job)
      {:noreply, %{state | queue: rest}}
    end
  end

  defp accept(queue, job, url) when length(queue) >= @max_queued do
    [{_id, dropped, _text} | rest] = queue
    Logger.info("link summary queue full (#{@max_queued}), dropped #{dropped} for #{url}")
    rest ++ [job]
  end

  defp accept(queue, job, _url), do: queue ++ [job]

  # A model or DB hiccup must not take this process down and lose the rest of
  # the queue with it — `Vutuv.LinkSummary` promises never to raise, and this
  # is the belt to that pair of braces.
  defp run({id, url, text}) do
    Screenshots.write_link_summary(id, url, text)
  rescue
    error -> Logger.error("link summary failed for #{url}: #{inspect(error)}")
  end

  # Fail-open, exactly as `Vutuv.Translations.Worker` does: if the check breaks,
  # the queue keeps draining.
  defp image_moderation_busy? do
    ImageScans.busy?()
  rescue
    error ->
      Logger.error("image scan check failed: #{inspect(error)}")
      false
  end
end
