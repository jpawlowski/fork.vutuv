defmodule VutuvWeb.ContentPolicy do
  @moduledoc """
  The one source of the site's AI-use stance. `VutuvWeb.RobotsTxt` renders
  it as robots.txt `Content-Signal` directives and `VutuvWeb.AgentDocs`
  (plus the feeds) as the per-response `Content-Signal` header, so the two
  can never disagree.

  Configured via `config :vutuv, ai_crawler_policy:` —

    * `:permissive` (default) — all AI crawlers welcome; search, live AI
      input and training all allowed. vutuv exists to give members reach.
    * `:block_training` — search and retrieval stay allowed, training
      crawlers are blocked and `ai-train=no` is declared.

  On top of the site stance every member answers two independent
  questions: `noindex?` (may search engines index my profile?) and `noai?`
  (may AI agents and LLMs use my content — training and live retrieval?).
  All four combinations are valid; `signal_header/2` and
  `robots_directives/2` render them per page.
  """

  def policy do
    Application.get_env(:vutuv, :ai_crawler_policy, :permissive)
  end

  @doc """
  The `Content-Signal` header value for a page. `noindex?` is the page's
  (or member's) search opt-out, `noai?` the AI opt-out; the two axes are
  independent. `ai-train` additionally requires the permissive site stance.
  """
  def signal_header(noindex?, noai?) do
    render_signals(policy() == :permissive and not noai?, not noindex?, not noai?)
  end

  @doc """
  The robots directives a page's meta tag / `X-Robots-Tag` header should
  carry for these opt-outs: `noindex` for search engines, the
  `noai, noimageai` pair (the de-facto AI-crawler vocabulary) for AI use.
  `nil` when there is nothing to declare.
  """
  def robots_directives(noindex?, noai?)
  def robots_directives(false, false), do: nil
  def robots_directives(true, false), do: "noindex"
  def robots_directives(false, true), do: "noai, noimageai"
  def robots_directives(true, true), do: "noindex, noai, noimageai"

  @doc """
  True when a member fully opted out of machine use — `noindex?` (search
  engines) **and** `noai?` (AI agents) both set. Their profile namespace
  then serves no agent documents at all (`VutuvWeb.Plug.AgentExportOptOut`
  404s the `.md`/`.txt`/`.json`/`.xml` URLs) and the profile shows a note
  where the "Other formats" card would link them. One opt-out alone blocks
  nothing: those documents keep flowing with the choice embedded in the
  headers and every body format, because a single opt-out still permits
  the other machine audience. The vCard is never gated (a human
  contact-exchange format).
  """
  def agent_docs_blocked?(%{noindex?: noindex?, noai?: noai?}), do: noindex? and noai?

  @vcard_download_levels ~w(everyone followers nobody)

  @doc """
  Who may download a member's profile as a vCard (issue #1705):

    * `"everyone"` — the default, and exactly today's behaviour: an anonymous
      public download of what the page already shows.
    * `"followers"` — a signed-in member who follows them.
    * `"nobody"` — no button, and `/:slug.vcf` is gone.

  The sibling of `users.carddav_visibility`, and the reason that one means
  anything: withdrawing from every address book while a one-click download sits
  on the profile is half a promise. Two settings, because they are not the same
  act — a subscription keeps a card current on a device indefinitely, a
  download is one file, once.
  """
  def vcard_download_levels, do: @vcard_download_levels

  @doc """
  Whether `viewer` may download `user`'s vCard. `viewer` is `nil` for a
  logged-out visitor.

  A member may always download their own. Note that the **default costs
  nothing**: with `"everyone"` the answer does not depend on the viewer at all,
  so the public `.vcf` stays the identical, cache-safe response it has always
  been. Only a member who narrows it makes their own profile answer differently
  per viewer, which is what they asked for.
  """
  def vcard_download_allowed?(user, viewer)

  def vcard_download_allowed?(%{id: id}, %{id: id}), do: true
  def vcard_download_allowed?(%{vcard_download: "nobody"}, _viewer), do: false
  def vcard_download_allowed?(%{vcard_download: "followers"}, nil), do: false

  def vcard_download_allowed?(%{vcard_download: "followers", id: id}, %{id: viewer_id}),
    do: Vutuv.Social.user_follows_user?(viewer_id, id)

  def vcard_download_allowed?(_user, _viewer), do: true

  @doc """
  Stamps `robots_directives/2` as the response's `X-Robots-Tag` header (a
  no-op when there is nothing to declare). The one conn-level application
  of the directives, shared by the agent docs, the feeds, the post pages
  and the `NoIndex` plug.
  """
  def put_robots_header(conn, noindex?, noai?) do
    case robots_directives(noindex?, noai?) do
      nil -> conn
      directives -> Plug.Conn.put_resp_header(conn, "x-robots-tag", directives)
    end
  end

  @doc false
  def render_signals(train?, search?, input?) do
    "ai-train=#{yn(train?)}, search=#{yn(search?)}, ai-input=#{yn(input?)}"
  end

  defp yn(true), do: "yes"
  defp yn(false), do: "no"
end
