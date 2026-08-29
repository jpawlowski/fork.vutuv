defmodule Vutuv.Repo.Migrations.CreatePostQuotes do
  @moduledoc """
  Quoting a post (issue #1610): a post of one's own that carries somebody
  else's post inside it, shown as a compact card.

  A sidecar beside `post_replies` rather than a column on it, because a quote is
  deliberately **not** a reply: it stays out of the thread, out of the reply
  count and out of the thread notifications. A quoting post is an ordinary
  top-level post; this row is what names the post it carries.

  The NULL pairs are `post_replies`' exactly, and encode the same banner states:
  `post_id` cascades (the row lives and dies with the quote), while the quoted
  post and both kinds of quoted author (a member, or the page a post was
  published in the name of — issue #1334) nilify. Both set means the quoted post
  is alive; only `quoted_post_id` NULL means "a now-deleted post by X"; all
  three NULL means the account behind it is gone too and no name is retained.
  No CHECK for "exactly one author": both being NULL is a reachable, legitimate
  state here, same as on `post_replies`.

  N-1 safe: purely additive. The previous release neither writes nor reads the
  table, and its composer cannot produce a row that would want one.
  """
  use Ecto.Migration

  def change do
    create table(:post_quotes) do
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false)
      add(:quoted_post_id, references(:posts, type: :binary_id, on_delete: :nilify_all))
      add(:quoted_author_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(
        :quoted_organization_id,
        references(:organizations, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps()
    end

    # One quote per post: the quoting post carries exactly one card.
    create(unique_index(:post_quotes, [:post_id]))
    # "How often was this post quoted" — the count on every action bar.
    create(index(:post_quotes, [:quoted_post_id]))
    # The derived "X quoted your post" notification feed, and its page-shaped
    # twin, both read oldest-to-newest by author: the same `(id, inserted_at)`
    # shape the reply feed reads.
    create(index(:post_quotes, [:quoted_author_id, :inserted_at]))
    create(index(:post_quotes, [:quoted_organization_id, :inserted_at]))
  end
end
