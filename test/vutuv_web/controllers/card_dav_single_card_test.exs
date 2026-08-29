defmodule VutuvWeb.CardDavSingleCardTest do
  @moduledoc """
  A request about **one** card must cost one card.

  macOS Contacts and Thunderbird fetch cards one at a time, and the single-card
  handlers used to go through `CardDav.snapshot/1` — which refreshes and
  renders the whole book to use one entry of it. An N-card book therefore cost
  N² card renders per sync, invisibly, because every individual response was
  correct.

  Measured in reductions rather than wall clock: `mix test` runs twenty cases
  in parallel, so the clock reports the machine (CLAUDE.md). Calibrated against
  the snapshot-based handlers — on those the same request cost 43_316 /
  92_033 / 306_926 reductions for a book of 1 / 16 / 64 contacts, against a
  flat ~21_000 now. The linear-in-the-book shape is what the bound refuses.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.CardDavHelpers

  alias Vutuv.CardDav
  alias Vutuv.Repo
  alias Vutuv.WorkCounter

  @token "vutuv_pat_carddav_one_card"

  setup do
    owner = insert(:activated_user, carddav_sharing: "following")
    contact = insert(:activated_user, first_name: "Ada", last_name: "Lovelace")
    follow!(owner, contact)

    carddav_token!(owner, @token)

    %{owner: owner, contact: contact}
  end

  defp fetch(conn, owner, contact),
    do: dav(conn, @endpoint, :get, card_path(owner, contact), "", token: @token)

  test "fetching one card costs about the same whatever else is in the book", ctx do
    CardDav.refresh(ctx.owner)

    # A throwaway request first: the very first one through this path pays the
    # query planning and code loading for all of them, and measuring it would
    # flatter whichever measurement came first.
    fetch(ctx.conn, ctx.owner, ctx.contact)

    {alone, small} =
      WorkCounter.count_reductions(fn -> fetch(ctx.conn, ctx.owner, ctx.contact) end)

    assert small.status == 200

    for _ <- 1..63, do: follow!(ctx.owner, insert(:activated_user))
    CardDav.refresh(ctx.owner)

    fetch(ctx.conn, ctx.owner, ctx.contact)

    {crowded, large} =
      WorkCounter.count_reductions(fn -> fetch(ctx.conn, ctx.owner, ctx.contact) end)

    assert large.status == 200
    assert large.resp_body == small.resp_body

    # Measured on this tree (OTP 28): one card costs ~21_000 reductions whether
    # the book holds 1 contact or 64. The snapshot-based handler cost 43_316 /
    # 92_033 / 306_926 for 1 / 16 / 64 — a factor of seven at 64, and it keeps
    # climbing. Twice the one-contact cost sits far above the flat measurement
    # and far below the linear one; a bound of three would have passed the
    # broken code at 16 contacts, which is why this uses 64.
    assert crowded < alone * 2,
           "one card cost #{crowded} reductions in a 64-contact book against #{alone} in a 1-contact book"
  end

  test "fetching a card writes nothing, even when the book has drifted", ctx do
    CardDav.refresh(ctx.owner)
    before = Repo.reload!(ctx.owner).carddav_revision

    # A change the collection has not been told about yet: on the old handler
    # the GET refreshed the whole book and bumped the revision, which is a GET
    # mutating state (CLAUDE.md) as well as the wasted work.
    follow!(ctx.owner, insert(:activated_user))

    assert fetch(ctx.conn, ctx.owner, ctx.contact).status == 200
    assert Repo.reload!(ctx.owner).carddav_revision == before
  end

  test "a contact who is not published is a 404, not a stale card", ctx do
    stranger = insert(:activated_user)
    assert fetch(ctx.conn, ctx.owner, stranger).status == 404
  end

  test "the ETag matches the body even when the stored row is stale", ctx do
    CardDav.refresh(ctx.owner)

    # Change the contact without refreshing: the stored ETag is now wrong.
    ctx.contact
    |> Ecto.Changeset.change(%{last_name: "Byron"})
    |> Repo.update!()

    answered = fetch(ctx.conn, ctx.owner, ctx.contact)
    [etag] = Plug.Conn.get_resp_header(answered, "etag")

    assert answered.resp_body =~ "Byron"
    assert {:ok, entry, _stored} = CardDav.entry(Repo.reload!(ctx.owner), ctx.contact.id)
    assert etag == ~s("#{CardDav.etag(entry)}")
  end
end
