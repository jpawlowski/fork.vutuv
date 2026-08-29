defmodule Vutuv.CardDav do
  @moduledoc """
  The member's address book: which of their contacts vutuv publishes over
  CardDAV (issue #1705), and the bookkeeping a synchronising client needs.

  A business network is an extended address book, and an address book that
  cannot reach the phone in your pocket is half a feature. So the people a
  member follows are offered as a **read-only** CardDAV collection
  (`VutuvWeb.CardDavController` speaks the protocol; this module owns the
  data).

  ## Whose cards, and only on request

  `users.carddav_sharing` is one of `sharing_levels/0`, `"off"` for everybody
  until they choose otherwise — the rows here are *other people's* contact
  details, so nothing is published by default and no installation-wide default
  can change that (see the field's comment in `Vutuv.Accounts.User`).

  The three live levels are nested, narrowest first:

    * `"personally_known"` — only follows the member ticked "I have met this
      person" (`follows.personally_known`).
    * `"mutual"` — only follows that are returned, what the site calls
      *vernetzt*.
    * `"following"` — everybody the member follows.

  Organization pages are deliberately absent: an address book is people.

  ## What a card contains

  Exactly the **anonymous public view** every visitor already sees, rendered
  from the same doc builder and the same vCard renderer as the `.vcf` download
  on a profile (`VutuvWeb.AgentDocs.ProfileDoc` → `VutuvWeb.AgentDocs.VCard`),
  never the session-aware permitted set. Two things ride along that a download
  has no use for: a stable `UID`, without which every sync would duplicate the
  contact, and the subscriber's own private `NOTE` — the one part of the card
  that belongs to its reader rather than to its subject.

  The `agent_docs_blocked?/1` opt-out does not apply here, for the reason the
  `.vcf` format is already exempt from it: a contact card is an exchange
  between people, not agent food.

  ## Why anything is stored at all

  A phone asks "what changed since token N?" and expects three answers: added,
  changed, **gone**. The first two can be derived from live data; the third
  cannot — once a follow is dropped, nothing is left to report. So the set a
  member last handed out lives in `carddav_cards`, and a contact who stops
  qualifying leaves a tombstone behind (`Vutuv.CardDav.Card`). That tombstone
  is what turns "I unfollowed them" into "their card left my phone", which is
  the half of this feature that protects the people *in* the address book.

  `refresh/1` is what maintains it, and it runs on request rather than in a
  sweeper: a sweeper would have to walk every member on a schedule to keep an
  answer nobody is asking for, while the client polling us is the exact moment
  the answer is wanted.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias Vutuv.CardDav.Card
  alias Vutuv.CardDav.PushSubscription
  alias Vutuv.Ordering
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
  alias Vutuv.UUIDv7
  alias Vutuv.WebPush
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

  @sharing_levels ~w(off personally_known mutual following)
  @visibility_levels ~w(followers mutual nobody)

  # The REV every ETag is computed against. REV is a timestamp, and the plain
  # renderer fills it with "now" — hashing that would make every card look
  # changed on every poll, which is precisely the traffic ETags exist to
  # prevent. The value is arbitrary; only its constancy matters.
  @etag_rev ~N[1970-01-01 00:00:00]

  @doc """
  The sharing levels, narrowest live level first after `"off"`. The order is
  the order the settings page offers them in, and it is also the containment
  order: every level contains the one before it.
  """
  def sharing_levels, do: @sharing_levels

  @doc """
  The levels a member may set for **their own** card: who is allowed to keep it
  in an address book.

    * `"followers"` — anybody who follows them. The default: what travels is the
      anonymous public view of a profile every visitor already sees, and a book
      that stays empty until each contact opts in individually is not a book.
    * `"mutual"` — only people they follow back.
    * `"nobody"` — the deliberate opt-out.

  **This outranks `sharing_levels/0`.** The subscriber decides whose cards they
  collect; the member decides whether theirs may be collected at all, and that
  answer wins — a `"nobody"` is absent from every book, however wide a
  subscriber opened theirs and whatever they marked.
  """
  def visibility_levels, do: @visibility_levels

  @doc """
  Whether this installation serves CardDAV at all.

  An installation switch rather than a hard-wired feature (see CLAUDE.md): a
  company intranet may well want the address book and no ActivityPub, and
  another operator may want neither. It makes no outbound calls, so it is on by
  default.
  """
  def enabled?, do: Application.get_env(:vutuv, :carddav_enabled, true)

  @doc "This member's sharing level, `\"off\"` when they never chose one."
  def sharing(%User{carddav_sharing: level}) when level in @sharing_levels, do: level
  def sharing(%User{}), do: "off"

  @doc "Whether this member publishes an address book at all."
  def publishing?(%User{} = user), do: sharing(user) != "off"

  # ── The published set ──

  @doc """
  The contacts this member currently publishes: `[%{contact: %User{}, note:
  binary | nil}]`, every contact preloaded for card rendering.

  One query for the edges, one for the members, one for their public email
  addresses, plus the profile preloads — for the whole book, not per contact.
  `ProfileDoc.build/2` then finds everything loaded and touches the database
  no further.
  """
  def contacts(%User{} = user) do
    case sharing(user) do
      "off" ->
        []

      level ->
        user
        |> follow_query(level)
        |> Repo.all()
        |> build_entries(Social.blocked_user_ids(user.id))
    end
  end

  @doc """
  **One** published contact, for the requests that are about a single card:
  `{:ok, entry, stored_card | nil}`, or `:error` when this member does not
  publish that contact (or never did).

  This exists because the whole-book path is the wrong instrument here. A GET
  or a PROPFIND of one card used to go through `snapshot/1`, which refreshes
  and renders **every** contact to use exactly one of them — and macOS Contacts
  and Thunderbird fetch cards one at a time, so an N-card book cost N² renders
  per sync. It narrows the same `follow_query/2` to one contact instead, so the
  qualification rules (visibility, level, moderation, blocks) stay in one place
  and cannot answer differently for one card than for the collection.

  It also **writes nothing**. The stored row is read, never refreshed: a GET
  that mutates state is a shape this codebase has been bitten by before
  (CLAUDE.md), and the collection-level reports are what a client discovers
  changes through anyway. The caller pairs the freshly rendered body with a
  freshly computed ETag, so the two always agree even when the stored row has
  since gone stale.
  """
  def entry(%User{} = user, contact_id) do
    with level when level != "off" <- sharing(user),
         id when is_binary(id) <- UUIDv7.cast_or_nil(contact_id),
         false <- Social.blocked_between?(user.id, id),
         [entry] <- one_contact(user, level, id) do
      {:ok, entry, card_view(entry, stored_card(user, id))}
    else
      _absent -> :error
    end
  end

  @doc """
  What one card's `getetag` and `getlastmodified` say.

  Formed here rather than in the web layer because it is a rule about cards,
  not about WebDAV: the ETag is hashed from the very entry the body will be
  rendered from — so the two agree even when the stored row went stale — and a
  contact that has never been through a collection refresh has no honest
  last-modified, where "now" is the least wrong answer for a property clients
  treat as advisory. The collection paths read the stored row directly, and
  `card_properties/1` therefore always sees one shape.
  """
  def card_view(entry, %Card{} = stored), do: %{etag: etag(entry), updated_at: stored.updated_at}
  def card_view(entry, nil), do: %{etag: etag(entry), updated_at: NaiveDateTime.utc_now(:second)}

  defp stored_card(%User{id: owner_id}, contact_id),
    do: Repo.get_by(Card, user_id: owner_id, contact_id: contact_id, deleted: false)

  # The block list is one query over every block the owner is party to, which
  # is the right shape for a whole book and the wrong one for a single card —
  # `entry/2` asks `blocked_between?/2` instead and hands in an empty set.
  defp one_contact(%User{} = user, level, contact_id) do
    user
    |> follow_query(level)
    |> where([contact: u], u.id == ^contact_id)
    |> Repo.all()
    |> build_entries(MapSet.new())
  end

  defp build_entries(rows, blocked) do
    rows =
      Enum.reject(rows, fn {contact, _note} ->
        MapSet.member?(blocked, to_string(contact.id))
      end)

    # The contact preload set, not the profile page's: `render_card/2` builds
    # its doc with `contact_only: true`, and loading the associations that mode
    # never reads would be the same waste one function further out.
    contacts = rows |> Enum.map(&elem(&1, 0)) |> ProfileDoc.preload(true)
    emails = public_emails(Enum.map(contacts, & &1.id))

    # Keyed by id rather than zipped by position: pairing the preloaded
    # contacts back to their notes positionally would hold only as long as
    # `Repo.preload/2` returns the list in the order it was given, which is
    # true and is nowhere promised.
    notes = Map.new(rows, fn {contact, note} -> {contact.id, note} end)

    Enum.map(contacts, fn contact ->
      %{contact: contact, note: notes[contact.id], emails: Map.get(emails, contact.id, [])}
    end)
  end

  # The follow edges that qualify, with the follower's private note. The
  # followee side is a **member** (`followee_id`), never an organization page,
  # and it passes the same moderation gate the public follow lists apply: a
  # suspended or hidden account drops out of the book on the next sync, which
  # is the point of maintaining one.
  defp follow_query(%User{id: owner_id}, level) do
    from(f in Follow,
      join: u in User,
      as: :contact,
      on: u.id == f.followee_id,
      where: f.follower_id == ^owner_id and not is_nil(f.followee_id),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      order_by: [asc: u.id],
      select: {u, f.note}
    )
    |> filter_visibility(owner_id)
    |> filter_level(level, owner_id)
  end

  # The contact's own say, applied before the subscriber's (see
  # `visibility_levels/0`): "nobody" is out of every book, and "mutual" only
  # stays in the book of somebody they follow back. Written as one predicate
  # over both cases so there is a single place this rule lives.
  defp filter_visibility(query, owner_id) do
    from([_f, contact: u] in query,
      where:
        u.carddav_visibility != "nobody" and
          (u.carddav_visibility != "mutual" or
             exists(
               from(back in Follow,
                 where:
                   back.follower_id == parent_as(:contact).id and
                     back.followee_id == ^owner_id
               )
             ))
    )
  end

  defp filter_level(query, "personally_known", _owner_id) do
    from(f in query, where: f.personally_known)
  end

  # "Returned" is the site's own definition of *vernetzt*: a follow edge in the
  # other direction. An inner join rather than an EXISTS, because the row is
  # either there or the contact does not belong in this level at all.
  defp filter_level(query, "mutual", owner_id) do
    from([f, contact: u] in query,
      join: back in Follow,
      on: back.follower_id == u.id and back.followee_id == ^owner_id
    )
  end

  defp filter_level(query, "following", _owner_id), do: query

  # Every published card's public addresses in one query instead of one per
  # card. `ProfileDoc.build/2` takes them as its `:emails` option, which is the
  # same list its own lookup would produce for an anonymous reader.
  defp public_emails([]), do: %{}

  defp public_emails(ids) do
    from(e in Email, where: e.user_id in ^ids and e.public?)
    |> Ordering.by_position()
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
  end

  # How many cards a level would publish, without rendering any of them — the
  # figure beside each choice on `/settings/carddav`. Private: `counts/1` is
  # the surface, and it never asks about "off", which publishes nothing by
  # definition and has no `filter_level/3` clause to ask with.
  defp count(%User{} = user, level) when level in @sharing_levels do
    user
    |> follow_query(level)
    |> exclude(:order_by)
    |> exclude(:select)
    |> Repo.aggregate(:count)
  end

  @doc "The three live levels with their counts, in the order they are offered."
  def counts(%User{} = user) do
    Map.new(@sharing_levels -- ["off"], fn level -> {level, count(user, level)} end)
  end

  # ── Rendering ──

  @doc """
  One contact rendered as a vCard, `nil` for the `rev` of a card that has
  never been synced.
  """
  def render_card(%{contact: contact} = entry, opts \\ []) do
    contact
    |> ProfileDoc.build(
      contact_only: true,
      emails: entry.emails,
      include_photo: Keyword.get(opts, :include_photo, true)
    )
    |> VCard.render(uid: contact.id, note: entry.note, rev: Keyword.get(opts, :rev))
  end

  @doc """
  The ETag of a contact's card: a hash over the card as rendered, plus the
  avatar's content fingerprint.

  The photo is hashed by proxy rather than by value — `users.avatar_fingerprint`
  is already the sha256 of the original image, so a changed picture changes the
  ETag without every sync reading and base64-ing every avatar on disk.
  """
  def etag(%{contact: contact} = entry) do
    body = render_card(entry, include_photo: false, rev: @etag_rev)

    :crypto.hash(:sha256, [body, "|", to_string(contact.avatar_fingerprint)])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # ── Synchronisation state ──

  @doc """
  Everything one CardDAV request needs, computed once:

      %{revision: integer, entries: %{contact_id => entry}, cards: [%Card{}]}

  `refresh/1` runs first, so `cards` is already up to date and `entries` are
  the rendered-ready contacts behind them. A request that asked for cards would
  otherwise recompute the whole book two or three times over — the refresh
  already knows every contact it just hashed.
  """
  def snapshot(%User{} = user) do
    Map.put(book(user), :cards, live_cards(user))
  end

  @doc """
  The refreshed book without the card rows: `%{revision:, entries:}`.

  What a `sync-collection` report needs, and all it needs — it answers from
  `changes_since/2`, so the `live_cards/1` query `snapshot/1` runs on top is
  dead work on the single most frequent request this endpoint gets.
  """
  def book(%User{} = user) do
    {revision, entries} = do_refresh(user)

    %{revision: revision, entries: Map.new(entries, &{&1.contact.id, &1})}
  end

  @doc """
  Brings `carddav_cards` in line with what the member publishes right now and
  returns the current sync revision.

  Nothing is written when nothing changed — that is the common case on a poll,
  and it keeps the revision (and therefore every client's sync token) still.
  """
  def refresh(%User{} = user) do
    {revision, _entries} = do_refresh(user)
    revision
  end

  defp do_refresh(%User{} = user) do
    entries = contacts(user)
    current = Map.new(entries, fn entry -> {entry.contact.id, etag(entry)} end)
    stored = Map.new(stored_cards(user), &{&1.contact_id, &1})

    # Changed means "not exactly what we already stored": no row at all, a
    # different ETag, or a row we had tombstoned and now publish again.
    changed =
      Enum.reject(current, fn {id, etag} ->
        match?(%Card{etag: ^etag, deleted: false}, Map.get(stored, id))
      end)

    gone =
      for {id, %Card{deleted: false}} <- stored, not Map.has_key?(current, id), do: id

    {apply_changes(user, changed, gone), entries}
  end

  defp apply_changes(%User{} = user, [], []), do: revision(user)

  defp apply_changes(%User{id: owner_id}, changed, gone) do
    revision = bump_revision(owner_id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    write_cards(owner_id, changed, revision, now)
    tombstone_cards(owner_id, gone, revision, now)

    revision
  end

  defp write_cards(_owner_id, [], _revision, _now), do: :ok

  defp write_cards(owner_id, changed, revision, now) do
    entries =
      Enum.map(changed, fn {contact_id, etag} ->
        %{
          id: UUIDv7.generate(),
          user_id: owner_id,
          contact_id: contact_id,
          etag: etag,
          revision: revision,
          deleted: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Card, entries,
      on_conflict: {:replace, [:etag, :revision, :deleted, :updated_at]},
      conflict_target: [:user_id, :contact_id]
    )

    :ok
  end

  defp tombstone_cards(_owner_id, [], _revision, _now), do: :ok

  defp tombstone_cards(owner_id, gone, revision, now) do
    Repo.update_all(
      from(c in Card, where: c.user_id == ^owner_id and c.contact_id in ^gone),
      set: [deleted: true, revision: revision, updated_at: now]
    )

    :ok
  end

  # One statement, so two clients synchronising at the same moment cannot mint
  # the same revision: Postgres serialises the increment and RETURNING hands
  # back the value this caller got.
  defp bump_revision(owner_id) do
    {1, [revision]} =
      Repo.update_all(
        from(u in User, where: u.id == ^owner_id, select: u.carddav_revision),
        inc: [carddav_revision: 1]
      )

    revision
  end

  @doc "The member's current sync revision, read fresh."
  def revision(%User{id: owner_id}) do
    Repo.one(from(u in User, where: u.id == ^owner_id, select: u.carddav_revision)) || 0
  end

  @doc "Every card row this member has, tombstones included."
  def stored_cards(%User{id: owner_id}) do
    Repo.all(from(c in Card, where: c.user_id == ^owner_id))
  end

  @doc "The cards this member currently publishes, as stored rows."
  def live_cards(%User{id: owner_id}) do
    Repo.all(from(c in Card, where: c.user_id == ^owner_id and not c.deleted, order_by: c.id))
  end

  # ── WebDAV-Push ──
  #
  # CardDAV itself has no push: the freshness contract is a client polling
  # `getctag` / `sync-collection`. WebDAV-Push (the DAVx⁵ draft) adds one, and
  # it does so over plain Web Push — the device names a push endpoint of its
  # own, we send one small encrypted XML message when the book moves, and the
  # device then runs the ordinary sync it would otherwise have run on a timer.
  #
  # Nobody issues us anything for that: VAPID is self-signed and
  # `Vutuv.WebPush` already derives this installation's key pair
  # from `secret_key_base`. (Apple's own CalDAV/CardDAV push is a different
  # extension over APNS, needs a certificate from Apple that a third-party
  # server cannot obtain, and is what iOS Contacts honours — so an iPhone stays
  # on polling whatever we build here.)

  @push_expiry_days 30
  @push_max_expiry_days 90

  @doc "Whether this installation can serve WebDAV-Push at all."
  def push_enabled?, do: enabled?() and WebPush.enabled?()

  @doc "The maximum lifetime of a push registration, in days."
  def push_max_expiry_days, do: @push_max_expiry_days

  @doc """
  The collection's push **topic**: one server-wide identifier the client uses
  to match an arriving push to the collection it belongs to.

  Keyed with a pepper derived from `secret_key_base` rather than a bare hash of
  the member id (CLAUDE.md): a UUID v7 carries a timestamp, so it is not the
  high-entropy input a bare hash would need, and this costs three lines.
  """
  def topic(%User{id: owner_id}) do
    :hmac
    |> :crypto.mac(:sha256, topic_pepper(), "carddav/collection/" <> owner_id)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  defp topic_pepper do
    :crypto.hash(
      :sha256,
      "vutuv/carddav/topic/pepper/v1" <> VutuvWeb.Endpoint.config(:secret_key_base)
    )
  end

  @doc """
  Registers one device's push endpoint. `expires_at` is what the client asked
  for, capped at `push_max_expiry_days/0` and defaulted when absent — a
  registration that never expired would outlive the device.
  """
  def register_push(%User{} = user, attrs) do
    %PushSubscription{user_id: user.id}
    |> PushSubscription.changeset(Map.put(attrs, :expires_at, capped_expiry(attrs[:expires_at])))
    |> Repo.insert()
  end

  defp capped_expiry(requested) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    default = DateTime.add(now, @push_expiry_days * 86_400, :second)
    ceiling = DateTime.add(now, @push_max_expiry_days * 86_400, :second)

    case requested do
      %DateTime{} = at ->
        cond do
          DateTime.compare(at, now) != :gt -> default
          DateTime.compare(at, ceiling) == :gt -> ceiling
          true -> DateTime.truncate(at, :second)
        end

      _absent ->
        default
    end
  end

  @doc "One of the member's own push registrations, or nil (also on a bad id)."
  def get_push_subscription(%User{id: owner_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      id -> Repo.get_by(PushSubscription, id: id, user_id: owner_id)
    end
  end

  @doc "Drops one registration. The client's DELETE on its registration URL."
  def unregister_push(%PushSubscription{} = subscription), do: Repo.delete(subscription)

  @doc "Every live registration this member has."
  def push_subscriptions(%User{id: owner_id}) do
    Repo.all(from(s in PushSubscription, where: s.user_id == ^owner_id, order_by: s.id))
  end

  @doc """
  One sweeper pass: the least recently checked registrations, refreshed and —
  where the book actually moved — pushed. Returns how many pushes went out.

  Every outcome stamps `checked_at`, including the ones that send nothing.
  That is the scheduler's clock, not a claim that anything happened: an item
  that cannot be worked on has to leave the front of the queue, or an
  oldest-first batch spends itself on the same rows forever (CLAUDE.md).
  Only a *successful* push advances `last_revision`, so a failed one is
  retried on the next pass rather than lost.
  """
  @push_check_interval :timer.minutes(2)

  def push_due(limit \\ 50) do
    if push_enabled?() do
      limit
      |> due_push_subscriptions()
      |> Enum.group_by(& &1.user_id)
      |> Map.values()
      |> Enum.flat_map(&deliver_group/1)
      |> stamp_unchanged()
      |> Enum.count(&(&1 == :sent))
    else
      0
    end
  end

  # Ordered oldest-first **and** bounded by a due floor. Without it every pass
  # took every registration, so a book was re-rendered every couple of minutes
  # whether or not anything could have moved, and a second sweeper (another
  # node, a manual run) simply doubled that. A row that has never been checked
  # is always due, so a device that registers between two passes does not wait.
  #
  # `PushSweeper` polls at well under this floor rather than at exactly it —
  # the `Vutuv.Fediverse.CountsRefresher` convention. Matching the two numbers
  # would halve the real cadence (a row checked exactly one interval ago is not
  # yet *older* than one interval) and buys a fudge constant to hide it.
  defp due_push_subscriptions(limit) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-@push_check_interval, :millisecond)
      |> NaiveDateTime.truncate(:second)

    Repo.all(
      from(s in PushSubscription,
        where: is_nil(s.checked_at) or s.checked_at < ^cutoff,
        order_by: [asc_nulls_first: s.checked_at, asc: s.id],
        limit: ^limit,
        preload: [:user]
      )
    )
  end

  # Every registration of one member, together. The refresh is the expensive
  # half — it re-renders that member's whole book — and it does not depend on
  # which device is asking, so a member with a phone, a tablet and a laptop
  # used to pay for it three times per pass.
  defp deliver_group(subscriptions) do
    {owned, dead} =
      Enum.split_with(subscriptions, &(PushSubscription.live?(&1) and is_map(&1.user)))

    delete_subscriptions(dead)

    case owned do
      [] ->
        []

      [%PushSubscription{user: user} | _rest] ->
        revision = refresh(user)
        Enum.map(owned, &push_if_moved(&1, user, revision))
    end
  end

  defp delete_subscriptions([]), do: :ok

  defp delete_subscriptions(subscriptions) do
    ids = Enum.map(subscriptions, & &1.id)
    Repo.delete_all(from(s in PushSubscription, where: s.id in ^ids))
    :ok
  end

  # A device whose book has not moved needs its clock stamped and nothing else,
  # and that is almost every device on almost every pass. Collecting them and
  # writing once turns up to fifty single-row UPDATEs into one.
  defp push_if_moved(%PushSubscription{} = subscription, user, revision) do
    if revision <= subscription.last_revision do
      {:unchanged, subscription.id}
    else
      send_push(subscription, user, revision)
    end
  end

  defp stamp_unchanged(outcomes) do
    {unchanged, rest} = Enum.split_with(outcomes, &match?({:unchanged, _id}, &1))

    case Enum.map(unchanged, &elem(&1, 1)) do
      [] ->
        :ok

      ids ->
        Repo.update_all(from(s in PushSubscription, where: s.id in ^ids),
          set: [checked_at: NaiveDateTime.utc_now(:second)]
        )
    end

    rest ++ Enum.map(unchanged, fn _ -> :unchanged end)
  end

  # The delivery half behind one seam. It is `Vutuv.WebPush` in
  # every real run; a test swaps it for something that records what would have
  # gone out, because the alternative is a suite that either talks to a push
  # service or cannot cover the sweeper's decisions at all.
  defp sender, do: Application.get_env(:vutuv, :carddav_push_sender, WebPush)

  defp send_push(subscription, user, revision) do
    case sender().send_body(PushSubscription.target(subscription), push_message(user, revision)) do
      :ok ->
        stamp_push(subscription, revision)
        :sent

      # The push service says this endpoint is dead. Deleting is the only way a
      # push list stays clean, and it is what the Mastodon sender does too.
      {:error, :gone} ->
        Repo.delete(subscription)
        :gone

      {:error, _other} ->
        stamp_push(subscription, nil)
        :failed
    end
  end

  defp stamp_push(subscription, revision) do
    changes = [checked_at: NaiveDateTime.utc_now(:second)]
    changes = if revision, do: Keyword.put(changes, :last_revision, revision), else: changes

    Repo.update_all(from(s in PushSubscription, where: s.id == ^subscription.id), set: changes)
  end

  @sync_token_prefix "urn:vutuv:carddav:"

  @doc """
  The sync token for a revision, and its inverse.

  Both live here rather than in the controller because the push body names a
  token that the `sync-collection` report then has to parse: split across two
  modules the prefix can drift, and the failure is a device being told a token
  the server will refuse — with nothing in between to notice.
  """
  def sync_token(revision), do: @sync_token_prefix <> Integer.to_string(revision)

  @doc """
  An initial sync sends no token and means "everything", which is revision 0.
  A token in anybody else's vocabulary is refused rather than guessed at: the
  client then starts over, which is correct and cheap.
  """
  def parse_sync_token(nil), do: {:ok, 0}

  def parse_sync_token(@sync_token_prefix <> revision) do
    case Integer.parse(revision) do
      {value, ""} when value >= 0 -> {:ok, value}
      _unparsable -> :error
    end
  end

  def parse_sync_token(_other), do: :error

  @doc """
  The push body: the topic that says which collection moved, and the sync token
  the client would otherwise have to ask for. It rides inside the Web Push
  encryption, so the push service never reads it.
  """
  def push_message(%User{} = user, revision) do
    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      ~s(<push-message xmlns="https://bitfire.at/webdav-push" xmlns:D="DAV:">) <>
      "<topic>" <>
      topic(user) <>
      "</topic>" <>
      "<content-update><D:sync-token>" <>
      sync_token(revision) <>
      "</D:sync-token></content-update>" <>
      "</push-message>"
  end

  @doc """
  The rows that changed after `since`, for a `sync-collection` report:
  `{:ok, rows, revision}`, or `{:error, :invalid_token}` when the client names
  a revision this member never reached (a token from another installation, or
  one restored from a backup that is ahead of us).
  """
  def changes_since(%User{id: owner_id} = user, since, revision \\ nil)
      when is_integer(since) do
    # The caller usually just refreshed and therefore already holds this
    # number; re-reading the column would be one free SELECT per sync poll.
    revision = revision || revision(user)

    if since > revision do
      {:error, :invalid_token}
    else
      rows =
        Repo.all(
          from(c in Card,
            where: c.user_id == ^owner_id and c.revision > ^since,
            order_by: [asc: c.revision, asc: c.id]
          )
        )

      {:ok, rows, revision}
    end
  end
end
