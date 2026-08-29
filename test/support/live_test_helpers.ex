defmodule VutuvWeb.LiveTestHelpers do
  @moduledoc """
  Shared test helpers that do NOT need the calling module's `@endpoint`,
  imported by `VutuvWeb.ConnCase`.

  A module of its own rather than more lines inside ConnCase's `using` quote:
  that quote is compiled into every test module in the suite and is already
  long enough that credo asks for it back (`Avoid long quote blocks`). What
  cannot move here is anything reaching for `@endpoint` — `live_at/3` dispatches
  a request and therefore has to stay generated per module.
  """

  import ExUnit.Assertions

  @doc """
  Asserts that `assets/js/app.js` sends the connect param `key` and still
  carries `hook`.

  This is the half a LiveView test cannot reach. `put_connect_params/2` hands
  the server whatever a test says, so every test of a bundle-gated feature
  would keep passing if `app.js` never sent the key and the feature were dead
  in every browser. So assert the source, the way `mobile_tab_bar_css_test.exs`
  does — and assert the hook too, because the param has to be retired with it.
  """
  def assert_bundle_capability(key, hook) do
    app_js = File.read!("assets/js/app.js")

    assert app_js =~ ~r/params:\s*\{[^}]*#{key}:\s*true/,
           "the LiveSocket params in assets/js/app.js must send `#{key}: true`"

    assert app_js =~ hook, "retire the `#{key}` param together with the #{hook} hook"
  end
end
