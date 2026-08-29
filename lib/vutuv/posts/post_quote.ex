defmodule Vutuv.Posts.PostQuote do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_quotes" do
    # The quoting post itself; the row cascades away with it.
    belongs_to(:post, Vutuv.Posts.Post)
    # The post being quoted and its author at quote time. All three nilify on
    # deletion, so the quote outlives what it carries and degrades to a
    # placeholder line (see the migration for the state encoding) — the same
    # pair `Vutuv.Posts.PostReply` keeps for a parent.
    belongs_to(:quoted_post, Vutuv.Posts.Post)
    # The two kinds of author a quoted post can have (issue #1334): a member, or
    # the page it was published in the name of. Exactly one of them is set while
    # the quoted post lives; both are NULL once the account or page behind it is
    # gone, which is what the nameless placeholder reads.
    belongs_to(:quoted_author, Vutuv.Accounts.User)
    belongs_to(:quoted_organization, Vutuv.Organizations.Organization)

    timestamps()
  end
end
