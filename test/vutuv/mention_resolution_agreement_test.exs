defmodule Vutuv.MentionResolutionAgreementTest do
  @moduledoc """
  The composer's chip and the rendered mention link must answer the SAME
  question (issue #1748).

  The chip is a promise: it says "this handle will be a link". That promise is
  only true while `Mentions.check_handles/1` — what `/system/mentions/check`
  answers — and `VutuvWeb.Markdown`, which actually writes the `<a>`, agree
  about which handles resolve. They agree today because both go through
  `Mentions.resolvable_handles/1`; this pins that, so a third account kind, a
  changed visibility gate or a hand-rolled lookup at either call site fails
  here instead of shipping a chip that promises a link nobody writes.

  Asserted as an equivalence rather than two separate expectations, so drift in
  EITHER direction is a failure: a chip without a link is the lie, a link
  without a chip is the quiet loss.

  Calibrated against a real divergence, not a copy: re-implementing
  `mention_targets/1` with the *same* rule leaves this green (it is the same
  answer, spelled twice), so the useful check is to change one side's gate —
  resolving pages in the renderer without `organization_public_row` makes the
  hidden-page case below fail with "the renderer disagrees for @acmehidden".
  That is the failure this file exists to produce.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Mentions

  # What the composer would draw: does `check` call this handle resolvable?
  defp chipped?(handle) do
    {_checked, resolved} = Mentions.check_handles([handle])
    MapSet.member?(resolved, handle)
  end

  # What the reader would get: does the renderer turn it into a mention link?
  defp linked?(handle) do
    "hallo @#{handle}"
    |> VutuvWeb.Markdown.render()
    |> Phoenix.HTML.safe_to_string()
    |> String.contains?(~s(class="mention"))
  end

  defp assert_agree(handle, expected) do
    assert chipped?(handle) == expected,
           "check_handles/1 disagrees for @#{handle}: expected #{expected}"

    assert linked?(handle) == expected,
           "the renderer disagrees for @#{handle}: expected #{expected}"
  end

  test "a member's handle both chips and links" do
    insert(:activated_user, username: "adalovelace")
    assert_agree("adalovelace", true)
  end

  test "a handle nobody holds neither chips nor links" do
    assert_agree("ghostwriter", false)
  end

  test "a publicly visible page both chips and links" do
    insert(:organization, username: "acmegmbh", name: "Acme GmbH")
    assert_agree("acmegmbh", true)
  end

  # The case that decides which question the chip is really asking. A page
  # nobody may see HOLDS its handle — `Mentions.unknown_handles/1` accepts it
  # and the post saves — but the renderer leaves it as text, so the chip must
  # stay away too. Answering the save's question here instead would put a chip
  # on a mention that never becomes a link.
  test "a page nobody may see neither chips nor links, though the save takes it" do
    insert(:organization, username: "acmehidden", name: "Acme Hidden", status: "pending")

    assert_agree("acmehidden", false)
    assert Mentions.unknown_handles("hallo @acmehidden") == []
  end
end
