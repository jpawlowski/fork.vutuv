defmodule Vutuv.CardDav.Card do
  @moduledoc """
  One card in one member's CardDAV address book — or the tombstone of one.

  The row is bookkeeping, not content: the card itself is rendered from the
  contact's live profile on every request. What is stored is only what a
  synchronising client needs and the live data cannot answer:

    * `etag` — a hash of the rendered card, so a poll that changed nothing
      transfers nothing.
    * `revision` — the owner's `carddav_revision` at the moment this row last
      changed, which is what `sync-collection` (RFC 6578) reports against.
    * `deleted` — the tombstone. A contact who stops qualifying (unfollowed,
      blocked, suspended, mark removed) has to be reported **gone** exactly
      once, and by then there is nothing in the live data left to report.

  `user_id` is the subscriber whose address book this is; `contact_id` is the
  member the card is about. Both cascade: an account leaving takes its own book
  and its appearances in everybody else's with it.
  """

  use VutuvWeb, :model

  schema "carddav_cards" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:contact, Vutuv.Accounts.User)

    field(:etag, :string)
    field(:revision, :integer)
    field(:deleted, :boolean, default: false)

    timestamps()
  end
end
