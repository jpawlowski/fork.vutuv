defmodule Vutuv.Posts.ScreenshotsTest do
  @moduledoc """
  The post link-screenshot subsystem: detection (a single URL, no image),
  enqueue/refresh/cancel reconciliation, the durable queue's state transitions
  and backoff, and the stuck-job re-queue. The real headless-Chromium capture is
  stubbed via the `capture:` seam so these run without launching a browser.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots

  defp user, do: insert(:activated_user)

  # A URL on *this* installation's own host (derived from the endpoint, not a
  # literal vutuv.de), used to test the own-host /settings|/admin|/system skip.
  defp own_url(path), do: "https://#{VutuvWeb.Endpoint.host()}#{path}"

  defp url_post(author, body \\ "Look at this: https://example.com/page"),
    do: create_post!(author, %{body: body})

  # A capture stub that "succeeds" with a fixed stored filename + size.
  defp ok_capture,
    do: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end

  # Route the HTTP-200 probe's Req request at a stub: a bare status, or a full
  # `plug: fn conn -> conn end` responder. Paired with the describe's on_exit.
  defp stub_probe(status) when is_integer(status),
    do: stub_probe(fn conn -> Plug.Conn.send_resp(conn, status, "") end)

  defp stub_probe(fun) when is_function(fun),
    do: Application.put_env(:vutuv, :post_screenshot_req_options, plug: fun)

  # Turn the link summariser on and answer both of its halves — the page and
  # the model — so the wiring can be asserted without a network or an Ollama.
  # Paired with the describe's on_exit.
  defp stub_summary(sentence) do
    Application.put_env(:vutuv, :summarize_links, true)

    Application.put_env(:vutuv, :link_summary_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          "<html><body><p>#{String.duplicate("Seitentext. ", 30)}</p></body></html>"
        )
      end
    )

    Application.put_env(:vutuv, :link_summary_ollama_req_options,
      plug: fn conn ->
        answer = %{"message" => %{"content" => Jason.encode!(%{summary: sentence})}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(answer))
      end
    )
  end

  # A post whose auto-screenshot has already been captured, stored and released
  # by the AI scan — the state the author sees on the card and wants gone.
  defp ready_post(author) do
    post = url_post(author)
    {:ok, job} = Screenshots.reconcile(post)

    {:ok, ready} =
      job
      |> Ecto.Changeset.change(
        status: "ready",
        screenshot: "0123456789ab.avif",
        moderation: "approved"
      )
      |> Repo.update()

    {post, ready}
  end

  describe "extract_urls/1 + chosen_url/2 (detection)" do
    test "one bare http(s) URL, surrounding text allowed" do
      assert Screenshots.extract_urls("see https://example.com now") == ["https://example.com"]
    end

    test "trailing sentence punctuation is trimmed off the URL" do
      assert Screenshots.extract_urls("Read (https://example.com/a).") ==
               ["https://example.com/a"]
    end

    test "the same URL twice counts as one" do
      assert Screenshots.extract_urls("https://a.test and https://a.test") == ["https://a.test"]
    end

    test "qualifies: no image + exactly one URL" do
      assert Screenshots.chosen_url(%Posts.Post{images: [], body: "https://a.test"}) ==
               {:ok, "https://a.test"}
    end

    test "does not qualify: an image is attached" do
      post = %Posts.Post{images: [%PostImage{}], body: "https://a.test"}
      assert Screenshots.chosen_url(post) == :none
    end

    test "does not qualify: no URL at all" do
      assert Screenshots.chosen_url(%Posts.Post{images: [], body: "no link here"}) == :none
      assert Screenshots.candidate_urls(%Posts.Post{images: [], body: "no link here"}) == []
    end

    test "two URLs: the first is the default, both are offered (issue #1714)" do
      post = %Posts.Post{images: [], body: "https://a.test and https://b.test"}

      # This used to be `:none` — a post with two links silently got no
      # preview. Now the first one is previewed and the author can switch.
      assert Screenshots.chosen_url(post) == {:ok, "https://a.test"}
      assert Screenshots.candidate_urls(post) == ["https://a.test", "https://b.test"]
    end

    test "a blocklisted or own-internal link is not offered as a candidate" do
      post = %Posts.Post{
        images: [],
        body: "#{own_url("/settings")} and https://a.test and https://reddit.com/r/x"
      }

      assert Screenshots.candidate_urls(post) == ["https://a.test"]
      assert Screenshots.chosen_url(post) == {:ok, "https://a.test"}
    end

    test "does not qualify: this installation's own /settings, /admin or /system page" do
      for path <-
            ~w(/settings /settings/privacy /admin /admin/screenshots /system /system/members) do
        body = own_url(path)

        assert Screenshots.chosen_url(%Posts.Post{images: [], body: body}) == :none,
               "expected #{body} to be excluded from screenshotting"
      end
    end

    test "still qualifies: another site's /admin (only the own host is excluded)" do
      assert Screenshots.chosen_url(%Posts.Post{
               images: [],
               body: "https://example.com/admin"
             }) == {:ok, "https://example.com/admin"}
    end

    test "still qualifies: the own host on an ordinary path" do
      url = own_url("/some-profile")
      assert Screenshots.chosen_url(%Posts.Post{images: [], body: url}) == {:ok, url}
    end

    test "does not qualify: a screenshot-blocklisted host (reddit.com + subdomains)" do
      # The seeded blocklist ships reddit.com (Vutuv.ScreenshotBlocklist); a
      # single-URL post pointing at it must not enqueue a job — the capture would
      # only ever be reddit's login/consent wall.
      for url <- ~w(
            https://reddit.com/r/elixir
            https://www.reddit.com/r/elixir/comments/abc
            https://old.reddit.com/r/programming
          ) do
        assert Screenshots.chosen_url(%Posts.Post{images: [], body: url}) == :none,
               "expected #{url} to be excluded from screenshotting"
      end
    end

    test "the blocklist is admin-editable data, and an added entry takes effect at once" do
      assert Screenshots.chosen_url(%Posts.Post{
               images: [],
               body: "https://example.com/page"
             }) == {:ok, "https://example.com/page"}

      {:ok, _entry} = Vutuv.ScreenshotBlocklist.create_entry(%{"pattern" => "example.com"})

      assert Screenshots.chosen_url(%Posts.Post{
               images: [],
               body: "https://example.com/page"
             }) == :none
    end
  end

  describe "ensure_http_ok/1 (HTTP-200 probe)" do
    setup do
      on_exit(fn -> Application.delete_env(:vutuv, :post_screenshot_req_options) end)
    end

    test "a plain 200 page is allowed through to capture" do
      stub_probe(200)
      assert Screenshots.ensure_http_ok("https://example.com/page") == :ok
    end

    test "a link that HTTP-redirects (3xx) is refused permanently" do
      stub_probe(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/login")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert Screenshots.ensure_http_ok("https://example.com/page") == {:error, :redirect}
    end

    test "a 404 (any 4xx) is refused permanently" do
      stub_probe(404)

      assert Screenshots.ensure_http_ok("https://example.com/gone") ==
               {:error, {:bad_status, 404}}
    end

    test "a 5xx server error is refused but transient (may recover on retry)" do
      stub_probe(503)

      assert Screenshots.ensure_http_ok("https://example.com/down") ==
               {:error, {:server_error, 503}}
    end
  end

  describe "reconcile/1" do
    test "enqueues a pending job for a single-URL, image-less post" do
      post = url_post(user())
      assert {:ok, %PostScreenshot{}} = Screenshots.reconcile(post)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://example.com/page"
    end

    test "is idempotent: the same URL leaves the job untouched" do
      post = url_post(user())
      {:ok, first} = Screenshots.reconcile(post)
      {:ok, again} = Screenshots.reconcile(post)

      assert first.id == again.id
      assert Repo.aggregate(PostScreenshot, :count) == 1
    end

    test "a changed URL resets the job to pending with the new URL" do
      author = user()
      post = url_post(author, "https://old.test")
      {:ok, job} = Screenshots.reconcile(post)

      # Mark it captured, then change the post's single URL.
      Repo.update!(Ecto.Changeset.change(job, status: "ready", screenshot: "x.avif"))
      {:ok, updated} = Posts.update_post(post, %{body: "https://new.test"})
      Screenshots.reconcile(updated)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://new.test"
    end

    test "drops the job when the post no longer qualifies" do
      author = user()
      post = url_post(author, "https://gone.test")
      {:ok, _job} = Screenshots.reconcile(post)

      {:ok, updated} = Posts.update_post(post, %{body: "no more link"})
      Screenshots.reconcile(updated)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "dismiss/1 (author removes a bad screenshot)" do
    test "tombstones the row as dismissed and clears the stored file" do
      {_post, ready} = ready_post(user())
      assert PostScreenshot.ready?(ready)

      {:ok, dismissed} = Screenshots.dismiss(ready)

      assert dismissed.status == "dismissed"
      assert dismissed.screenshot == nil
      assert dismissed.captured_at == nil
      refute PostScreenshot.ready?(dismissed)
    end

    test "the worker never picks a dismissed job back up" do
      {_post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      assert Screenshots.list_due() == []
    end

    test "a plain re-save of the same URL leaves the dismissed tombstone in place" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      # Editing the body but keeping the single URL reconciles the job; the
      # dismissed tombstone must survive so the removed screenshot stays gone.
      {:ok, updated} =
        Posts.update_post(post, %{body: "New words, same link https://example.com/page"})

      Screenshots.reconcile(updated)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "dismissed"
    end

    test "changing the post's URL re-captures (a new page is a new screenshot)" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      {:ok, updated} = Posts.update_post(post, %{body: "https://different.test/other"})
      Screenshots.reconcile(updated)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.url == "https://different.test/other"
    end

    test "dropping the post's link removes the dismissed row and would-be files" do
      {post, ready} = ready_post(user())
      {:ok, _} = Screenshots.dismiss(ready)

      {:ok, updated} = Posts.update_post(post, %{body: "no more link at all"})
      Screenshots.reconcile(updated)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "deliver_due/1 (draining the queue)" do
    setup do
      # `stub_summary/1` flips :summarize_links, which is global application
      # env the SQL sandbox does not roll back — and the whole module is
      # already async: false for the same reason the other stubs here are.
      on_exit(fn ->
        Application.delete_env(:vutuv, :summarize_links)
        Application.delete_env(:vutuv, :link_summary_req_options)
        Application.delete_env(:vutuv, :link_summary_ollama_req_options)
      end)

      :ok
    end

    test "is a no-op when :generate_screenshots is off (rows stay pending)" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      # config/test.exs sets :generate_screenshots false.
      Screenshots.deliver_due()

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "pending"
    end

    test "a successful capture marks the job ready and broadcasts" do
      author = user()
      Vutuv.Activity.subscribe(author.id)
      post = url_post(author)
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "ready"
      assert job.screenshot == "0123456789ab.avif"
      assert job.captured_at

      assert_receive {:post_screenshot_ready, %{post_id: ready_id}}
      assert ready_id == post.id
    end

    test "writes the tooltip summary onto the row that is already ready" do
      # The row is marked `ready` first and summarised after (issue #1709), so
      # the picture never waits behind a model call — the column is filled by a
      # second write, not by the capture result.
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)
      stub_summary("Was auf der verlinkten Seite steht.")

      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "ready"
      assert job.summary == "Was auf der verlinkten Seite steht."
    end

    test "an installation that does not summarise links stores no summary" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: ok_capture())

      assert Repo.get_by!(PostScreenshot, post_id: post.id).summary == nil
    end

    test "the model is never asked about a page that published its own teaser" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)
      test_pid = self()

      stub_summary("Der Satz, den das Modell geschrieben hätte.")

      Application.put_env(:vutuv, :link_summary_req_options,
        plug: fn conn ->
          send(test_pid, :page_read_for_summary)
          Plug.Conn.send_resp(conn, 500, "")
        end
      )

      Screenshots.deliver_due(
        force: true,
        capture: fn _job ->
          {:ok,
           %{
             screenshot: "0123456789ab.avif",
             width: 400,
             height: 264,
             source: "open_graph",
             title: "Ein Titel",
             description: "Der Klappentext des Verlegers.",
             site_name: "Example Times"
           }}
        end
      )

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.description == "Der Klappentext des Verlegers."
      assert job.summary == nil
      # Not merely "no summary was stored": the page was never even fetched, so
      # this is a skipped model call rather than a failed one.
      refute_received :page_read_for_summary
    end

    test "a captured page that carries words is the same card an og:image page gets" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      # What `page_capture_and_store/2` now returns for a page whose `<title>`
      # was readable but which declared no og:image: our own picture, the
      # page's own headline.
      Screenshots.deliver_due(
        force: true,
        capture: fn _job ->
          {:ok,
           %{
             screenshot: "0123456789ab.avif",
             width: 400,
             height: 264,
             source: "screenshot",
             title: "Eine ganz gewöhnliche Seite",
             description: nil,
             site_name: "example.com"
           }}
        end
      )

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.source == "screenshot"
      assert job.title == "Eine ganz gewöhnliche Seite"
      assert job.site_name == "example.com"
      assert PostScreenshot.card?(job)
    end

    test "a transient failure keeps the job pending with backoff" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :timeout} end)

      job = Repo.get_by!(PostScreenshot, post_id: post.id)
      assert job.status == "pending"
      assert job.attempts == 1
      assert job.next_attempt_at
      assert job.last_error =~ "timeout"
    end

    test "an internal-target (SSRF) refusal fails permanently at once" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :internal_target} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end

    test "a blocklisted refusal fails permanently (a stale row is never retried)" do
      # `qualify/1` keeps a blocklisted URL from ever enqueuing, but a row queued
      # before the page was blocklisted could still reach capture — it must die
      # at once, not burn five retries on a shot that can't work.
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :blocklisted} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end

    test "a non-200 link (redirect, 404) fails permanently at once (no retry)" do
      for reason <- [:redirect, {:bad_status, 404}] do
        post = url_post(user())
        {:ok, _job} = Screenshots.reconcile(post)

        Screenshots.deliver_due(force: true, capture: fn _ -> {:error, reason} end)

        job = Repo.get_by!(PostScreenshot, post_id: post.id)
        assert job.status == "failed", "expected #{inspect(reason)} to fail permanently"
        assert job.attempts == 1
      end
    end

    test "a 5xx / unreachable link stays pending with backoff (transient)" do
      for reason <- [{:server_error, 503}, :probe_failed] do
        post = url_post(user())
        {:ok, _job} = Screenshots.reconcile(post)

        Screenshots.deliver_due(force: true, capture: fn _ -> {:error, reason} end)

        job = Repo.get_by!(PostScreenshot, post_id: post.id)
        assert job.status == "pending", "expected #{inspect(reason)} to be retried"
        assert job.attempts == 1
        assert job.next_attempt_at
      end
    end

    test "a transient failure at the attempt cap becomes failed" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      # One try below the cap, and due for retry now.
      Repo.update!(
        Ecto.Changeset.change(job,
          attempts: Screenshots.max_attempts() - 1,
          next_attempt_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
        )
      )

      Screenshots.deliver_due(force: true, capture: fn _ -> {:error, :timeout} end)

      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "failed"
    end
  end

  describe "requeue/1 (an admin hands a dead job back)" do
    test "a failed job returns to pending with a clean slate and is due at once" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      failed =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "failed",
            attempts: Screenshots.max_attempts(),
            last_error: ":timeout",
            next_attempt_at: DateTime.utc_now(:second)
          )
        )

      assert {:ok, requeued} = Screenshots.requeue(failed)
      assert requeued.status == "pending"
      assert requeued.attempts == 0
      refute requeued.last_error
      refute requeued.next_attempt_at

      # Nothing else brings a `failed` row back: without this the job stays dead
      # even after the capture bug that killed it is fixed.
      assert Enum.map(Screenshots.list_due(), & &1.id) == [requeued.id]
    end

    test "an author-dismissed tombstone is never handed back" do
      {_post, ready} = ready_post(user())
      {:ok, dismissed} = Screenshots.dismiss(ready)

      assert {:error, :not_requeueable} = Screenshots.requeue(dismissed)
      assert Repo.get!(PostScreenshot, dismissed.id).status == "dismissed"
    end
  end

  describe "list_due/1" do
    test "excludes jobs whose backoff has not elapsed" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      future = DateTime.add(DateTime.utc_now(:second), 3600, :second)
      Repo.update!(Ecto.Changeset.change(job, next_attempt_at: future))

      assert Screenshots.list_due() == []
    end
  end

  describe "resume_stuck/0" do
    test "re-queues a capturing job a crash orphaned, leaving fresh ones" do
      stuck = url_post(user())
      {:ok, stuck_job} = Screenshots.reconcile(stuck)

      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

      Repo.update_all(
        from(ps in PostScreenshot, where: ps.id == ^stuck_job.id),
        set: [status: "capturing", updated_at: old]
      )

      fresh = url_post(user())
      {:ok, fresh_job} = Screenshots.reconcile(fresh)
      Repo.update!(Ecto.Changeset.change(fresh_job, status: "capturing"))

      assert Screenshots.resume_stuck() == 1
      assert Repo.get!(PostScreenshot, stuck_job.id).status == "pending"
      assert Repo.get!(PostScreenshot, fresh_job.id).status == "capturing"
    end
  end

  describe "create_post/2 integration" do
    setup do
      previous = Application.get_env(:vutuv, :generate_screenshots)
      Application.put_env(:vutuv, :generate_screenshots, true)
      on_exit(fn -> Application.put_env(:vutuv, :generate_screenshots, previous) end)
    end

    test "a qualifying new post enqueues a pending job" do
      post = create_post!(user(), %{body: "https://enqueued.test"})
      assert Repo.get_by!(PostScreenshot, post_id: post.id).status == "pending"
    end

    test "an image-less post with no URL enqueues nothing" do
      post = create_post!(user(), %{body: "just some words"})
      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "cleanup" do
    test "deleting a post removes its screenshot row" do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)

      {:ok, _} = Posts.delete_post(post)

      refute Repo.get_by(PostScreenshot, post_id: post.id)
    end
  end

  describe "deliver_due/1 with a YouTube link (thumbnail instead of Chromium)" do
    # These run the REAL capture path (no capture: stub): the YouTube fetch is
    # stubbed via :youtube_thumbnail_req_options, the page probe via
    # :post_screenshot_req_options, and stored files land in a tmp uploads dir.
    setup do
      tmp = Path.join(System.tmp_dir!(), "vutuv_yt_shots_#{System.unique_integer([:positive])}")
      previous = Application.get_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

      on_exit(fn ->
        File.rm_rf(tmp)

        if previous,
          do: Application.put_env(:vutuv, :uploads_dir_prefix, previous),
          else: Application.delete_env(:vutuv, :uploads_dir_prefix)

        Application.delete_env(:vutuv, :youtube_thumbnail_req_options)
        Application.delete_env(:vutuv, :post_screenshot_req_options)
      end)

      # A real (tiny) JPEG: the store path opens it with libvips.
      fixture = Path.join(tmp, "fixture.jpg")
      File.mkdir_p!(tmp)
      {:ok, img} = Image.new(64, 36, color: [200, 30, 30])
      {:ok, _} = Image.write(img, fixture)
      jpeg_bytes = File.read!(fixture)

      {:ok, tmp: tmp, jpeg: jpeg_bytes}
    end

    defp stub_youtube(fun) when is_function(fun),
      do: Application.put_env(:vutuv, :youtube_thumbnail_req_options, plug: fun)

    defp youtube_post(author),
      do: create_post!(author, %{body: "https://www.youtube.com/watch?v=EZ05e7EMOLM"})

    test "stores the video's thumbnail raw — no page probe, no Chromium", %{
      tmp: tmp,
      jpeg: jpeg
    } do
      post = youtube_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      test_pid = self()
      maxres = "/vi/EZ05e7EMOLM/maxresdefault.jpg"

      stub_youtube(fn conn ->
        cond do
          conn.request_path == "/oembed" ->
            send(test_pid, :oembed_checked)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"title":"stub"}))

          conn.request_path == maxres ->
            conn
            |> Plug.Conn.put_resp_content_type("image/jpeg", nil)
            |> Plug.Conn.send_resp(200, jpeg)
        end
      end)

      # If the classic path ran anyway, this probe answer would mark the job
      # for retry (attempts 1), never ready — so "ready with 0 attempts"
      # proves the page was neither probed nor captured.
      stub_probe(500)

      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "ready"
      assert job.attempts == 0
      # The classic path stores .webp (framed capture); the thumbnail is .jpg.
      assert String.ends_with?(job.screenshot, ".jpg")
      assert_received :oembed_checked

      thumb_name = "thumb-#{Path.rootname(job.screenshot)}.avif"
      assert File.exists?(Path.join([tmp, "screenshots", job.id, thumb_name]))
    end

    test "falls back to the page capture when YouTube doesn't know the video" do
      post = youtube_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_youtube(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(404, "Not Found")
      end)

      # The fallback probes the page; a 301 is a permanent refusal, so hitting
      # exactly that state proves the classic path took over.
      stub_probe(301)

      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "failed"
      assert job.last_error == ":redirect"
    end

    test "a non-YouTube link never calls the YouTube seam" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      test_pid = self()

      stub_youtube(fn conn ->
        send(test_pid, :youtube_called)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      stub_probe(301)

      Screenshots.deliver_due(force: true)

      assert Screenshots.get_job!(job.id).status == "failed"
      refute_received :youtube_called
    end
  end

  describe "deliver_due/1 with a page that publishes its own preview (issue #1706)" do
    # The REAL capture path, like the YouTube block above: the Open Graph fetch
    # is stubbed through :open_graph_req_options, the page probe through
    # :post_screenshot_req_options, and stored files land in a tmp uploads dir.
    setup do
      tmp = Path.join(System.tmp_dir!(), "vutuv_og_shots_#{System.unique_integer([:positive])}")
      previous_prefix = Application.fetch_env(:vutuv, :uploads_dir_prefix)
      previous_flag = Application.fetch_env(:vutuv, :fetch_open_graph)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
      # Off in config/test.exs so nothing else can dial out; on here.
      Application.put_env(:vutuv, :fetch_open_graph, true)

      on_exit(fn ->
        File.rm_rf(tmp)
        restore(:uploads_dir_prefix, previous_prefix)
        restore(:fetch_open_graph, previous_flag)
        Application.delete_env(:vutuv, :open_graph_req_options)
        Application.delete_env(:vutuv, :post_screenshot_req_options)
      end)

      # A real (tiny) PNG: the store path opens it with libvips.
      fixture = Path.join(tmp, "fixture.png")
      File.mkdir_p!(tmp)
      {:ok, img} = Image.new(64, 36, color: [10, 90, 200])
      {:ok, _written} = Image.write(img, fixture)

      {:ok, tmp: tmp, png: File.read!(fixture)}
    end

    defp restore(key, {:ok, was}), do: Application.put_env(:vutuv, key, was)
    defp restore(key, :error), do: Application.delete_env(:vutuv, key)

    defp stub_open_graph(fun) when is_function(fun),
      do: Application.put_env(:vutuv, :open_graph_req_options, plug: fun)

    # A page answering the full Open Graph set, and its image.
    defp stub_og_page(png, head) do
      stub_open_graph(fn conn ->
        case conn.request_path do
          "/page" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html", nil)
            |> Plug.Conn.send_resp(200, "<html><head>#{head}</head><body></body></html>")

          "/card.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png", nil)
            |> Plug.Conn.send_resp(200, png)
        end
      end)
    end

    @og_head """
    <meta property="og:title" content="Ein Titel von der Seite selbst">
    <meta property="og:description" content="Der Teaser, den die Seite anbietet.">
    <meta property="og:site_name" content="Example Times">
    <meta property="og:image" content="https://example.com/card.png">
    """

    test "stores the page's own card — its words and its image, no Chromium", %{
      tmp: tmp,
      png: png
    } do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_og_page(png, @og_head)
      # If the classic path ran anyway this probe answer would mark the job for
      # retry, never ready — so "ready with 0 attempts" proves the page was
      # neither probed nor captured.
      stub_probe(500)

      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "ready"
      assert job.attempts == 0
      assert job.source == "open_graph"
      assert job.title == "Ein Titel von der Seite selbst"
      assert job.description == "Der Teaser, den die Seite anbietet."
      assert job.site_name == "Example Times"
      # The classic path stores .webp (framed capture); a supplied image keeps
      # its own format.
      assert String.ends_with?(job.screenshot, ".png")
      assert PostScreenshot.card?(job)

      thumb_name = "thumb-#{Path.rootname(job.screenshot)}.avif"
      assert File.exists?(Path.join([tmp, "screenshots", job.id, thumb_name]))
    end

    test "a page that names no site falls back to its host", %{png: png} do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_og_page(png, """
      <meta property="og:title" content="Ein Titel">
      <meta property="og:image" content="https://example.com/card.png">
      """)

      stub_probe(500)
      Screenshots.deliver_due(force: true)

      assert Screenshots.get_job!(job.id).site_name == "example.com"
    end

    test "a page with no Open Graph tags takes the capture path exactly as before" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_open_graph(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html", nil)
        |> Plug.Conn.send_resp(200, "<html><head><title>plain</title></head><body></body></html>")
      end)

      # A 301 is a permanent refusal, so hitting exactly that state proves the
      # classic path took over.
      stub_probe(301)
      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "failed"
      assert job.last_error == ":redirect"
      assert job.source == "screenshot"
      refute PostScreenshot.card?(job)
    end

    test "the flag off means the linked page is never asked" do
      Application.put_env(:vutuv, :fetch_open_graph, false)
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      test_pid = self()

      stub_open_graph(fn conn ->
        send(test_pid, :open_graph_fetched)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      stub_probe(301)
      Screenshots.deliver_due(force: true)

      assert Screenshots.get_job!(job.id).status == "failed"
      refute_received :open_graph_fetched
    end

    test "an og:image the uploader cannot store falls back to the capture", %{png: _png} do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      stub_open_graph(fn conn ->
        case conn.request_path do
          "/page" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html", nil)
            |> Plug.Conn.send_resp(200, "<html><head>#{@og_head}</head></html>")

          "/card.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/avif", nil)
            |> Plug.Conn.send_resp(200, "AVIFBYTES")
        end
      end)

      stub_probe(301)
      Screenshots.deliver_due(force: true)

      job = Screenshots.get_job!(job.id)
      assert job.status == "failed"
      assert job.source == "screenshot"
      assert job.title == nil
    end

    test "a re-capture as a plain screenshot cannot keep the old headline", %{png: png} do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)
      stub_og_page(png, @og_head)
      stub_probe(500)
      Screenshots.deliver_due(force: true)
      assert Screenshots.get_job!(job.id).source == "open_graph"

      # The AI scan rejects the page's image, which is what
      # `Vutuv.Moderation.ImageSubjects.apply_rejected/1` leaves behind: the
      # file gone, the row `failed` — and the headline still on it, because
      # that path knows nothing about the card columns.
      {:ok, _rejected} =
        Screenshots.get_job!(job.id)
        |> Ecto.Changeset.change(status: "failed", screenshot: nil)
        |> Repo.update()

      # An admin hands the dead job back and this time the capture path
      # answers. The row must stop being a card: a Chromium photograph under
      # the previous page's headline is the one output worse than either kind
      # alone.
      {:ok, _requeued} = Screenshots.requeue(Screenshots.get_job!(job.id))
      Screenshots.deliver_due(force: true, capture: ok_capture())

      job = Screenshots.get_job!(job.id)
      assert job.status == "ready"
      assert job.source == "screenshot"
      assert job.title == nil
      assert job.description == nil
      assert job.site_name == nil
      refute PostScreenshot.card?(job)
    end

    test "editing the post's link clears the old page's card", %{png: png} do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)
      stub_og_page(png, @og_head)
      stub_probe(500)
      Screenshots.deliver_due(force: true)

      # `Posts.update_post/2` reconciles behind the `:generate_screenshots`
      # flag, which the test config keeps off, so the reconcile is called here
      # the way the other reconcile tests in this file do.
      {:ok, updated} =
        Posts.update_post(Repo.preload(post, [:images, :tags]), %{
          body: "Now this one: https://example.com/other"
        })

      {:ok, job} = Screenshots.reconcile(updated)
      assert job.status == "pending"
      assert job.source == "screenshot"
      assert job.title == nil
      assert job.description == nil
      assert job.site_name == nil
    end

    test "editing the link clears the summary too, not only the card's words" do
      post = url_post(user())
      {:ok, job} = Screenshots.reconcile(post)

      # The state the summariser leaves behind: a sentence about the OLD page.
      # It renders inside the card now (`PostScreenshot.teaser/1`) rather than
      # in a hover tooltip, so leaving it on the row would put one page's
      # description under the next page's headline.
      {:ok, _summarised} =
        job
        |> Ecto.Changeset.change(status: "ready", summary: "Über die alte Seite.")
        |> Repo.update()

      {:ok, updated} =
        Posts.update_post(Repo.preload(post, [:images, :tags]), %{
          body: "Now this one: https://example.com/other"
        })

      {:ok, job} = Screenshots.reconcile(updated)
      assert job.summary == nil
    end

    test "the author's removal takes the card's words with it", %{png: png} do
      post = url_post(user())
      {:ok, _job} = Screenshots.reconcile(post)
      stub_og_page(png, @og_head)
      stub_probe(500)
      Screenshots.deliver_due(force: true)

      # Freshly loaded: `dismiss_screenshot/1` preloads without `force`, so a
      # struct carrying the nil `:screenshot` it was created with would be a
      # no-op here (the composer/edit page always hands it a fresh one).
      {:ok, post} = Posts.dismiss_screenshot(Repo.get!(Posts.Post, post.id))

      assert post.screenshot.status == "dismissed"
      assert post.screenshot.title == nil
      assert post.screenshot.source == "screenshot"
      refute PostScreenshot.card?(post.screenshot)
    end
  end

  describe "requeue_youtube/0 (backfill after the thumbnail capture shipped)" do
    defp youtube_job(author, video_id, status) do
      post = create_post!(author, %{body: "https://youtu.be/#{video_id}"})
      {:ok, job} = Screenshots.reconcile(post)

      Repo.update!(
        Ecto.Changeset.change(job,
          status: status,
          attempts: Screenshots.max_attempts(),
          last_error: ":timeout"
        )
      )
    end

    test "re-queues finished YouTube jobs; other URLs and dismissed rows stay" do
      author = user()

      yt_ready = youtube_job(author, "AAAAAAAAAA1", "ready")
      yt_failed = youtube_job(author, "AAAAAAAAAA2", "failed")
      yt_dismissed = youtube_job(author, "AAAAAAAAAA3", "dismissed")
      {_post, other_ready} = ready_post(author)

      assert Screenshots.requeue_youtube() == 2

      requeued = Screenshots.get_job!(yt_ready.id)
      assert requeued.status == "pending"
      assert requeued.attempts == 0
      assert requeued.last_error == nil

      assert Screenshots.get_job!(yt_failed.id).status == "pending"
      assert Screenshots.get_job!(yt_dismissed.id).status == "dismissed"
      assert Screenshots.get_job!(other_ready.id).status == "ready"
    end
  end
end
