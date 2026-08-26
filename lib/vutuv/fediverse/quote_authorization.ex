defmodule Vutuv.Fediverse.QuoteAuthorization do
  @moduledoc """
  One standing permission for a post on another network to quote a post of ours
  (issue #1608) — the "stamp" FEP-044f calls a `QuoteAuthorization`.

  Quoting in the fediverse is consent-first by design, and the consent is a
  **document, not a message**: the quoting server publishes our stamp's URL
  beside its quote, and every third server that renders that quote fetches the
  URL to check the permission is still live. Withdrawal is therefore not a
  request anybody may ignore — deleting the row makes the URL answer `410`, and
  the quote stops rendering everywhere that checks.

  That is also why the row holds so much: it is the whole of what the withdrawal
  needs, long after the thing it describes is gone.

    * `interacting_object_uri` — the remote post doing the quoting. Half of the
      identity (with `post_id`), and what a third party's stamp fetch is checked
      against.
    * `actor_uri` / `inbox_uri` — who quoted us and where a
      `Delete(QuoteAuthorization)` reaches them. Nullable inbox: an actor
      document without a usable inbox still gets its answer, it simply cannot be
      told later, and the stamp's `410` carries the withdrawal on its own.
    * `request_activity_id` — the `QuoteRequest` this answers, so a redelivery
      finds this row instead of minting a second stamp for one quote.
    * `note_uri` — our own Note id **as published at the time**. A Note id is
      built from the author's username, so after a rename (issue #1086) an id
      rebuilt from the current one names nothing the other server stored; the
      stamp has to keep naming what it named when it was issued.

  Like `Vutuv.Fediverse.PostDelivery` beside it, and for the same reason, the
  ids are plain columns and **not** foreign keys: the withdrawal runs after the
  post row is gone, so a cascade would erase these rows moments before they are
  needed. `Vutuv.Fediverse` clears them explicitly instead.
  """

  use VutuvWeb, :model

  # Remote URIs are unbounded in theory. Capped in **bytes**, like every other
  # one here, because `interacting_object_uri` is half of a unique index whose
  # btree entry has a hard size limit — a hostile multi-kilobyte id must fail
  # the changeset, never the insert, which would be a 500 out of the inbox.
  @max_uri_bytes 2_048

  schema "fediverse_quote_authorizations" do
    field(:post_id, :binary_id)
    field(:user_id, :binary_id)
    field(:organization_id, :binary_id)

    field(:interacting_object_uri, :string)
    field(:actor_uri, :string)
    field(:inbox_uri, :string)
    field(:request_activity_id, :string)
    field(:note_uri, :string)
    field(:accepted_at, :utc_datetime)

    timestamps(updated_at: false)
  end

  @doc "The longest remote URI a stamp may carry."
  def max_uri_bytes, do: @max_uri_bytes

  def changeset(%__MODULE__{} = authorization, attrs) do
    authorization
    |> cast(attrs, [
      :post_id,
      :user_id,
      :organization_id,
      :interacting_object_uri,
      :actor_uri,
      :inbox_uri,
      :request_activity_id,
      :note_uri,
      :accepted_at
    ])
    |> validate_required([
      :post_id,
      :interacting_object_uri,
      :actor_uri,
      :note_uri,
      :accepted_at
    ])
    |> validate_length(:interacting_object_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:actor_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:inbox_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:request_activity_id, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:note_uri, max: @max_uri_bytes, count: :bytes)
    |> unique_constraint([:post_id, :interacting_object_uri],
      name: :fediverse_quote_authorizations_post_object_index
    )
  end
end
