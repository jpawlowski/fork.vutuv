defmodule Vutuv.MentionSuggestTest do
  @moduledoc """
  The composer's `@`-picker (issue #1748): who `Vutuv.Mentions.suggest/3`
  offers, in what order, and who it refuses to offer at all.

  The refusals are the load-bearing half. A picker is a second way to find
  accounts, and one that answered more freely than the search page would turn a
  block into a suggestion — so each exclusion is asserted here rather than
  trusted to the query reading right.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Mentions
  alias Vutuv.Social

  defp handles(results), do: Enum.map(results, & &1.username)

  defp member(handle, attrs \\ []) do
    insert(:activated_user, Keyword.merge([username: handle], attrs))
  end

  describe "suggest/3" do
    test "offers a member whose handle starts with the term" do
      viewer = member("viewer_a")
      member("adalovelace", first_name: "Ada", last_name: "Lovelace")

      assert handles(Mentions.suggest(viewer, "ada")) == ["adalovelace"]
    end

    test "offers a member the term only appears in the name of" do
      viewer = member("viewer_b")
      member("countess", first_name: "Ada", last_name: "Lovelace")

      assert handles(Mentions.suggest(viewer, "lovel")) == ["countess"]
    end

    test "offers an organization page by its root handle" do
      viewer = member("viewer_c")
      insert(:organization, username: "acmegmbh", name: "Acme GmbH")

      assert handles(Mentions.suggest(viewer, "acme")) == ["acmegmbh"]
    end

    test "a page without a root handle cannot be mentioned, so is not offered" do
      viewer = member("viewer_d")
      insert(:organization, username: nil, name: "Acme Nohandle")

      assert Mentions.suggest(viewer, "acme") == []
    end

    test "a handle-prefix match sorts ahead of a name-only match" do
      viewer = member("viewer_e")
      member("zzz_named", first_name: "Adalbert", last_name: "Aaa")
      member("adaline", first_name: "Zora", last_name: "Zzz")

      assert handles(Mentions.suggest(viewer, "adal")) == ["adaline", "zzz_named"]
    end

    test "somebody the viewer follows comes first, whatever the spelling says" do
      viewer = member("viewer_f")
      # The handle-prefix match would otherwise win on the ordering above.
      insert(:activated_user, username: "adastranger", first_name: "Ada", last_name: "Stranger")
      friend = member("thefriend", first_name: "Ada", last_name: "Friend")
      follow!(viewer, friend)

      assert handles(Mentions.suggest(viewer, "ada")) == ["thefriend", "adastranger"]
    end

    test "an organization the viewer follows comes first too" do
      viewer = member("viewer_g")
      insert(:activated_user, username: "adastranger2", first_name: "Ada", last_name: "Stranger")
      page = insert(:organization, username: "adapage", name: "Ada Page")
      insert(:follow, follower: viewer, followee_organization: page)

      assert hd(handles(Mentions.suggest(viewer, "ada"))) == "adapage"
    end

    test "the viewer is not offered themselves" do
      viewer = member("adaviewer", first_name: "Ada", last_name: "Viewer")

      assert Mentions.suggest(viewer, "ada") == []
    end

    test "a block hides the account in both directions" do
      viewer = member("viewer_h")
      blocked = member("adablocked", first_name: "Ada", last_name: "Blocked")
      blocker = member("adablocker", first_name: "Ada", last_name: "Blocker")

      Social.block_user(viewer, blocked)
      Social.block_user(blocker, viewer)

      assert Mentions.suggest(viewer, "ada") == []
    end

    test "a member moderation hides is not offered" do
      viewer = member("viewer_i")

      member("adafrozen",
        first_name: "Ada",
        last_name: "Frozen",
        frozen_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      )

      assert Mentions.suggest(viewer, "ada") == []
    end

    test "a member who never confirmed their address is not offered" do
      viewer = member("viewer_j")
      insert(:user, username: "adaunconfirmed", first_name: "Ada", email_confirmed?: false)

      assert Mentions.suggest(viewer, "ada") == []
    end

    test "a page that is not publicly visible is not offered" do
      viewer = member("viewer_k")
      insert(:organization, username: "adapending", name: "Ada Pending", status: "pending")

      assert Mentions.suggest(viewer, "ada") == []
    end

    test "nothing is offered below two characters" do
      viewer = member("viewer_l")
      member("adaempty", first_name: "Ada", last_name: "Empty")

      # A bare `@` starts a word more often than a mention, and one letter names
      # half the site — so the rows would be noise and the scan would be wasted.
      assert Mentions.suggest(viewer, "") == []
      assert Mentions.suggest(viewer, "   ") == []
      assert Mentions.suggest(viewer, "a") == []
      assert handles(Mentions.suggest(viewer, "ad")) == ["adaempty"]
    end

    test "the term is a literal, not a LIKE pattern" do
      viewer = member("viewer_m")
      member("adapercent", first_name: "Ada", last_name: "Percent")

      assert Mentions.suggest(viewer, "%a") == []
      assert Mentions.suggest(viewer, "_d") == []
    end

    test "at most `limit` rows come back" do
      viewer = member("viewer_n")
      for index <- 1..4, do: member("adamany#{index}", first_name: "Ada")

      assert length(Mentions.suggest(viewer, "ada", 2)) == 2
    end
  end

  describe "check_handles/1" do
    test "answers for members and pages alike, and drops what nobody holds" do
      member("adaknown")
      insert(:organization, username: "acmeknown")

      {checked, resolved} = Mentions.check_handles(["adaknown", "AcmeKnown", "ghost"])

      assert Enum.sort(checked) == ["adaknown", "acmeknown", "ghost"] |> Enum.sort()
      assert MapSet.equal?(resolved, MapSet.new(["adaknown", "acmeknown"]))
    end

    # The chip means "this will be a link", so it has to answer the RENDERER's
    # question, not the save's. A page nobody may see holds its handle — the save
    # takes it — but `VutuvWeb.Markdown` leaves it as plain text, and a chip there
    # would promise a link that never appears.
    test "a page nobody may see holds its handle but does not resolve" do
      insert(:organization, username: "acmehidden", status: "pending")

      {checked, resolved} = Mentions.check_handles(["acmehidden"])

      assert checked == ["acmehidden"]
      assert MapSet.size(resolved) == 0
      # …and the save still accepts it, which is the asymmetry being chosen.
      assert Mentions.unknown_handles("hi @acmehidden") == []
    end

    test "normalizes, dedupes and caps the list it answers about" do
      handles = Enum.map(1..(Mentions.max_check_handles() + 5), &"handle#{&1}")

      {checked, _resolved} = Mentions.check_handles(handles)
      assert length(checked) == Mentions.max_check_handles()

      assert {["ada"], _} = Mentions.check_handles(["@Ada", "ada", "  "])
    end
  end
end
