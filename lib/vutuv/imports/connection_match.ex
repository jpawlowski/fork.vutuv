defmodule Vutuv.Imports.ConnectionMatch do
  @moduledoc """
  Which vutuv members a member's LinkedIn contact list resolves to (issue #1476).

  It takes the contacts `Vutuv.Imports.LinkedIn.parse_connections/2` reduced the
  archive to and answers with vutuv members — nothing else is kept, nothing is
  written, and the contact list itself never reaches the database as data.

  **Exact identifiers only**, two of them:

    * `:email` — a contact's address equals one of a member's addresses.
    * `:linkedin` — a contact's LinkedIn profile identifier equals the LinkedIn
      account a member links from their profile.

  There is deliberately no name / employer / position matching. A guess in a
  "people you already know" list is not neutral: acting on it means following
  the wrong person, publicly, and telling them so.

  ## Why the email half asks about the audience, not the address

  An address matches only if it is visible **to this member** — the rule of
  `Vutuv.Accounts.contact_visible/2`, the same one their profile page resolves
  through (issue #1521). So this discloses nothing they could not have read by
  opening the profile of everyone they uploaded, one by one; it only saves them
  from doing that. A private address stays unmatched and therefore unconfirmed,
  which is the line that matters: *a private address must not even confirm that
  an account exists.*

  Note what this deliberately does not do: it does not fall back to the widest
  rung "because it is a bulk question". A member who opened their address to
  signed-in members expects to be found by them, and being found by a contact
  who already has the address in their own address book is the least surprising
  form of that.

  The consequence is honest and worth knowing: only a part of the member base
  can be matched this way at all, and which part depends on what each of them
  chose.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1, account_hidden_row: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo
  alias Vutuv.Social

  # An archive may carry tens of thousands of contacts, so the identifier lists
  # go to Postgres in bounded chunks rather than as one enormous IN list.
  @chunk 500

  @doc """
  The members `contacts` resolves to, as `%{user: %User{}, via: :email | :linkedin}`,
  sorted by name.

  `viewer` is excluded (a member is not their own contact), as is anybody either
  side has blocked. Members the viewer already follows stay in — the page shows
  that state rather than pretending they are new, and hiding them would make a
  second run of the same archive look as if people had vanished.
  """
  def find(%User{} = viewer, contacts) when is_list(contacts) do
    emails = identifiers(contacts, :email)
    linkedin = identifiers(contacts, :linkedin)

    if emails == [] and linkedin == [] do
      []
    else
      blocked = Social.blocked_user_ids(viewer.id)

      # Email first, so `uniq_by` keeps that label for a member matched by both:
      # an address is the stronger evidence, and the one the member can check.
      (tag(users_by_email(emails, viewer), :email) ++ tag(users_by_linkedin(linkedin), :linkedin))
      |> Enum.uniq_by(& &1.user.id)
      |> Enum.reject(&excluded?(&1, viewer, blocked))
      |> Enum.sort_by(&sort_key/1)
    end
  end

  defp identifiers(contacts, key) do
    contacts |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp tag(users, via), do: Enum.map(users, &%{user: &1, via: via})

  defp excluded?(%{user: user}, viewer, blocked) do
    user.id == viewer.id or MapSet.member?(blocked, user.id)
  end

  defp sort_key(%{user: user}) do
    {downcase(user.last_name), downcase(user.first_name)}
  end

  defp downcase(nil), do: ""
  defp downcase(value), do: String.downcase(value)

  defp users_by_email([], _viewer), do: []

  defp users_by_email(values, viewer) do
    audience = Accounts.contact_visible(viewer, :email)

    in_chunks(values, fn chunk ->
      from(u in User,
        join: e in assoc(u, :emails),
        as: :contact,
        where: e.value in ^chunk,
        where: account_confirmed_row(u) and not account_hidden_row(u),
        distinct: u.id
      )
      |> where(^audience)
    end)
  end

  defp users_by_linkedin([]), do: []

  defp users_by_linkedin(ids) do
    in_chunks(ids, fn chunk ->
      from(u in User,
        join: s in SocialMediaAccount,
        on: s.user_id == u.id,
        # The stored value is the bare handle (SocialMediaAccount.parse_value/1
        # collapses a pasted URL to its last segment), and a handle is
        # case-insensitive, so both sides are lowered before they meet.
        where: s.provider == "LinkedIn" and fragment("lower(?)", s.value) in ^chunk,
        where: account_confirmed_row(u) and not account_hidden_row(u),
        distinct: u.id
      )
    end)
  end

  defp in_chunks(values, build_query) do
    values
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(&Repo.all(build_query.(&1)))
  end
end
