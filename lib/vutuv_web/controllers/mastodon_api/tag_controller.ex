defmodule VutuvWeb.MastodonApi.TagController do
  @moduledoc """
  Mastodon's hashtag endpoints, mapped onto vutuv's topics.

  vutuv has had tag following since issue #872 — a private subscription that
  pulls a topic's posts into the member's `/feed`, with no owner to notify and
  no public follower list — which is Mastodon's followed hashtag down to the
  silence. The adapter nevertheless answered `/api/v1/followed_tags` with a
  hardcoded empty list and had no follow route at all, so a client showed the
  member no tags, offered "Follow" on a topic they already followed, and 404ed
  when they pressed it.

  A **page identity** cannot act here. vutuv does let a page follow a topic
  (`Tags.follow_tag_as_organization/2`), but Mastodon has no notion of posting
  as somebody else, so a client acting for a page has no way to say which of the
  two it means — and silently subscribing the member instead is the wrong guess
  in the direction that is hardest to notice. It answers 422, the same refusal
  the account relationships use for an action an identity cannot perform.
  """

  use VutuvWeb, :controller

  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Organizations.Organization
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  @doc """
  One topic (`GET /api/v1/tags/:id`).

  The `:id` a client sends is the hashtag as written, so it is matched by slug —
  and through an alias to the topic it was merged into (#1338), because a client
  holding an old spelling should land on the topic rather than on a dead end.
  """
  def show(conn, %{"id" => id}) do
    case Tags.resolve_tag_by_slug(id) do
      %Tag{} = tag -> json(conn, Presenter.tag(tag, following?(conn, tag)))
      nil -> not_found(conn)
    end
  end

  def follow(conn, %{"id" => id}), do: subscribe(conn, id, :follow)
  def unfollow(conn, %{"id" => id}), do: subscribe(conn, id, :unfollow)

  @doc "The topics this member follows (`GET /api/v1/followed_tags`)."
  def followed(%{assigns: %{current_organization: %Organization{}}} = conn, _params),
    do: json(conn, [])

  def followed(conn, _params) do
    tags = Tags.followed_tags(conn.assigns.current_user)

    # `true` by construction — every tag this list returns is one the member
    # follows — so there is nothing to look up per row.
    json(conn, Enum.map(tags, &Presenter.tag(&1, true)))
  end

  # A page identity is refused before anything is looked up: vutuv does let a
  # page follow a topic (`Tags.follow_tag_as_organization/2`), but Mastodon has
  # no notion of acting as somebody else, so a client acting for a page has no
  # way to say which of the two it means — and quietly subscribing the member
  # instead is the wrong guess in the direction hardest to notice.
  defp subscribe(%{assigns: %{current_organization: %Organization{}}} = conn, _id, _action),
    do: unsupported(conn)

  defp subscribe(conn, id, action) do
    case Tags.resolve_tag_by_slug(id) do
      %Tag{} = tag ->
        apply_subscription(conn.assigns.current_user, tag, action)
        # The answer states the outcome the action just decided, rather than
        # asking the database to confirm it: a client flips its button back on
        # the next read if the reply disagrees.
        json(conn, Presenter.tag(tag, action == :follow))

      nil ->
        not_found(conn)
    end
  end

  defp apply_subscription(user, tag, :follow), do: Tags.follow_tag(user, tag)
  defp apply_subscription(user, tag, :unfollow), do: Tags.unfollow_tag(user, tag)

  # `show/2` is the one read that has to ask, because nothing about the request
  # says whether this member already follows the topic.
  defp following?(%{assigns: %{current_organization: %Organization{}}}, _tag), do: false
  defp following?(conn, tag), do: Tags.tag_followed?(conn.assigns.current_user, tag)

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Record not found"})

  defp unsupported(conn),
    do: conn |> put_status(422) |> json(%{error: "This identity cannot perform that action"})
end
