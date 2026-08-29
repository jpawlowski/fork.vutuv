# Getting contacts onto your phone (CardDAV)

A business network is an address book too. The people you follow here can sit in
the Contacts app on your phone — with their photo, phone number and address —
and stay up to date without you doing anything.

That is what CardDAV is for, a standard iPhone, iPad, Mac and Android all speak.
You set it up once and then it runs.

It is off until you switch it on.

## Switching it on

Open **Settings → Address book (CardDAV)** and pick whose cards go to your
devices:

* **Everybody I follow**
* **People I follow who follow me back** — what vutuv calls *connected*
* **Only people I marked as personally known**

Each level says how many contacts it covers. You mark somebody as personally
known in the ⋯ menu on their profile, where you also write a private note about
them — only you see it, and it travels to your phone as the contact's note.

## An access token instead of your password

Your phone stores the password for good — that is how CardDAV works. So do
**not** give it your vutuv password. Give it a token that may do this one thing
and that you can revoke on its own.

Create one under **Settings → Apps & API → Access tokens → Create**. Three
things matter:

* Tick the **contacts** permission. Nothing else is needed.
* Name the token **after the device** — "iPhone", "iPad at the office". The list
  then shows you which device last synced and when, and you can revoke exactly
  that one.
* Give it **a year**. When a token expires the device asks for a new password
  instead of syncing.

The token is shown to you **once**. Copy it before you leave the page.

## On an iPhone or iPad

Open **Settings → Apps → Contacts** and tap *Add Account*.

![The Contacts settings with "Add Account"](/images/help/carddav/01-kontakte.avif)

iOS asks for an email address first. We do not need one — tap
**"choose from a list"** underneath.

![The hint pointing at the provider list](/images/help/carddav/02-anbieter-liste.avif)

At the very bottom of the list sits **CardDAV Account**.

![The provider list with the CardDAV Account entry](/images/help/carddav/03-carddav-account.avif)

Now three fields:

![The filled-in form](/images/help/carddav/04-zugangsdaten.avif)

* **Server:** `{{host}}`
* **User Name:** your username here
* **Password:** the access token from above

That is all — no `https://`, no path, no port, and nothing to change under
*Advanced Settings*. Tap **Done**.

A few seconds later the contacts are in the Contacts app, as their own group,
separate from your private ones.

*(The screenshots show the German interface; the screens are the same.)*

## On a Mac

**Contacts → Settings → Accounts → +** → *Other Contacts Account…* →
**CardDAV**, account type **Manual**. The same three details as above;
`{{host}}` is enough as the server address.

## On Android

Android ships no CardDAV client of its own. The most widely used one is
**DAVx⁵** — open source, free on F-Droid, a small amount on the Play Store.

After installing: **+ → Login with URL and user name**, then `https://{{host}}`
as the base URL, your username, and the token as the password. DAVx⁵ finds the
address book itself; then switch on syncing for contacts.

DAVx⁵ can also do something Apple's client cannot: it lets us tell it the moment
something changes, instead of asking on a timer. An iPhone keeps asking on its
own schedule — that is Apple's decision and not one we can change.

## What lands on the phone, and what does not

What travels is exactly what the profile already shows every visitor: name,
photo, job title, public phone numbers, public addresses, public email
addresses. **No private entries.**

Plus your own note about that person, if you wrote one. Nobody but you sees it.

The address book is **read-only**. You cannot edit a contact on the phone — the
details belong to the member, and they change them here. Your phone shows the
account as read-only for that reason.

## When somebody drops out

Unfollow somebody, remove their mark, block them, or let them leave vutuv, and
their card is withdrawn: at the next sync your device is told to delete it, and
it does — usually within minutes.

The same happens when somebody decides they no longer want to be in other
people's address books.

## Your own card

You decide the other direction under **Settings → Visibility**: whether others
may keep your card — anybody who follows you, only people you follow back, or
nobody. The widest level is the default, because what travels is only what your
profile already shows publicly.

You can take that back at any time, and it works: your card leaves those address
books at the next sync.

The same page decides about the **vCard download** on your profile. That one is
different: a file, saved once, that never updates again — and that you cannot
take back.

## When it does not work

**"Account verification failed"** — usually the password. You need the access
token, not your vutuv password, and the token needs the *contacts* permission.

**The address book stays empty** — is your level under *Address book (CardDAV)*
still "Off"? And do you actually follow anybody who falls into the level you
picked? The number beside each level tells you.

**It worked and then stopped** — the token has probably expired. Create a new
one and enter it on the device.

**Somebody is missing** — they may have decided not to be in other people's
address books. That is their call, and we respect it.
