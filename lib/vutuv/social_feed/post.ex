defmodule Vutuv.SocialFeed.Post do
  @moduledoc """
  One remote social post as the profile page shows it: sanitized plain text,
  the post's URL on its home network, and when it was posted. Built
  exclusively by the provider clients' `fetch_posts/1`; the `text` is already
  reduced to plain text there (never render it with `raw/1`).

  `html` is presentation data the web layer fills in
  (`VutuvWeb.UserProfileLive` via `VutuvWeb.Markdown.render_remote/1`): the
  `text` run through the member-post pipeline — links, Markdown, hashtag
  linking, sanitized — so *that* field is safe for `raw/1`. It stays nil in
  the cache.
  """

  defstruct [:id, :url, :text, :html, :created_at]

  @type t :: %__MODULE__{
          id: String.t(),
          url: String.t(),
          text: String.t(),
          html: String.t() | nil,
          created_at: DateTime.t()
        }

  # Remote post text is clamped to this many characters (with an ellipsis) in
  # both provider feeds.
  @max_text_length 500

  @doc "The trimmed value, or nil when it is blank/whitespace-only."
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_value), do: nil

  @doc "Clamps remote post text to #{@max_text_length} characters with a trailing ellipsis."
  def truncate(text), do: truncate(text, @max_text_length)

  @doc """
  Clamps `text` to at most `max` characters, replacing the tail with a trailing
  ellipsis when it runs over.

  **The cut lands between words, not inside one.** Every caller here shows the
  result to a reader — a remote post's body, a repository description, a card
  headline, a link teaser — and `Bild & Ton: das neue Sm…` reads as a glitch
  where `Bild & Ton: das neue…` reads as a clamp. The `max - 1` leaves room for
  the ellipsis, so the result never exceeds `max`; a first word longer than the
  whole budget has no space to cut at and keeps the blunt slice, which is the
  only shape that still fits.

  This is the one clamp in the remote-content stack (issue #1741). It used to
  be two — a blunt one here and a word-aware one private to
  `Vutuv.LinkSummary` — and both fed the *same* link preview card: an over-long
  `og:description` was cut mid-word while the model-written teaser beside it
  was not, which is a difference no reader could attribute to anything.
  """
  # Neither clause asks how long `text` IS — only whether it reaches past `max`,
  # which is the cheaper question and the only one that matters. `String.length/1`
  # walks the whole input, and this is now the clamp on the `RemoteHtml` →
  # `LinkSummary` path, where "the whole input" is up to 128 KB of a stranger's
  # page being cut to 12,000 characters: 72,255 reductions to answer it that way
  # against 16,334 this way, and a short post that needs no cut at all drops from
  # 226 to 6. `byte_size/1` is O(1) and sound as a first pass because bytes are
  # never fewer than graphemes, so the common no-op leaves immediately;
  # `String.split_at/2` then bounds the test at `max` graphemes and hands back the
  # head it already walked.
  def truncate(text, max) when byte_size(text) <= max, do: text

  def truncate(text, max) do
    case String.split_at(text, max) do
      {_head, ""} ->
        text

      {head, _rest} ->
        head = String.slice(head, 0, max - 1)
        trimmed = String.replace(head, ~r/\s+\S*$/u, "")

        # `/u` is load-bearing, not decoration: `Vutuv.RemoteHtml.decode_entities/1`
        # resolves `&nbsp;` to U+00A0, which `\s` matches only under `/u`.
        if(trimmed == "", do: head, else: trimmed) <> "…"
    end
  end
end
