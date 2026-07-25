defmodule VutuvWeb.SettingsFollowedTagsTest do
  use VutuvWeb.ConnCase, async: true

  # The /settings/followed_tags management list (issue #872) and its settings-hub
  # row. The row used to appear only once the member followed a tag; it is
  # unconditional now, because a menu that changes shape between visits cannot be
  # learned and a hidden row is unfindable by definition. The empty page teaches
  # the feature instead.

  alias Vutuv.Tags

  test "lists the member's followed tags with an unfollow control", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    tag = insert(:tag)
    Tags.follow_tag(user, tag)

    html = conn |> get(~p"/settings/followed_tags") |> html_response(200)
    assert html =~ tag.name
    assert html =~ ~s(href="/tag_follows/#{tag.id}")
    refute html =~ ~s(id="followed-tags-empty")
  end

  test "with nothing followed, the page explains how to follow a tag", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings/followed_tags") |> html_response(200)

    assert html =~ ~s(id="followed-tags-empty")
    assert html =~ ~s(href="#{~p"/tags"}")
  end

  test "the settings hub carries the row whether or not a tag is followed", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings") |> html_response(200)
    assert html =~ ~s(href="#{~p"/settings/followed_tags"}")

    Tags.follow_tag(user, insert(:tag))

    html = conn |> recycle() |> get(~p"/settings") |> html_response(200)
    assert html =~ ~s(href="#{~p"/settings/followed_tags"}")
  end
end
