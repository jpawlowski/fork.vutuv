defmodule VutuvWeb.ComposerMentionsTest do
  @moduledoc """
  The composer's end of the `@`-picker (issue #1748).

  The component test next door proves `<.markdown_editor>` renders the picker's
  scaffold; this proves the post composer actually asks for it — with the cap a
  post has, which the shared editor cannot know on its own.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Mentions

  test "the feed composer arms the picker and names the post's mention cap", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    {:ok, _live, html} = live(conn, ~p"/feed")

    assert html =~ ~s(data-mention-url="/system/mentions/suggest")
    assert html =~ ~s(data-mention-max="#{Mentions.max_post_mentions()}")
  end
end
