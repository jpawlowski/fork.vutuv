defmodule VutuvWeb.AssetImportOrderTest do
  @moduledoc """
  Two `document`-level click listeners on the phone tab bar talk to each other
  through one event, and nothing in JavaScript makes them do it in the right
  order (issue #1731).

  `scroll_top_tab.js` turns the active Feed tab into a back-to-top control once
  the reader is a screen down `/feed`: it takes the press, `preventDefault`s it
  and stops it reaching LiveView's own handler on `window`. `tab_scroll.js`
  remembers where each tab was left, and reads `defaultPrevented` to know that
  such a press left the page exactly where it was and must not be recorded.

  Both listen on `document` in the bubble phase, so the DOM calls them in
  registration order — which is the order of the `import` lines in `app.js` and
  nothing else. Swap them (alphabetising, a lint autofix, a third module
  inserted between) and the scroll memory records an offset for a press that
  never navigated, with no build error and no failing test anywhere near the
  behaviour. This is that test.

  The repo already pins asset-source facts this way (`press_paint_css_test.exs`,
  `mobile_tab_bar_css_test.exs`); an ordering contract between two files is the
  same kind of claim.
  """
  use ExUnit.Case, async: true

  @app_js Path.expand("../../assets/js/app.js", __DIR__)

  test "tab_scroll is imported after scroll_top_tab" do
    source = File.read!(@app_js)

    scroll_top = index_of!(source, ~s(import "./scroll_top_tab"))
    tab_scroll = index_of!(source, ~s(import "./tab_scroll"))

    assert scroll_top < tab_scroll, """
    assets/js/app.js imports ./tab_scroll before ./scroll_top_tab.

    Both register a click listener on `document`, and tab_scroll only knows to
    leave a back-to-top press alone because scroll_top_tab has already called
    preventDefault on it. In this order it silently records a scroll offset for
    a page the reader never left.
    """
  end

  defp index_of!(source, needle) do
    case :binary.match(source, needle) do
      {at, _} -> at
      :nomatch -> flunk("assets/js/app.js no longer contains `#{needle}`")
    end
  end
end
