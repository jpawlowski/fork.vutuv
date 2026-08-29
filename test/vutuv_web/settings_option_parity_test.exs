defmodule VutuvWeb.SettingsOptionParityTest do
  @moduledoc """
  The radio groups on `/settings/carddav` and `/settings/privacy` spell their
  values a second time, as `{value, label, hint}` triples with wording beside
  each one — a list the changesets validate against but do not produce.

  The failure that buys is silent and one-directional: add a level to the owner
  and it is storable, validated and **un-offerable**, with a green build and no
  radio for anyone to notice missing. So the sets are asserted equal here
  rather than left to agree by hand.
  """
  use ExUnit.Case, async: true

  alias Vutuv.CardDav
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.SettingsHTML

  defp offered(triples), do: triples |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  test "the sharing levels offered are exactly the ones CardDAV knows" do
    assert offered(SettingsHTML.carddav_options()) == Enum.sort(CardDav.sharing_levels())
  end

  test "the visibility levels offered are exactly the ones CardDAV knows" do
    assert offered(SettingsHTML.carddav_visibility_options()) ==
             Enum.sort(CardDav.visibility_levels())
  end

  test "the vCard-download levels offered are exactly the ones the policy knows" do
    assert offered(SettingsHTML.vcard_download_options()) ==
             Enum.sort(ContentPolicy.vcard_download_levels())
  end

  test "every option carries a label and a hint, not a bare value" do
    for triples <- [
          SettingsHTML.carddav_options(),
          SettingsHTML.carddav_visibility_options(),
          SettingsHTML.vcard_download_options()
        ],
        {value, label, hint} <- triples do
      assert is_binary(label) and label != "", "#{value} has no label"
      assert is_binary(hint) and hint != "", "#{value} has no hint"
    end
  end
end
