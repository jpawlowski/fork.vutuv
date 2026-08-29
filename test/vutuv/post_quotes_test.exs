defmodule Vutuv.PostQuotesTest do
  @moduledoc """
  Quoting a post (issue #1610): a post of one's own that carries somebody
  else's inside it.

  What these pin down is mostly what a quote is **not**. It is not a reply —
  no thread, no reply count, no thread notification — and it is not a silent
  reshare either: it takes the reshare's gate, notifies the quoted author and
  pins their audience open. Each half is a decision somebody could reasonably
  undo by folding quotes into `Vutuv.Posts.PostReply`, so each half is asserted.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostQuote
  alias Vutuv.Social

  defp user, do: insert(:activated_user)

  defp quote!(author, quoted) do
    {:ok, post} = Posts.create_quote(author, quoted, %{body: "Worth reading."})
    post
  end

  # The sidecar and both of its author sides, which `quote_ref_state/1` and
  # `quoted_state/3` read. `create_quote/3` hands back a post that already
  # carries them; only a re-read after a deletion or a freeze needs this.
  defp with_quote_ref(post) do
    Repo.preload(post, [quote_ref: [:quoted_post, :quoted_author, :quoted_organization]],
      force: true
    )
  end

  describe "create_quote/3" do
    test "writes the sidecar naming the quoted post and its author" do
      author = user()
      quoter = user()
      quoted = create_post!(author, %{body: "The original."})

      post = quote!(quoter, quoted)

      assert %PostQuote{} = ref = Repo.get_by(PostQuote, post_id: post.id)
      assert ref.quoted_post_id == quoted.id
      assert ref.quoted_author_id == author.id
      assert ref.quoted_organization_id == nil
      assert post.user_id == quoter.id
    end

    test "is not a reply: no reply row, no reply count, not in the thread" do
      author = user()
      quoted = create_post!(author, %{body: "The original."})

      post = quote!(user(), quoted)

      assert Repo.preload(post, :reply_ref).reply_ref == nil
      assert Posts.reply_count(quoted.id) == 0
      assert Posts.engagement_counts(quoted.id).replies == 0
      assert Posts.list_replies(quoted, nil) == []
    end

    test "counts on the quoted post's engagement and moves with a deletion" do
      quoted = create_post!(user(), %{body: "The original."})

      post = quote!(user(), quoted)
      assert Posts.engagement_counts(quoted.id).quotes == 1
      assert Posts.quote_count(quoted.id) == 1
      assert Posts.has_quotes?(quoted)

      {:ok, _} = Posts.delete_post(post)
      assert Posts.quote_count(quoted.id) == 0
      refute Posts.has_quotes?(quoted)
    end

    test "deleting the quote ticks the quoted post's open action bars" do
      # The count is on a bar somebody else may be looking at, and the row is
      # gone a line later — without the tick it keeps a figure for a card that
      # no longer exists until the page is reloaded.
      quoted = create_post!(user(), %{body: "The original."})
      post = quote!(user(), quoted)

      Posts.subscribe_post(quoted.id)
      quoted_id = quoted.id

      {:ok, _} = Posts.delete_post(post)

      assert_receive {:post_counters, %{post_id: ^quoted_id, quotes: 0}}
    end

    test "a frozen quote does not move the public count" do
      quoted = create_post!(user(), %{body: "The original."})
      post = quote!(user(), quoted)

      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      assert Posts.quote_count(quoted.id) == 0
      assert Posts.engagement_counts(quoted.id).quotes == 0
    end

    test "refuses a post deleted while the composer was open" do
      # The struct in hand is minutes old by submit time, and nothing else in
      # the gate asks whether the post is still there — without the re-read the
      # sidecar's foreign key raises and the LiveView goes down with it.
      author = user()
      quoted = create_post!(author, %{body: "gone in a moment"})
      {:ok, _} = Posts.delete_post(quoted)

      assert {:error, :not_visible} = Posts.create_quote(user(), quoted, %{body: "mine"})
    end

    test "refuses a restricted post, like a reshare does" do
      author = user()
      stranger = user()

      restricted =
        create_post!(author, %{body: "Only some of you.", denials: [%{"wildcard" => "everyone"}]})

      assert {:error, :restricted} = Posts.create_quote(author, restricted, %{body: "mine"})
      assert {:error, :not_visible} = Posts.create_quote(stranger, restricted, %{body: "mine"})
    end

    test "refuses a post restricted after the composer opened" do
      author = user()
      quoted = create_post!(author, %{body: "Public for now."})

      {:ok, _} =
        Posts.update_post(quoted, %{
          body: "Public for now.",
          denials: [%{"wildcard" => "everyone"}]
        })

      # The struct in hand still says public; the gate re-reads the denials.
      assert {:error, :restricted} = Posts.create_quote(author, quoted, %{body: "mine"})
    end

    test "refuses across a block, in either direction" do
      author = user()
      quoter = user()
      quoted = create_post!(author, %{body: "The original."})

      {:ok, _} = Social.block_user(author, quoter)

      assert {:error, :restricted} = Posts.create_quote(quoter, quoted, %{body: "mine"})
    end

    test "drops any audience the quote itself was given" do
      quoted = create_post!(user(), %{body: "The original."})

      {:ok, post} =
        Posts.create_quote(user(), quoted, %{
          body: "mine",
          denials: [%{"wildcard" => "everyone"}]
        })

      assert post.denials == []
      refute Posts.restricted?(post)
    end

    test "closes the quoted post's edit window and pins its audience open" do
      # A quote reproduces the words — a teaser of them sits inside somebody
      # else's post — so being quoted closes editing the way being answered or
      # reshared does, and the audience stays open on top of it (the two locks
      # ask `Posts.audience_locked?/1`, which is why both are asserted here).
      author = user()
      quoted = create_post!(author, %{body: "The original."})

      refute Posts.audience_locked?(quoted)
      assert {:ok, _} = Posts.update_post(quoted, %{body: "Second thoughts."})

      _post = quote!(user(), quoted)

      assert Posts.audience_locked?(quoted)

      assert {:error, :edit_engaged} =
               Posts.update_post(quoted, %{
                 body: "Third thoughts.",
                 denials: [%{"wildcard" => "everyone"}]
               })
    end
  end

  describe "quote_ref_state/1" do
    test "names the quoted post, then its author alone once it is deleted" do
      author = user()
      quoted = create_post!(author, %{body: "The original."})
      post = quote!(user(), quoted)

      assert {:quoted, %Post{}} = Posts.quote_ref_state(post)

      {:ok, _} = Posts.delete_post(quoted)

      post = with_quote_ref(post)

      assert {:author_only, quoted_author} = Posts.quote_ref_state(post)
      assert quoted_author.id == author.id
    end

    test "nil for a post that quotes nothing" do
      post = create_post!(user(), %{body: "Just a post."}) |> Repo.preload(:quote_ref)
      assert Posts.quote_ref_state(post) == nil
    end
  end

  describe "quoted_state/3" do
    test "shows the quoted post to an ordinary reader" do
      quoted = create_post!(user(), %{body: "The original."})
      post = quote!(user(), quoted)

      assert {:quoted, %Post{}} = Posts.quoted_state(post, user())
      assert {:quoted, %Post{}} = Posts.quoted_state(post, nil)
    end

    test "takes a handed-in blocked set instead of asking per card" do
      # The feed reads the set once for a page of twenty cards; the answer has
      # to be the same one the per-card query gives.
      author = user()
      reader = user()
      quoted = create_post!(author, %{body: "The original."})
      post = quote!(user(), quoted)

      assert {:quoted, _} = Posts.quoted_state(post, reader, MapSet.new())
      assert Posts.quoted_state(post, reader, MapSet.new([author.id])) == :unavailable
    end

    test "withholds it from a reader on either side of a block with its author" do
      # `visible_to?/2` never asks about blocks (the feed asks separately), and
      # this card carries a third party's name and words into a post the reader
      # did not choose to open — so the pair is asked here or the block leaks in
      # the one place the reader cannot scroll past.
      author = user()
      reader = user()
      quoted = create_post!(author, %{body: "The original."})
      post = quote!(user(), quoted)

      assert {:quoted, _} = Posts.quoted_state(post, reader)

      {:ok, _} = Social.block_user(reader, author)
      assert Posts.quoted_state(post, reader) == :unavailable
    end

    test "withholds a page's post once the page stops being publicly visible" do
      # The third thing that can put a quoted post out of reach, and the reason
      # `answerable?/1` exists: page visibility lives in the queries, so nothing
      # else in the card's render path asks it. Rows inserted directly — this is
      # about what the card shows, not about how a page publishes.
      page = insert(:organization)
      quoted = insert(:post, user: nil, organization: page, body: "The page's own.")
      post = insert(:post, user: user())
      insert(:post_quote, post: post, quoted_post: quoted, quoted_author: nil)

      post = with_quote_ref(post)
      assert {:quoted, %Post{}} = Posts.quoted_state(post, nil)

      {:ok, _} = Repo.update(Ecto.Changeset.change(page, status: "pending"))
      post = with_quote_ref(post)

      assert Posts.quoted_state(post, nil) == :unavailable
    end

    test "withholds a frozen quoted post from everyone" do
      quoted = create_post!(user(), %{body: "The original."})
      post = quote!(user(), quoted)

      Repo.update_all(from(p in Post, where: p.id == ^quoted.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      post = with_quote_ref(post)

      assert Posts.quoted_state(post, nil) == :unavailable
      assert Posts.quoted_state(post, user()) == :unavailable
    end
  end

  describe "notifications" do
    test "tells the quoted author, in its own kind" do
      author = user()
      quoter = user()
      quoted = create_post!(author, %{body: "The original."})

      Activity.subscribe(author.id)
      post = quote!(quoter, quoted)

      %{entries: entries} = Activity.notifications_page(author.id)
      entry = Enum.find(entries, &(&1.kind == "quote"))

      assert entry
      assert entry.post_id == quoted.id
      assert entry.quote_post_id == post.id
      # The row leads to the post that carries theirs — the thing worth reading.
      assert entry.post_path == Posts.path(post)
      # …and the live push says the same, or one event would have two
      # destinations depending on whether the page was open when it happened.
      assert_received {:new_notification, %{kind: "quote"} = pushed}
      assert pushed.post_path == Posts.path(post)
      # …and the badge counts it: the tally reads its own query, so a kind can
      # be listed and still never light the bell.
      assert Activity.unread_notification_count(Repo.reload!(author)) >= 1
    end

    test "a self-quote is not news" do
      author = user()
      quoted = create_post!(author, %{body: "The original."})

      _post = quote!(author, quoted)

      %{entries: entries} = Activity.notifications_page(author.id)
      refute Enum.any?(entries, &(&1.kind == "quote"))
    end

    test "no thread notification: a quote opens no conversation" do
      author = user()
      quoted = create_post!(author, %{body: "The original."})

      _post = quote!(user(), quoted)

      %{entries: entries} = Activity.notifications_page(author.id)
      refute Enum.any?(entries, &(&1.kind in ["reply", "thread"]))
    end
  end
end
