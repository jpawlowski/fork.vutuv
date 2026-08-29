# CardDAV: the address book

A business network is an extended address book, and an address book that cannot
reach the phone in your pocket is half a feature. vutuv therefore publishes the
people a member follows as a **read-only CardDAV collection**, subscribable from
iOS and macOS Contacts, Thunderbird, DAVx⁵ and anything else that speaks the
protocol (issue #1705).

Two modules own it:

| Module | Role |
|---|---|
| `Vutuv.CardDav` | which cards exist, what they contain, the synchronisation state, and the push half |
| `Vutuv.CardDav.PushSweeper` | notices that a book moved and notifies subscribed devices |
| `VutuvWeb.CardDavController` | the protocol: PROPFIND, REPORT, GET |
| `VutuvWeb.CardDav.Xml` | building `multistatus` documents and reading request bodies |
| `VutuvWeb.Plug.CardDavAuth` | HTTP Basic with a personal access token |

## Which contacts

`users.carddav_sharing` is one of four levels, `"off"` for everybody until they
choose otherwise on `/settings/carddav`. What it publishes is *other people's*
contact details, so there is deliberately no installation-wide default an admin
could flip: the column carries a plain `NOT NULL DEFAULT 'off'` rather than
being a `Vutuv.Prefs` knob.

| Level | Publishes |
|---|---|
| `off` | nothing; the whole collection 401s |
| `personally_known` | follows the member ticked "personally known" |
| `mutual` | follows that come back — what the site calls *vernetzt* |
| `following` | every member they follow |

The levels contain each other, which is why the settings page offers **one
choice of four** rather than three checkboxes: ticking "everybody I follow"
alongside "personally known" says nothing the first one does not.

Organization pages never appear — an address book is people. Neither do
accounts moderation has hidden, or unconfirmed ones: the query applies the same
gate the public follow lists do (`account_confirmed_row/1`,
`account_hidden_row/1`).

## And whose card may be carried

`users.carddav_visibility` is the mirror image, and the half that is the
member's **own** data. It lives with the rest of their visibility settings on
`/settings/privacy`, not on the address-book page — that page decides whose
cards you collect, this decides whether yours may be collected.

| Level | Who may keep this member's card |
|---|---|
| `followers` | anybody who follows them — **the default** |
| `mutual` | only people they follow back |
| `nobody` | the deliberate opt-out |

Generous by default, unlike `carddav_sharing`, and for the opposite reason:
what travels is the anonymous public view of a profile every visitor already
sees, while a book that stays empty until each contact has opted in
individually is not a book. Only-opt-in would make the feature unusable.

**It outranks the subscriber's setting**, and that ordering is the whole point:
whoever the data is about decides. A member set to `"nobody"` is absent from
every book, however wide a subscriber opened theirs and whatever they marked —
a "personally known" tick cannot mark its way past somebody else's opt-out. One
predicate in `filter_visibility/2` carries both cases, so there is a single
place this rule lives.

### And the one-off download

`users.vcard_download` answers the same question for the `.vcf` button on the
profile: `everyone` (the default), `followers`, `nobody`. It exists because
`carddav_visibility` is half a promise without it — withdrawing from every
address book while a one-click download sits on the page withdraws nothing.

**Two settings and not one, because the difference is what you can undo.** A
subscription is convenient, stays current, and is ours to end: one click and
the card is gone from every device. A download is manual, one profile at a
time, and it is a **snapshot** — it never updates, it does not know the member
changed their mind, and switching this off later removes the button, not the
copies somebody already has. The comfortable option is the revocable one; the
laborious one is the permanent one. Members deserve to be told which is which,
and the settings page says it in as many words rather than implying otherwise.

That asymmetry is also why the levels differ.
`everyone` is the default and is exactly today's behaviour, an anonymous public
download; defaulting to anything narrower would quietly remove a public
affordance from every member who never asked.

The gate is one line in `UserController.show/2`: dropping `:vcf` from the
`allowed` list `AgentDocs.respond/2` is given. That stops `negotiate/2`
offering it, stops `put_html_alternates/2` advertising it in the head and the
`Link` header, and turns a bare `/:slug.vcf` into the plain 404 the endpoint's
`AgentFormat` guard gives every unhandled extension. One list, three surfaces,
nothing to keep in sync by hand — and the profile's own button and formats card
read the same verdict from `@vcard_download?`, so a link that would 404 is
never rendered.

**A direction worth considering: retiring the download entirely.** If the point
is that the member keeps control of their own details, CardDAV is the only
shape that delivers it — the card stays current and can be withdrawn — while a
download hands out a copy that is gone the moment it is saved. Anybody who
wants a permanent local contact can still make one: copy it into the phone's
own address book, which is a deliberate act by the person keeping it rather
than a button we offer. That would remove `users.vcard_download`, this section
and the `:vcf` format, and it is a decision for the milestone that owns member
control, not a change to make in passing. Recorded on issue #1705.

The default costs nothing: with `everyone` the answer does not depend on the
viewer, so the public `.vcf` stays the identical, cache-safe response it always
was. Only a member who narrows it makes their profile answer per viewer, which
is what they asked for. `VutuvWeb.ContentPolicy` owns the rule, beside the
other question about what a profile hands to whom.

**A subscription is the half we can take back**, and that is why this one can
afford to be generous: narrow or withdraw it and the card leaves every book on
the next sync, within minutes, with nobody doing anything. The tombstone
machinery below is what makes that a fact rather than a hope, and a real iPhone
has been watched doing it.

The `.vcf` download is the other half, and it is the irreversible one — see
below.

## The two private marks

`follows.personally_known` (boolean) and `follows.note` (text) belong to the
**follower**. Nobody else ever sees either: they are not rendered on the
followee's profile, not notified, not counted. Both are set on the profile —
the mark in the ⋯ menu, the note in a card only its author can see — and both
travel through `Vutuv.Social.set_follow_marks/3` and
`Follow.marks_changeset/2`.

Two fields rather than one, because they answer different questions. A note
saying "answers fast, ask about the Elixir job" is not a claim to have met
somebody, and the `personally_known` level keys on the flag alone.

The note rides into the card as vCard `NOTE:` — the one property of a card that
belongs to its reader rather than its subject.

## What a card contains

Exactly the **anonymous public view** the profile already serves to any
visitor, rendered by the same builder and the same renderer as the `.vcf`
download on a profile page:

```
Vutuv.CardDav.render_card/2
  → VutuvWeb.AgentDocs.ProfileDoc.build(contact, contact_only: true, emails: …)
  → VutuvWeb.AgentDocs.VCard.render(doc, uid: …, note: …, rev: …)
```

`contact_only: true` skips the four slices a contact card never shows — the
timeline, the header counts, the code-forge snapshots, the job-search
visibility lookup — because the sync renders every published card on every
poll. The whole book's profile associations and public email addresses are
preloaded in bulk first, so `build/2` itself touches the database no further.

The `agent_docs_blocked?/1` opt-out does **not** apply, for the same reason the
`.vcf` format is already exempt from it: a contact card is an exchange between
people, not agent food.

Three things ride along that a one-off download has no use for, all of them
options on the renderer so the download's bytes are unchanged:

- **`UID`** (`urn:uuid:<member id>`) — without it every sync duplicates the
  contact instead of updating it.
- **`NOTE`** — the follower's own.
- **`REV`** — the moment the card last actually changed. The plain renderer
  fills REV with "now", which is right for a download and would make every card
  look changed on every poll here.

## Synchronisation, and why anything is stored

A phone asks "what changed since token N?" and expects three answers: added,
changed, **gone**. The first two are derivable from live data; the third is
not — once a follow is dropped there is nothing left to report. So the set a
member last handed out lives in `carddav_cards`:

| Column | Meaning |
|---|---|
| `user_id` | the subscriber whose book this is |
| `contact_id` | the member the card is about |
| `etag` | hash of the rendered card |
| `revision` | `users.carddav_revision` when this row last changed |
| `deleted` | the tombstone |

`Vutuv.CardDav.refresh/1` (via `snapshot/1`, which every request uses)
recomputes the qualifying set, hashes each card, and writes only what moved —
bumping `users.carddav_revision` once, in a single `UPDATE … SET
carddav_revision = carddav_revision + 1 RETURNING`, so two clients
synchronising at the same moment cannot mint the same number. **Nothing is
written when nothing changed**, which is the common case on a poll and keeps
every client's token valid.

The sync token is `urn:vutuv:carddav:<revision>`; a token in any other
vocabulary is refused with `403 valid-sync-token` rather than guessed at, and
the client starts over.

A contact who stops qualifying — unfollowed, mark removed, blocked, suspended,
account deleted, level narrowed — comes back in the next sync report as a bare
`404` on their href, which is what deletes the card on the device. **That
propagation is the feature, not a detail**: it is the half that protects the
people *in* the address book, and it is what makes "the card is withdrawn" a
true statement rather than a hope.

This runs on request rather than in a sweeper. A sweeper would have to walk
every member on a schedule to keep an answer nobody is asking for; the client
polling us is the exact moment the answer is wanted. (It also sidesteps the
standing sweeper trap in CLAUDE.md entirely — there is no "least recently
done" clock to forget to advance.)

### What a card carries, and how it is labelled

A vutuv label is not a vCard type, and a Contacts app that meets a word it does
not know files the value under no label at all. So `VutuvWeb.AgentDocs.VCard`
translates rather than passes through: the private/work x landline/mobile
matrix of `PhoneNumber.number_types/0` becomes `HOME` / `CELL` / `WORK` /
`FAX`, and "Work Cell" — the one label with no single registered token —
becomes the **pair** `WORK,CELL`. That pair is why the type cannot go through
`sanitize/1`, which escapes the comma and would turn two real types into one
made-up one. `Personal` / `Work` emails become `INTERNET,HOME` /
`INTERNET,WORK`; anything unrecognised degrades to the RFC's own defaults
(`VOICE`, bare `INTERNET`) rather than travelling as an invalid parameter.

The **photo** is the 192px `:medium` avatar, not the 96px `:thumb` a list uses:
this is the picture a phone paints across the screen when the person calls.
(`Avatar.binary/2` matches a `{:crop, w, h, gravity}` version, so `:large` is
not available to it.) At that size the base64 runs to kilobytes on a property
whose unit is one line, so it is **folded** — RFC 2426 s2.6, a line break plus
one space, which every parser unfolds again. Only the photo is folded, and only
because base64 is ASCII: octet-counting cannot cut a character in half there.

### What one card costs

A request about **one** card goes through `CardDav.entry/2`, which narrows the
same `follow_query/2` to that contact — not through `snapshot/1`, which
refreshes and renders the whole book. macOS Contacts and Thunderbird fetch
cards one at a time, so the collection-wide path made an N-card book cost N²
renders per sync, invisibly, because every individual answer was correct
(measured: 43k / 92k / 307k reductions for a book of 1 / 16 / 64 contacts,
against a flat ~21k now).

It writes nothing. The stored row is read for `getlastmodified` and never
refreshed, so a GET no longer mutates state, and the ETag is hashed from the
very entry the body is rendered from — the two agree even when the stored row
has gone stale. A `sync-collection` report likewise takes `book/1` rather than
`snapshot/1`: it answers from `changes_since/2` and has no use for the card
rows, which is one query saved on the single most frequent request here.

**The photo is memoized, keyed by its own content — inside `Vutuv.Avatar`, not
here.** `Avatar.binary/2` does not read a derived file: it opens the *original*
and runs the whole libvips pipeline, so a 300-card book was 300 image pipelines,
repeated on every sync that touched the cards. The memo sits in that function
rather than at this call site so every caller gets it and no future one has to
remember — the CV asked for the very same `:medium` picture and paid full price
while the vCard did not. The key is `{user_id, version, avatar_fingerprint}`;
the fingerprint is the sha256 of the original (crop folded in), so a changed
picture is a different key and nothing stale can be served, and a row without
one is never remembered. Moderation needs no place in the key because
`binary/2`'s own clause answers a pending picture with the placeholder first.
`Vutuv.Uploads.AvatarCache` is only the table: no TTL (a content-addressed
entry is never stale), bounded by entry count at roughly 16 MB of refcounted
binary, emptied rather than evicted — a miss costs one pipeline, never a wrong
answer.

### The ETag and the photo

The ETag hashes the card rendered **without** the photo, plus
`users.avatar_fingerprint` — which is already the sha256 of the original image.
A changed picture therefore changes the ETag without every sync reading and
base64-ing every avatar on disk. REV is pinned to a constant while hashing, or
the hash would change on every render and defeat its own purpose.

## Authentication

HTTP Basic, with a **personal access token as the password** and the account
password never. A CardDAV client stores what it is given, on the device,
forever — that is how the protocol works — so what it is given must be
revocable on its own. The token needs the `contacts:read` scope
(`Vutuv.ApiAuth.Scopes`), is minted at `/access_tokens/new`, and is verified by
the same `Vutuv.ApiAuth.verify_token/1` the JSON API uses, so revoking it stops
the phone on its next poll.

The **username field is not checked**. Every client insists on one, so the
settings page tells members to type their handle, but the token is the whole
credential: comparing a stored handle against a member who has since renamed
would break every device at once for no security gained. For the same reason
the URLs carry member **ids**, not handles.

Switching the level to `off` closes the collection immediately, token or no
token: the setting is the gate, and a token minted before that decision must
not outlive it.

### Why not OAuth 2

Because no CardDAV client can use it. CardDAV rides on HTTP and inherits
whatever HTTP authentication a client implements, and for a *generic* CardDAV
account that is Basic (and Digest). iOS and macOS Contacts offer no OAuth flow
when you add "Other → CardDAV account"; Thunderbird and DAVx⁵ do OAuth only for
a hard-coded list of providers (Google and friends), not by discovery against
an arbitrary server. There is an IETF draft for bearer tokens over DAV and no
client that speaks it.

So a long-lived, per-device, revocable credential handed over Basic is not a
shortcut here — it is what every self-hosted and hosted CardDAV service does,
Apple's own iCloud included (an "app-specific password" is exactly this). We
mint ours as a PAT so it is scoped (`contacts:read` and nothing else), listed,
dated (`last_used_at`) and revocable one device at a time at `/access_tokens`,
which is the connected-devices view for CardDAV.

An OAuth **access token** works too, since both live in `api_tokens` and go
through the same `verify_token/1` — an app granted `contacts:read` can read the
book. Nothing in a Contacts app will ever obtain one, but the API side of the
scope is consistent.

The one rough edge is expiry: a PAT expires (30 / 90 / 365 days), and a device
whose token ran out simply stops syncing. The settings page therefore says so
and tells members to name a token after its device and give it a year.

## What the protocol says, and what it cannot

CardDAV is RFC 6352. There is one version of it — what is versioned is the
payload, and vutuv renders vCard 3.0 (RFC 2426), which CardDAV mandates and
every client reads. vCard 4.0 (RFC 6350) is deliberately **not** advertised in
`supported-address-data`: announcing a format we do not produce is a lie a
client acts on. Adding a 4.0 renderer is the obvious follow-up.

**Read-only is said in the protocol, not only in the docs.**
`current-user-privilege-set` (RFC 3744) advertises `DAV:read` alone, which is
what makes macOS Contacts grey the account out rather than let a member type
into a card that will bounce; every write method answers `403` with
`need-privileges` behind it. Per-property write is not something CardDAV can
express — its unit is the whole card — so a writable `NOTE` would mean taking a
client's `PUT`, keeping one property and silently discarding the rest of its
edits. Notes are edited on vutuv.

**No protocol mechanism can stop a copy.** Nothing in CardDAV forbids a client
from duplicating a card into another account, exporting it, or including it in
a device backup. A read-only account keeps the contacts in vutuv's own account
store rather than in iCloud, but that is client behaviour we rely on, not a
guarantee we can enforce. Deletion propagation is the lever we actually hold,
and the settings page says so in as many words.

### Implemented

| Request | Path |
|---|---|
| `GET`/`PROPFIND` `/.well-known/carddav` | RFC 6764 discovery, unauthenticated → 301 to `/system/carddav/` |
| `OPTIONS` | `DAV: 1, 3, addressbook` |
| `PROPFIND` | service → principal → home → collection → card |
| `REPORT sync-collection` | RFC 6578, with tombstones |
| `REPORT addressbook-multiget` | fetch these cards |
| `REPORT addressbook-query` | see below |
| `GET` on a card | vCard + `ETag` |

`addressbook-query` answers with the **whole collection** rather than
evaluating the filter. Clients use that report to search, and a superset is an
answer they can filter themselves while a wrong subset is not; the two reports
that carry the synchronisation are exact.

Request bodies are read with patterns, **not** with an XML parser. The bodies
are tiny and fixed in shape, while handing attacker-controlled XML to `:xmerl`
is how a server acquires an XXE hole — "read this file for me" is not a feature
an address book needs. The cost is namespace precision: an element is matched
by local name with any prefix.

### Discovery, and what an iPhone actually does

Three URLs answer the service document, and the reasons are worth keeping.

`GET /.well-known/carddav` (RFC 6764) is a **301** to `/system/carddav/` — the
code the spec asks for, for a browser or a curious human.

`PROPFIND /.well-known/carddav` is **not redirected**. A 301 there looks
correct and breaks iOS: it follows the redirect, meets the 401 challenge at the
*redirected* location, gives up rather than retrying there, falls back to
probing `/` and `/principals/`, and reports "CardDAV account verification
failed". So the challenge and the answer both sit at the URL the client asked
about, with no redirect in the authentication path.

`PROPFIND /` — the site root — answers the same document. A CardDAV account's
"server" is a bare host name, so its account URL is `https://<host>/`, and that
is the first thing iOS asks. `PROPFIND` is a method no page of this site has
any other use for, so this costs nothing and the website's own `GET /` is
untouched.

All three were established against real Apple clients on 2026-08-26, where the
first two behaviours are what stood between a working account and that error
message.

### Apple will not send a password in the clear

The one that cost the most to find, because it looks like everything else:
**iOS and macOS Contacts do not answer an HTTP Basic challenge over an
unencrypted connection.** They ask, they are told how to authenticate, and they
say nothing further — the account reports "verification failed" while the
server log shows a wall of 401s and not one `Authorization` header. There is no
error and no prompt, on the phone or in the log.

So a development server on `http://` cannot be tested with an Apple client at
all, whatever the specification allows. `scripts/e2e/tunnel.sh` exists for
exactly this: it puts the checkout behind a Cloudflare Quick Tunnel with a real
certificate, and the same iPhone that had refused for hours authenticated on
the first attempt.

### What a real iPhone actually walks

Verified 2026-08-26 against iOS 27 (`dataaccessd/1.0`) through that tunnel, from
the recorded traffic:

```
OPTIONS  /system/carddav/p/<owner>/            → 200
PROPFIND /system/carddav/p/<owner>/            → 207   principal
PROPFIND /system/carddav/a/<owner>/            → 207   home
PROPFIND /system/carddav/a/<owner>/contacts/   → 207   the collection
REPORT   /system/carddav/a/<owner>/contacts/   → 207   the cards
```

The card arrived with its `UID`, its `NOTE` and the contact's phone number, and
the account showed as read-only. Then the member unfollowed, and the next sync
report carried the tombstone — a bare `404` on the card's href, acknowledged
with the new sync token — and the contact left the phone with nobody touching
it. That is the whole feature, proven on a device.

The iOS **Simulator** cannot show any of this: it runs the account setup in
Settings, so verification requests do arrive, but it never drives the sync
itself. Only a device does.

Two things iOS asks for that we do not answer (they come back `404` per
property, which it accepts): `me-card`, `max-image-size`, `quota-*`,
`add-member`, `bulk-requests`, `resource-id`, `principal-collection-set`,
`email-address-set` — and `push-transports` / `pushkey`, which is Apple's own
push extension and the one we cannot serve (see the push section).

The other half of "just type the host name" is a DNS SRV record
(`_carddavs._tcp`), which every client tries *before* the well-known URL. It is
the operator's to add and entirely optional — see [ADMINS.md](../ADMINS.md).

### Routing notes

The collection lives under `/system/carddav/`, so it burns no root path word
(profiles own the URL root). A card's URL ends in the bare contact id with **no
`.vcf`**: the endpoint's `VutuvWeb.Plug.AgentFormat` strips that extension off
every GET path before the router sees it, and its guard would then 404 the
response for not being an agent document.

## Push (WebDAV-Push)

CardDAV itself has no push: a client polls `getctag` / `sync-collection` and
that is the whole freshness contract. Two extensions add one, and only one of
them is ours to build.

**Apple's** (`push-transports` in the calendarserver namespace) carries the
message over APNS and is what iOS and macOS Contacts honour. It needs a push
certificate issued by Apple for the CalDAV/CardDAV topic, which was only ever
obtainable through Apple's retired Server.app provisioning — no third-party
server can get one, and an installation somebody else runs would need its own.
**An iPhone therefore stays on polling**, however much push we serve.

**WebDAV-Push** (the DAVx⁵ draft, namespace `https://bitfire.at/webdav-push`)
carries it over ordinary Web Push, which needs nobody's permission: VAPID is
self-signed, and `Vutuv.MastodonApi.WebPush` already derives this
installation's key pair from `secret_key_base`. That is what is implemented
here. DAVx⁵ speaks it today; Apple's clients do not.

### The shape of it

The collection advertises three properties, and only while Web Push is on — a
client is never told about a transport whose registration would be refused:

| Property | Carries |
|---|---|
| `transports` | `web-push`, with this installation's VAPID public key |
| `topic` | an opaque, stable id for the collection (HMAC of the member id under a `secret_key_base` pepper, so it is not a bare hash of a partly-timestamp UUID) |
| `supported-triggers` | `content-update` at depth 1, and nothing else — a read-only collection's own properties do not change under a member |

A device `POST`s a `push-register` document to the collection and gets `201`
with the `Location` of its registration and the `Expires` we actually granted
(its request is capped at `push_max_expiry_days/0`, defaulted when absent).
It `DELETE`s that URL to unregister. Refusals speak the draft's vocabulary
rather than a bare 4xx: `push-not-available`, `no-supported-trigger`,
`invalid-subscription`.

When the book moves, the member's devices get one small XML document —
`<push-message>` with the topic and the new sync token — inside the Web Push
encryption, so the push service never reads it. The device then runs the
`sync-collection` it would otherwise have run on a timer.

The endpoint a device registers is a URL this server will POST to, so it
carries the same SSRF pair as every other stored-then-fetched URL here: the
cheap literal check in `Vutuv.CardDav.PushSubscription`'s changeset, and the
resolving check `WebPush` runs again at send time.

### The one place this design pays a background cost

`Vutuv.CardDav.PushSweeper` runs every two minutes over the least recently
checked registrations, calls `refresh/1` for each owner, and pushes the ones
whose revision moved.

A pass takes only registrations it has not checked within
`CardDav.push_check_interval_ms/0` — one number that `PushSweeper`'s timer
reads too, since a threshold that drifted from the sweep interval would halve
the push rate — and it groups them by owner, so a member with a phone, a tablet
and a laptop pays for one refresh rather than three. Without the threshold every
pass took every registration, so a second sweeper (another node, a manual run)
simply doubled the work of re-rendering every book.

A sweeper, in a module that otherwise deliberately computes on request, because
push inverts the question: the server has to notice a change with nobody
asking. The member's own actions could be hooked. The case that matters cannot:
a *contact* changes their phone number, and that must reach the device without
the member touching anything. Detecting that by hooks would mean a write path
on every profile section — a dozen places to remember forever — while
recomputing the book is one place that cannot go stale.

The cost is one card render per contact per pass, per member holding a
registration, and two things bound it. The doc builder has a **contact mode**
(`ProfileDoc.preload(user, true)` plus `timeline_sections/2`) that loads and
builds only what the vCard reads — five associations it used to load and the
card never renders, one of them a `GROUP BY` aggregate over endorsements; a
30-contact refresh went from 16 queries to 11. What remains measures a few
milliseconds of scheduler work per member per pass, which is why there is no
change detector in front of `refresh/1`: the alternatives are hooking every
profile write path or comparing an aggregate over every table the card reads,
and neither is worth that price today. If it ever is, the shape is a per-owner
generation held in the sweeper's own state and compared before the refresh —
never in the request path, so a missed probe can only delay a push, never serve
a stale card.

`checked_at` is stamped on **every** outcome, including the passes that send
nothing — it is the scheduler's clock, not a claim that work happened, and an
oldest-first batch whose unworkable rows never leave the front is the deadlock
CLAUDE.md describes. Only a *successful* push advances `last_revision`, so a
failed one is retried next pass. A push service answering 404/410 takes the
registration with it; anything else is bounded by the expiry.

`config :vutuv, :carddav_push_sweeping` gates the child (off in tests, which
call `push_due/1` directly inside the SQL sandbox), and a pass is a no-op while
either `:carddav_enabled` or Web Push is off.

## The member-facing guide

`/system/carddav` (`priv/help/carddav_{de,en,it}.md`, served by
`VutuvWeb.HelpController`) walks a member through it: switching a level on,
minting the token, the iPhone screens with pictures, the Mac, DAVx⁵ on Android,
what lands on the phone and what does not, and how to withdraw again. The server
address is `{{host}}`, filled in at render time — an installation is not
vutuv.de, and a guide that says otherwise is wrong everywhere else.

The screenshots live in `priv/static/images/help/carddav/` and were taken from
the iOS Simulator in German. English and Italian reuse them with a line saying
so: the screens are identical, and three sets of the same pictures would be
three sets to keep current.

## Installation switch

`config :vutuv, :carddav_enabled` (env `CARDDAV_ENABLED=false`) turns the whole
thing into 404s. It is on by default and makes no outbound calls at all, so an
intranet installation can keep the address book while switching federation off.
See [ADMINS.md](../ADMINS.md).
