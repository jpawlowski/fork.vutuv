defmodule Vutuv.PageScreenshot.ConsentSweepTest do
  @moduledoc """
  The sweep is JavaScript, so what a unit test can hold on to is its
  *contract*: the promises the moduledoc makes to the reader and the shape
  `Vutuv.PageScreenshot.Cdp` relies on. Whether it actually clears `zdf.de` is
  a browser question and was answered with a browser.

  Both promises asserted here fail silently when broken — a swept page that
  clicked "Accept" looks exactly like one that hid the dialog, and a decode
  that raises inside the driver loses the whole capture rather than the
  cosmetic part of it.
  """
  use ExUnit.Case, async: true

  alias Vutuv.PageScreenshot.ConsentSweep

  describe "expression/0" do
    test "is one self-contained expression `Runtime.evaluate` can return" do
      expression = ConsentSweep.expression() |> String.trim()

      assert String.starts_with?(expression, "(function")
      assert String.ends_with?(expression, "})()")
    end

    test "hides, and never clicks" do
      # The policy, not an implementation detail: autoconsent clicks *reject*
      # against a rule that names the button, while this one only ever gets to
      # guess from a label — and the button beside the one you meant says
      # "Accept". Consenting on a member's behalf is not ours to do, so a
      # `.click()` creeping in here would be a policy change that no page and
      # no log would report.
      refute ConsentSweep.expression() =~ ".click("
      refute ConsentSweep.expression() =~ "dispatchEvent"
    end

    test "never hides an element carrying a page's worth of text" do
      # Both routes into `isConsentNotice` sit under the size ceiling — the
      # CMP-name one included, or a `<div id="privacy-policy">` that happens to
      # be sticky would take the whole page out of the picture.
      [_before, after_gate] =
        String.split(ConsentSweep.expression(), "function isConsentNotice", parts: 2)

      [gate, _rest] = String.split(after_gate, "CMP.test", parts: 2)
      assert gate =~ "MAX_DIALOG_TEXT"
    end

    test "asks for a consent action before it hides anything" do
      # Text alone is not enough to hide part of a page: an article *about*
      # cookie banners under a sticky header would qualify. The accept/reject
      # control is the thing a consent dialog has and prose does not.
      assert ConsentSweep.expression() =~ "offersConsentAction"
      assert ConsentSweep.expression() =~ "akzeptier"
      assert ConsentSweep.expression() =~ "reject"
    end
  end

  describe "hidden/1" do
    test "reads back what the page reported" do
      assert ConsentSweep.hidden(["notice:div#cmp", "backdrop:div.overlay"]) ==
               ["notice:div#cmp", "backdrop:div.overlay"]
    end

    test "an empty sweep is an empty list" do
      assert ConsentSweep.hidden([]) == []
    end

    test "anything else reads as nothing hidden, and never raises" do
      # The value comes back from a page we do not control, through a driver
      # that must never lose a screenshot over the cosmetic step. An evaluate
      # that threw and returned no value, a reply shape we did not expect:
      # both of them mean "nothing was hidden".
      for value <- [nil, "not a list", %{"hidden" => 1}, :undefined, 7] do
        assert ConsentSweep.hidden(value) == []
      end
    end

    test "drops entries that are not descriptions" do
      assert ConsentSweep.hidden(["notice:div#cmp", 3, nil]) == ["notice:div#cmp"]
    end
  end
end
