defmodule Vutuv.Posts.SummaryQueueTest do
  @moduledoc """
  The teaser sentence a link preview gets written off the capture worker
  (issue #1742) — both halves of that move.

  The **job** is `Screenshots.write_link_summary/3` and is driven directly,
  with no queue running: what it writes, who it tells, and what it refuses to
  tell. The **queue** is `Vutuv.Posts.SummaryQueue` and owns only the ordering:
  it is started per test with `start_supervised!/1` and asked how it behaves at
  its cap.

  `async: false`: it flips `:summarize_links` and the two `plug:` seams
  `Vutuv.LinkSummary` reads, all of which are global application env the SQL
  sandbox does not roll back. `config/test.exs` keeps the app from starting a
  queue, so nothing makes a model call at a moment of its own choosing.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Posts.SummaryQueue

  @url "https://example.com/page"
  @sentence "Ein Bericht über den Ausbau der Radwege."

  # Long enough to clear the "is there anything here to summarise" floor.
  @page_text String.duplicate("Ein Absatz über den Bau von Fahrradwegen. ", 12)

  setup do
    Application.put_env(:vutuv, :summarize_links, true)

    on_exit(fn ->
      Application.delete_env(:vutuv, :summarize_links)
      Application.delete_env(:vutuv, :link_summary_req_options)
      Application.delete_env(:vutuv, :link_summary_ollama_req_options)
    end)

    :ok
  end

  defp stub_model(sentence) do
    Application.put_env(:vutuv, :link_summary_ollama_req_options,
      plug: fn conn ->
        answer = %{"message" => %{"content" => Jason.encode!(%{summary: sentence})}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(answer))
      end
    )
  end

  describe "write_link_summary/3 (the job)" do
    test "stores the sentence and tells the card, which is already on the page" do
      author = insert(:activated_user)
      {post, ready} = ready_preview!(author)
      stub_model(@sentence)

      Vutuv.Activity.subscribe(author.id)
      :ok = Screenshots.write_link_summary(ready.id, @url, @page_text)

      assert Repo.get!(PostScreenshot, ready.id).summary == @sentence

      # Nobody reloads a feed to find out whether a second line has appeared:
      # the capture's own announcement went out minutes ago.
      assert_receive {:post_screenshot_ready, %{post_id: ready_id}}
      assert ready_id == post.id
    end

    test "a preview the image scan still holds gets its sentence but no announcement" do
      # Announcing here would put a screenshot the scan has not released in
      # front of readers — the exact bypass `mark_ready/2` withholds its own
      # announcement to prevent. Nothing is lost: `ImageSubjects.apply_approved/1`
      # announces the row when the verdict lands, teaser and all.
      author = insert(:activated_user)
      {_post, held} = ready_preview!(author, "pending")
      stub_model(@sentence)

      Vutuv.Activity.subscribe(author.id)
      :ok = Screenshots.write_link_summary(held.id, @url, @page_text)

      assert Repo.get!(PostScreenshot, held.id).summary == @sentence
      refute_receive {:post_screenshot_ready, _payload}, 100
    end

    test "a row that vanished during the model call is a no-op, not a raise" do
      # The author can delete the post while the sentence is being written; the
      # row cascades with it. The write goes by id for exactly this.
      stub_model(@sentence)

      assert :ok = Screenshots.write_link_summary(Vutuv.UUIDv7.generate(), @url, @page_text)
    end

    test "an installation that does not summarise links writes nothing" do
      Application.put_env(:vutuv, :summarize_links, false)
      {_post, ready} = ready_preview!(insert(:activated_user))

      Application.put_env(:vutuv, :link_summary_ollama_req_options,
        plug: fn _conn -> flunk("the model must not be asked when the flag is off") end
      )

      :ok = Screenshots.write_link_summary(ready.id, @url, @page_text)

      assert Repo.get!(PostScreenshot, ready.id).summary == nil
    end

    test "the page is never fetched — the capture already read it" do
      {_post, ready} = ready_preview!(insert(:activated_user))

      Application.put_env(:vutuv, :link_summary_req_options,
        plug: fn _conn -> flunk("the capture already read this page") end
      )

      stub_model(@sentence)

      :ok = Screenshots.write_link_summary(ready.id, @url, @page_text)

      assert Repo.get!(PostScreenshot, ready.id).summary == @sentence
    end
  end

  describe "the queue (the ordering)" do
    test "runs what it is given" do
      start_supervised!(SummaryQueue)
      {_post, ready} = ready_preview!(insert(:activated_user))
      stub_model(@sentence)

      SummaryQueue.enqueue(ready.id, @url, @page_text)
      :ok = SummaryQueue.flush()

      assert Repo.get!(PostScreenshot, ready.id).summary == @sentence
    end

    test "a full queue drops the OLDEST job and takes the new one" do
      # Aim, not spend: a busy installation sits at the cap permanently, so
      # refusing new work here would spend the one Ollama entirely on links
      # nobody has looked at since lunch, while the card a member is watching
      # right now never gets a teaser.
      #
      # Called as a plain function on a made-up state, deliberately: a running
      # queue starts on the first job the moment it is cast, so filling one to
      # the brim through `enqueue/3` would be racing the drain it is meant to
      # be waiting behind. The policy under test is this clause and nothing
      # else.
      full = for i <- 1..SummaryQueue.max_queued(), do: {"id-#{i}", "#{@url}/#{i}", @page_text}
      newest = {"newest", @url, @page_text}

      assert {:noreply, %{queue: queue}} =
               SummaryQueue.handle_cast({:summarize, newest}, %{queue: full})

      assert length(queue) == SummaryQueue.max_queued()
      refute {"id-1", "#{@url}/1", @page_text} in queue
      assert List.last(queue) == newest
    end
  end
end
