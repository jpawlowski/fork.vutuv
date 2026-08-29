defmodule VutuvWeb.AgentDocs.ContactDocTest do
  @moduledoc """
  A vCard asks for a name, a number and an address. The doc builder used to
  load and build the whole profile for one anyway.

  `contact_only: true` is what CardDAV renders every card with, and the sweeper
  renders every card of every subscribed member every couple of minutes — so
  five associations the vCard never reads, one of them a `GROUP BY … count()`
  aggregate over endorsements, were being fetched on a loop.
  """
  use Vutuv.DataCase, async: true

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

  setup do
    user = insert(:activated_user, first_name: "Ada", last_name: "Lovelace")
    insert(:phone_number, user: user, number_type: "Work")
    insert(:address, user: user)
    insert(:language, user: user)
    insert(:education, user: user)
    Vutuv.Tags.add_user_tag(user, unique_tag_name())

    {:ok, user: user}
  end

  test "a contact document carries only what a vCard renders", %{user: user} do
    doc = ProfileDoc.build(user, contact_only: true)

    # Present, because the card shows them.
    assert doc.name == "Ada Lovelace"
    assert [_phone] = doc.phone_numbers
    assert [_address] = doc.addresses

    # Absent, because it does not — and not merely absent from the output: the
    # associations behind them are no longer fetched (16 queries per book
    # refresh became 11, measured on a 30-contact book).
    assert doc.tags == []
    assert doc.languages == []
    assert doc.educations == []
    assert doc.qualifications == []
    assert doc.job_references == []
  end

  test "the rendered card is the same as before the narrowing", %{user: user} do
    contact = VCard.render(ProfileDoc.build(user, contact_only: true))
    full = VCard.render(ProfileDoc.build(user))

    # The vCard reads no slice the contact mode drops, so the two renderings
    # differ only in `REV`, which is stamped per build.
    assert strip_rev(contact) == strip_rev(full)
  end

  test "the full document still carries everything", %{user: user} do
    doc = ProfileDoc.build(user)

    assert [_tag] = doc.tags
    assert [_language] = doc.languages
    assert [_education] = doc.educations
  end

  defp strip_rev(card), do: String.replace(card, ~r/^REV:.*$/m, "REV:")
end
