defmodule VutuvWeb.ContactVisibilityTest do
  @moduledoc """
  The contact ladder (issue #1521) as every surface answers it: the profile card,
  the public section pages and their single-entry pages, the vCard downloads, the
  crawlable agent formats, the API, the CV and the email search.

  The point of testing them together in one file is that they must agree. The
  failure this feature can actually ship is not "the gate is wrong" — that is
  covered by `Vutuv.VisibilityTest` — but "one of the eleven places that renders
  a phone number forgot to ask", and a number that is hidden on the profile while
  its `.json` sibling still lists it is not hidden at all.

  Stefan's condition on the issue is the `describe "the vCard download"` block: if
  you grant somebody access to your number, the vCard they download has to carry
  it.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Accounts.Email
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Repo
  alias Vutuv.Search
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard
  alias VutuvWeb.CV
  alias VutuvWeb.UserHelpers

  @public_number "+49 30 1110001"
  @members_number "+49 30 2220002"
  @connected_number "+49 30 3330003"
  @private_number "+49 30 4440004"

  # An owner with one number on each rung of the ladder, plus a member who is
  # vernetzt with them (mutual follow) and a signed-in stranger.
  defp ladder_fixture do
    owner = signed_up_member()
    contact = signed_up_member()
    stranger = signed_up_member()

    insert(:follow, follower: owner, followee: contact)
    insert(:follow, follower: contact, followee: owner)

    for {value, level} <- [
          {@public_number, "everyone"},
          {@members_number, "members"},
          {@connected_number, "connected"},
          {@private_number, "private"}
        ] do
      insert(:phone_number, user: owner, value: value, visibility: level)
    end

    # One postal address per rung too (issue #1521 extended the ladder to all
    # three contact channels), each recognisable by its street line.
    for {line, level} <- [
          {"Offenstraße 1", "everyone"},
          {"Mitgliederweg 2", "members"},
          {"Vernetztgasse 3", "connected"},
          {"Privatpfad 4", "private"}
        ] do
      insert(:address, user: owner, line_1: line, city: "Koblenz", visibility: level)
    end

    %{owner: owner, contact: contact, stranger: stranger}
  end

  # A member who can actually sign in: an activated account with one confirmed
  # address to send the login PIN to. The address is minted per call
  # (`unique_integer`), never a literal, so this async file cannot convoy with
  # another one on the emails unique index.
  defp signed_up_member do
    user = insert(:user, email_confirmed?: true)
    n = System.unique_integer([:positive])
    insert(:email, user: user, value: "ladder#{n}@example.com", visibility: "everyone")
    user
  end

  # Sign the given member in through the real PIN flow. Takes its own fresh conn
  # (with a test session, which `login_by_email/3` needs) so one test can hold
  # several differently-authenticated viewers side by side.
  defp login(user) do
    [email | _] = Repo.all(Ecto.assoc(user, :emails))

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> login_via_pin(email.value)
  end

  describe "the profile contact card" do
    setup do
      ladder_fixture()
    end

    test "a logged-out visitor sees only the public number", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "1110001"
      refute html =~ "2220002"
      refute html =~ "3330003"
      refute html =~ "4440004"
    end

    test "a signed-in stranger also sees the members number", %{owner: owner, stranger: stranger} do
      html = login(stranger) |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "1110001"
      assert html =~ "2220002"
      refute html =~ "3330003"
      refute html =~ "4440004"
    end

    test "a vernetzt contact also sees the connected number, but not the private one",
         %{owner: owner, contact: contact} do
      html = login(contact) |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "1110001"
      assert html =~ "2220002"
      assert html =~ "3330003"
      refute html =~ "4440004"
    end

    test "the restricted rows carry a lock naming their audience, the public one none",
         %{owner: owner, contact: contact} do
      html = login(owner) |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "1110001"

      # The marker names the audience rather than merely saying "restricted".
      assert html =~ ~s(data-phone-visibility="everyone")
      assert html =~ ~s(data-phone-visibility="connected")
      assert html =~ "Only visible to people you are connected with"

      # And the same page shows a vernetzt viewer the connected row with no
      # marker: which rung it sits on is the owner's setting, not a fact about
      # the number.
      seen = login(contact) |> get(~p"/#{owner}") |> html_response(200)
      assert seen =~ ~s(data-phone-visibility="connected")
      refute seen =~ "Only visible to people you are connected with"
    end

    test "the owner's private row shows on the profile, marked as owner-only" do
      # Its own fixture with two numbers, because the card previews only
      # `preview_limit(:phone_numbers)` (3) of them and the ladder fixture's
      # private number is the fourth.
      owner = signed_up_member()
      insert(:phone_number, user: owner, value: "+49 30 7770007", visibility: "everyone")
      insert(:phone_number, user: owner, value: "+49 30 8880008", visibility: "private")

      html = login(owner) |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "8880008"
      assert html =~ ~s(data-phone-visibility="private")
      assert html =~ "Only visible to you"

      # Nobody else gets it, marker or number.
      anon = build_conn() |> get(~p"/#{owner}") |> html_response(200)
      refute anon =~ "8880008"
      assert anon =~ "7770007"
    end

    test "another viewer gets no marker at all — the rung is the owner's business",
         %{owner: owner, contact: contact} do
      html = login(contact) |> get(~p"/#{owner}") |> html_response(200)

      assert html =~ "3330003"
      refute html =~ "Only visible to people you are connected with"
      refute html =~ "opacity-55"
    end
  end

  describe "the public /:slug/phone_numbers page" do
    setup do
      ladder_fixture()
    end

    test "lists what the viewer's rung allows", %{owner: owner, contact: contact} do
      anon = build_conn() |> get(~p"/#{owner}/phone_numbers") |> html_response(200)
      assert anon =~ "1110001"
      refute anon =~ "3330003"

      seen = login(contact) |> get(~p"/#{owner}/phone_numbers") |> html_response(200)
      assert seen =~ "3330003"
    end

    test "never shows a private number, not even to the owner", %{owner: owner} do
      html = login(owner) |> get(~p"/#{owner}/phone_numbers") |> html_response(200)

      # The showcase page is what a visitor of the widest standing can see, so a
      # private row belongs only in /settings/phone_numbers. Otherwise the owner
      # reads a page and cannot tell which half of it anybody else gets.
      refute html =~ "4440004"
      assert html =~ "1110001"
    end

    test "the owner's /settings editor shows every rung", %{owner: owner} do
      html = login(owner) |> get(~p"/settings/phone_numbers") |> html_response(200)

      assert html =~ "4440004"
      assert html =~ "1110001"
    end
  end

  describe "the single-number page" do
    setup do
      ladder_fixture()
    end

    test "404s for a viewer who may not see that number", %{owner: owner, stranger: stranger} do
      number = Repo.get_by!(PhoneNumber, value: @connected_number)

      # A 404 rather than a 403: telling a stranger "you are not allowed to see
      # this" would confirm that the member has such a number on file.
      assert login(stranger)
             |> get(~p"/#{owner}/phone_numbers/#{number}")
             |> html_response(404)
    end

    test "renders for a viewer who may", %{owner: owner, contact: contact} do
      number = Repo.get_by!(PhoneNumber, value: @connected_number)

      html =
        login(contact)
        |> get(~p"/#{owner}/phone_numbers/#{number}")
        |> html_response(200)

      assert html =~ "3330003"
    end

    test "its agent-format sibling stays the anonymous view", %{owner: owner, contact: contact} do
      number = Repo.get_by!(PhoneNumber, value: @connected_number)

      # The `.md`/`.txt`/`.json` URLs are publicly cacheable and crawlable, so
      # they answer the same for everybody — a wider answer for a signed-in
      # viewer could be handed on by a shared cache.
      conn =
        login(contact)
        |> get("/#{owner.username}/phone_numbers/#{number.id}.md")

      assert conn.status == 404
    end
  end

  describe "the crawlable profile formats" do
    setup do
      ladder_fixture()
    end

    test "the .md, .json and .vcf siblings carry only public numbers", %{
      owner: owner,
      contact: contact
    } do
      for ext <- ~w(md txt json xml vcf) do
        body =
          login(contact)
          |> get("/#{owner.username}.#{ext}")
          |> response(200)

        assert body =~ "1110001", "#{ext} lost the public number"
        refute body =~ "3330003", "#{ext} leaked a connections-only number to a cacheable URL"
        refute body =~ "4440004", "#{ext} leaked a private number"
      end
    end
  end

  describe "the vCard download" do
    setup do
      ladder_fixture()
    end

    # Stefan's condition on issue #1521, verbatim: "If you grant me access to
    # your phone number I want to be able to download the correct vCard with
    # that information."
    test "a vernetzt contact's vCard carries the number they were granted", %{
      owner: owner,
      contact: contact
    } do
      conn = login(contact) |> get(~p"/#{owner}/vcard")
      body = response(conn, 200)

      assert body =~ "3330003"
      assert body =~ "1110001"
      refute body =~ "4440004"
    end

    test "a stranger's vCard does not", %{owner: owner, stranger: stranger} do
      body = login(stranger) |> get(~p"/#{owner}/vcard") |> response(200)

      assert body =~ "1110001"
      assert body =~ "2220002"
      refute body =~ "3330003"
    end

    test "the owner's own vCard carries every rung", %{owner: owner} do
      body = login(owner) |> get(~p"/#{owner}/vcard") |> response(200)

      assert body =~ "4440004"
    end

    test "the response is uncacheable, so no shared cache can pass it on", %{
      owner: owner,
      contact: contact
    } do
      conn = login(contact) |> get(~p"/#{owner}/vcard")

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "vary") == ["cookie"]
    end

    test "the profile points a signed-in viewer at that session-aware download", %{
      owner: owner,
      contact: contact
    } do
      html = login(contact) |> get(~p"/#{owner}") |> html_response(200)
      assert html =~ ~s(href="/#{owner.username}/vcard")

      # The logged-out visitor keeps the cacheable, crawlable sibling.
      anon = build_conn() |> get(~p"/#{owner}") |> html_response(200)
      assert anon =~ ~s(href="/#{owner.username}.vcf")
    end
  end

  describe "ProfileDoc" do
    setup do
      ladder_fixture()
    end

    test "builds the anonymous view without a viewer and the scoped one with", %{
      owner: owner,
      contact: contact
    } do
      anon = ProfileDoc.build(owner)
      values = Enum.map(anon.phone_numbers, & &1.value)
      assert @public_number in values
      refute @connected_number in values

      scoped = ProfileDoc.build(owner, viewer: contact)
      scoped_values = Enum.map(scoped.phone_numbers, & &1.value)
      assert @connected_number in scoped_values
      refute @private_number in scoped_values
    end

    test "the rendered vCard follows the doc it was built from", %{
      owner: owner,
      contact: contact
    } do
      assert ProfileDoc.build(owner, viewer: contact) |> VCard.render() =~ "3330003"
      refute ProfileDoc.build(owner) |> VCard.render() =~ "3330003"
    end
  end

  describe "postal addresses" do
    setup do
      ladder_fixture()
    end

    test "the profile card shows each viewer their own rung", %{
      owner: owner,
      contact: contact,
      stranger: stranger
    } do
      anon = build_conn() |> get(~p"/#{owner}") |> html_response(200)
      assert anon =~ "Offenstraße 1"
      refute anon =~ "Vernetztgasse 3"

      seen = login(stranger) |> get(~p"/#{owner}") |> html_response(200)
      assert seen =~ "Mitgliederweg 2"
      refute seen =~ "Vernetztgasse 3"

      vernetzt = login(contact) |> get(~p"/#{owner}") |> html_response(200)
      assert vernetzt =~ "Vernetztgasse 3"
      refute vernetzt =~ "Privatpfad 4"
    end

    test "the /:slug/addresses page and its single-entry page follow", %{
      owner: owner,
      contact: contact,
      stranger: stranger
    } do
      anon = build_conn() |> get(~p"/#{owner}/addresses") |> html_response(200)
      assert anon =~ "Offenstraße 1"
      refute anon =~ "Vernetztgasse 3"

      assert login(contact) |> get(~p"/#{owner}/addresses") |> html_response(200) =~
               "Vernetztgasse 3"

      address = Repo.get_by!(Address, line_1: "Vernetztgasse 3")

      assert login(stranger)
             |> get(~p"/#{owner}/addresses/#{address}")
             |> html_response(404)

      assert login(contact)
             |> get(~p"/#{owner}/addresses/#{address}")
             |> html_response(200) =~ "Vernetztgasse 3"
    end

    test "the crawlable formats and the vCard behave like the other two channels", %{
      owner: owner,
      contact: contact
    } do
      for ext <- ~w(md txt json xml vcf) do
        body = login(contact) |> get("/#{owner.username}.#{ext}") |> response(200)
        assert body =~ "Offenstraße 1", "#{ext} lost the public address"
        refute body =~ "Vernetztgasse 3", "#{ext} leaked a connections-only address"
      end

      vcard = login(contact) |> get(~p"/#{owner}/vcard") |> response(200)
      assert vcard =~ "Vernetztgasse 3"
      refute vcard =~ "Privatpfad 4"
    end

    test "the structured data on the page carries only the public address", %{
      owner: owner,
      contact: contact
    } do
      html = login(contact) |> get(~p"/#{owner}") |> html_response(200)

      # The connections-only address is on the page (the contact card), but the
      # JSON-LD block is written for crawlers and must stay at the public rung.
      assert html =~ "Vernetztgasse 3"

      json_ld =
        html
        |> String.split(~s(<script type="application/ld+json">))
        |> Enum.drop(1)
        |> Enum.join()

      assert json_ld =~ "Offenstraße 1"
      refute json_ld =~ "Vernetztgasse 3"
    end

    test "the ort: search filter is not an oracle for a restricted address" do
      # A member whose ONLY address is restricted must not be findable by city:
      # a hit would confirm they live there. `Vutuv.Search` needs three chars and
      # a signed-in viewer is irrelevant here — the filter itself must be strict.
      hidden = signed_up_member()
      insert(:address, user: hidden, city: "Flensburg", visibility: "connected")

      assert Search.instant("ort:flensburg").exact_people == []

      public = signed_up_member()
      insert(:address, user: public, city: "Flensburg", visibility: "everyone")

      found = Search.instant("ort:flensburg").exact_people
      assert Enum.map(found, & &1.id) == [public.id]
    end

    test "the owner's /settings editor shows every rung", %{owner: owner} do
      html = login(owner) |> get(~p"/settings/addresses") |> html_response(200)
      assert html =~ "Privatpfad 4"
      assert html =~ "Offenstraße 1"
    end

    test "an address nobody has decided about reaches nobody" do
      assert %Address{}.visibility == "private"

      changeset =
        Address.changeset(%Address{}, %{"description" => "Home", "country" => "Germany"})

      assert Ecto.Changeset.apply_changes(changeset).visibility == "private"
    end
  end

  describe "the CV" do
    test "shows no number at all rather than one the viewer has no standing for" do
      # A member whose ONLY number is a restricted one, so the CV cannot quietly
      # fall back to a public row: for a stranger the field has to stay empty.
      owner = signed_up_member()
      contact = signed_up_member()
      stranger = signed_up_member()
      insert(:follow, follower: owner, followee: contact)
      insert(:follow, follower: contact, followee: owner)
      insert(:phone_number, user: owner, value: "+49 30 9990009", visibility: "connected")

      assert CV.build(owner, viewer: contact).phone =~ "9990009"
      assert CV.build(owner, viewer: stranger).phone == nil
      assert CV.build(owner).phone == nil
      assert CV.build(owner, viewer: owner).phone =~ "9990009"
    end
  end

  describe "the API" do
    test "answers the phone list at the token member's rung" do
      %{owner: owner, contact: contact, stranger: stranger} = ladder_fixture()

      for {viewer, expected, unexpected} <- [
            {contact, @connected_number, @private_number},
            {stranger, @members_number, @connected_number}
          ] do
        entries = UserHelpers.phone_numbers_for_display(owner, viewer)
        values = Enum.map(entries, & &1.value)

        assert expected in values
        refute unexpected in values
      end
    end
  end

  describe "email search" do
    test "finds only an address on the widest rung" do
      owner = insert(:user, email_confirmed?: true)
      insert(:email, user: owner, value: "offen@example.com", visibility: "everyone")
      insert(:email, user: owner, value: "mitglieder@example.com", visibility: "members")
      insert(:email, user: owner, value: "vernetzt@example.com", visibility: "connected")

      assert Search.search_by_email("offen@example.com") != []

      # A hit confirms that an account holds this address, so anything narrower
      # than public must not be findable by whoever can type it — searching is
      # not standing.
      assert Search.search_by_email("mitglieder@example.com") == []
      assert Search.search_by_email("vernetzt@example.com") == []
    end
  end

  describe "a row written by the previous release (visibility IS NULL)" do
    test "resolves through the legacy public? boolean instead of being guessed" do
      owner = signed_up_member()

      # Exactly what the N-1 release inserts across a blue/green switch: it knows
      # only `public?`, so `visibility` stays NULL and the read path has to fall
      # back to the boolean rather than treating NULL as private (which would
      # hide a public address) or as public (which would expose a hidden one).
      {1, _} =
        Repo.update_all(
          from(e in Email, where: e.user_id == ^owner.id),
          set: [visibility: nil, public?: true]
        )

      [email] = UserHelpers.emails_for_display(owner, nil)
      assert Email.visibility_of(email) == "everyone"

      {1, _} =
        Repo.update_all(
          from(e in Email, where: e.user_id == ^owner.id),
          set: [visibility: nil, public?: false]
        )

      assert UserHelpers.emails_for_display(owner, nil) == []
    end
  end

  describe "the schema defaults" do
    test "a phone number nobody has decided about reaches nobody" do
      # Privacy by default: before the column existed every number was public
      # without anybody choosing that, which is the data-protection problem the
      # ladder fixes — so an undecided number must start at the narrowest rung.
      assert %PhoneNumber{}.visibility == "private"

      changeset =
        PhoneNumber.changeset(%PhoneNumber{}, %{
          "value" => "+49 30 5550005",
          "number_type" => "Cell"
        })

      assert Ecto.Changeset.apply_changes(changeset).visibility == "private"
    end

    test "the changeset refuses a rung outside the ladder" do
      changeset =
        PhoneNumber.changeset(%PhoneNumber{}, %{
          "value" => "+49 30 5550005",
          "number_type" => "Cell",
          "visibility" => "followers"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :visibility)
    end

    test "an email changeset keeps the legacy public? mirror in step" do
      for {level, mirror} <- [{"everyone", true}, {"members", false}, {"private", false}] do
        changeset =
          Email.update_changeset(%Email{}, %{
            "visibility" => level
          })

        applied = Ecto.Changeset.apply_changes(changeset)
        assert applied.visibility == level
        assert applied.public? == mirror
      end
    end

    test "and the sign-up checkbox still maps onto a rung" do
      # The registration form keeps its single "show it on my profile" box rather
      # than growing the four-way control, so the boolean has to widen to a rung.
      for {public?, level} <- [{true, "everyone"}, {false, "private"}] do
        changeset =
          Email.changeset(%Email{}, %{
            "value" => "neu#{level}@example.com",
            "email_type" => "Personal",
            "public?" => public?
          })

        assert Ecto.Changeset.apply_changes(changeset).visibility == level
      end
    end
  end
end
