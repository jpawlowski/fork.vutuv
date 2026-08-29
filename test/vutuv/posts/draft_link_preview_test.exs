defmodule Vutuv.Posts.DraftLinkPreviewTest do
  @moduledoc """
  The preview the composer shows before anything is published (issue #1714):
  the draft owns the `post_screenshots` row, the author picks which link it is
  for (or none), and publishing hands that same row to the post.

  `async: false`, because the whole file drives the real capture path and has to
  flip three application-wide flags to do it: `:generate_screenshots` (read by
  `Vutuv.Posts.reconcile_draft_preview/1` and `reconcile_screenshot/1`, i.e. by
  every post save in the suite), `:fetch_open_graph` (read by
  `Vutuv.OpenGraph.fetch/1`; off in `config/test.exs` so nothing else can dial
  out) and `:moderate_images` (read by `Vutuv.Moderation.ImageScans`, so a
  stored preview is released here instead of waiting on a scan). HTTP is stubbed
  through `:open_graph_req_options`.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Posts
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo

  @first "https://first.example/page"
  @second "https://second.example/page"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_draft_preview_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    put_env(:uploads_dir_prefix, tmp)
    put_env(:generate_screenshots, true)
    put_env(:fetch_open_graph, true)
    put_env(:moderate_images, false)

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.delete_env(:vutuv, :open_graph_req_options)
      Application.delete_env(:vutuv, :post_screenshot_req_options)
    end)

    fixture = Path.join(tmp, "fixture.png")
    {:ok, image} = Image.new(64, 36, color: [10, 90, 200])
    {:ok, _written} = Image.write(image, fixture)

    {:ok, tmp: tmp, png: File.read!(fixture), author: insert(:activated_user)}
  end

  defp put_env(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  # Both hosts answer a full Open Graph set, each naming itself, so a test can
  # tell which page a row describes.
  defp stub_pages(png) do
    Application.put_env(:vutuv, :open_graph_req_options,
      plug: fn conn ->
        case conn.request_path do
          "/page" ->
            name = conn.host

            conn
            |> Plug.Conn.put_resp_content_type("text/html", nil)
            |> Plug.Conn.send_resp(200, """
            <html><head>
            <meta property="og:title" content="Headline of #{name}">
            <meta property="og:description" content="Teaser of #{name}.">
            <meta property="og:site_name" content="#{name}">
            <meta property="og:image" content="https://#{name}/card.png">
            </head></html>
            """)

          "/card.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png", nil)
            |> Plug.Conn.send_resp(200, png)
        end
      end
    )
  end

  defp draft(author, body) do
    :ok = Posts.save_draft(author, nil, %{"body" => body})
    Posts.get_draft(author, nil)
  end

  defp preview(draft), do: Posts.draft_link_preview(draft)

  describe "reconcile_draft_preview/1" do
    test "the first link in the draft is previewed", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Two of them: #{@first} and #{@second}")

      :ok = Posts.reconcile_draft_preview(draft)
      assert preview(draft).url == @first

      Screenshots.deliver_due(force: true)
      ready = preview(draft)

      assert ready.status == "ready"
      assert ready.source == "open_graph"
      assert ready.title == "Headline of first.example"
      assert PostScreenshot.card?(ready)
    end

    test "dropping the link from the text drops the preview", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      :ok = Posts.reconcile_draft_preview(draft)
      assert preview(draft)

      draft = draft(author, "No link any more")
      :ok = Posts.reconcile_draft_preview(draft)

      assert preview(draft) == nil
      assert Repo.aggregate(PostScreenshot, :count) == 0
    end

    test "no draft rows reach the admin queue or gallery", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      :ok = Posts.reconcile_draft_preview(draft)

      assert {[], 0} = Screenshots.queue_page(%{})
      Screenshots.deliver_due(force: true)
      assert {[], 0} = Screenshots.gallery_page(%{})
      assert Screenshots.counts() == %{queue: 0, ready: 0}
    end
  end

  describe "choose/2" do
    test "the author points the preview at the other link", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Two of them: #{@first} and #{@second}")
      :ok = Posts.reconcile_draft_preview(draft)
      Screenshots.deliver_due(force: true)
      assert preview(draft).title == "Headline of first.example"

      {:ok, _chosen} = Posts.choose_draft_preview(draft, @second)
      assert preview(draft).url == @second
      # The old page's headline goes with the old page.
      assert preview(draft).title == nil

      Screenshots.deliver_due(force: true)
      assert preview(draft).title == "Headline of second.example"
    end

    test "a link that is not in the text is refused, not fetched", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Only this one: #{@first}")

      assert {:error, :not_a_candidate} =
               Posts.choose_draft_preview(draft, "https://elsewhere.example/x")
    end

    test "the author asks for no preview at all", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      :ok = Posts.reconcile_draft_preview(draft)
      Screenshots.deliver_due(force: true)
      assert PostScreenshot.card?(preview(draft))

      {:ok, _dismissed} = Posts.choose_draft_preview(draft, :none)

      assert preview(draft).status == "dismissed"
      refute PostScreenshot.card?(preview(draft))

      # And a later reconcile (the autosave keeps running while they type on)
      # must not quietly bring it back.
      :ok = Posts.reconcile_draft_preview(draft)
      Screenshots.deliver_due(force: true)
      assert preview(draft).status == "dismissed"
    end

    test "choosing the same link again lifts the author's own tombstone", %{
      author: author,
      png: png
    } do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      {:ok, _dismissed} = Posts.choose_draft_preview(draft, :none)
      assert preview(draft).status == "dismissed"

      {:ok, _back} = Posts.choose_draft_preview(draft, @first)

      assert preview(draft).status == "pending"
      Screenshots.deliver_due(force: true)
      assert PostScreenshot.card?(preview(draft))
    end

    test "asking for none before anything was fetched still sticks", %{author: author, png: png} do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")

      {:ok, _dismissed} = Posts.choose_draft_preview(draft, :none)
      assert preview(draft).status == "dismissed"
    end
  end

  describe "adopt_draft/2 (publishing)" do
    test "the published post keeps the very row the composer showed", %{
      author: author,
      png: png,
      tmp: tmp
    } do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      :ok = Posts.reconcile_draft_preview(draft)
      Screenshots.deliver_due(force: true)

      shown = preview(draft)
      assert shown.status == "ready"

      thumb =
        Path.join([tmp, "screenshots", shown.id, "thumb-#{Path.rootname(shown.screenshot)}.avif"])

      assert File.exists?(thumb)

      {:ok, post} = Posts.create_post(author, %{body: "Look: #{@first}"})
      :ok = Posts.adopt_draft_preview(draft, post)

      adopted = Repo.preload(post, :screenshot, force: true).screenshot

      # The same row, so the stored file never moved and the AI verdict on
      # those bytes still stands — no second fetch, no second scan.
      assert adopted.id == shown.id
      assert adopted.post_draft_id == nil
      assert adopted.title == "Headline of first.example"
      assert File.exists?(thumb)
      assert Repo.aggregate(PostScreenshot, :count) == 1
    end

    test "a preview the author dismissed stays dismissed after publishing", %{
      author: author,
      png: png
    } do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      {:ok, _dismissed} = Posts.choose_draft_preview(draft, :none)

      {:ok, post} = Posts.create_post(author, %{body: "Look: #{@first}"})
      :ok = Posts.adopt_draft_preview(draft, post)

      assert Repo.preload(post, :screenshot, force: true).screenshot.status == "dismissed"
    end

    test "publishing without a draft preview leaves the post's own job alone", %{author: author} do
      {:ok, post} = Posts.create_post(author, %{body: "Look: #{@first}"})
      :ok = Posts.adopt_draft_preview(%PostDraft{id: Vutuv.UUIDv7.generate()}, post)

      assert Repo.preload(post, :screenshot, force: true).screenshot
    end
  end

  describe "cleanup" do
    test "discarding the draft takes the preview's files with it", %{
      author: author,
      png: png,
      tmp: tmp
    } do
      stub_pages(png)
      draft = draft(author, "Look: #{@first}")
      :ok = Posts.reconcile_draft_preview(draft)
      Screenshots.deliver_due(force: true)

      dir = Path.join([tmp, "screenshots", preview(draft).id])
      assert File.exists?(dir)

      :ok = Posts.delete_draft(author, nil)

      # The row cascades with the draft; the files are the part that needs
      # saying so out loud.
      assert Repo.aggregate(PostScreenshot, :count) == 0
      refute File.exists?(dir)
    end
  end
end
