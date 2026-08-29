defmodule Vutuv.RemoteHtml do
  @moduledoc """
  The one place where HTML written by a *remote* server becomes something vutuv
  is willing to store and show: plain text.

  Two callers, one rule. `Vutuv.Mastodon` reduces the statuses of a member's own
  linked account for their profile feed, and `Vutuv.Fediverse` reduces the posts
  and replies other networks deliver (issues #1069, #1161). Both hold text an
  attacker controls, and neither has any use for the remote markup, so the
  answer to "how do we sanitise this safely" is to not keep HTML at all:

    * `<script>` and `<style>` elements go **with their contents**,
    * `<br>` and `</p>` become the line breaks that carried the meaning,
    * every remaining tag is stripped (`HtmlSanitizeEx.strip_tags/1`), so there
      is no allowlist to get wrong and nothing to render `raw`,
    * HTML entities are decoded exactly **once** (`decode_entities/1`),
    * the sending server's own **custom-emoji shortcodes** go out with it
      (`strip_shortcodes/1`), and
    * the result is clamped, so one hostile delivery cannot park a novel.

  **One consequence of that decode worth knowing before you read this text:**
  `&nbsp;` resolves to a real U+00A0, where the six-replacement chain it
  replaced produced an ASCII space — a stored body now keeps the non-breaking
  space its author wrote. Everything downstream already copes: `String.trim/1`
  counts it as whitespace, the `\\s` in `Vutuv.SocialFeed.Post.truncate/2` and
  in `Vutuv.LinkSummary`'s squash both match it because both carry `/u`, and
  post search is Postgres full-text, which splits on it. A new reader reaching
  for a byte-mode `\\s` would not — that is the trap.

  The script/style pass matters because `strip_tags/1` removes the *tags* and
  keeps the *text between them*: without it `<script>alert(1)</script>Hallo`
  reduces to the literal `alert(1)Hallo`. That was never an execution risk (the
  output is escaped again on the way to the page), but it let a remote server
  push arbitrary invisible text into a member's profile feed, and it would have
  put the same junk into a stored reply.

  It also owns the two small pieces every reader of a stranger's markup needs and
  nobody should own a second copy of (issue #1741): `tag_attributes/1`, the
  attribute-quoting grammar for the callers that read a stranger's tags without
  parsing the HTML around them (`Vutuv.OpenGraph`'s `<meta>` scan,
  `Vutuv.WebVerification`'s `rel=me` scan), and `decode_entities/1`, which
  `Vutuv.OpenGraph` needs for the same values — the same "one place, one rule"
  reason as the text reduction below.

  What comes out is plain text that HEEx escapes again on the way to the page,
  and that the agent-format siblings can carry unchanged. Links survive as bare
  URLs, which `VutuvWeb.Markdown` linkifies anyway — including the `@user@host`
  handles of those networks, which it maps to the right remote profile.

  **Mentions** need one repair on the way through: those networks render a
  mention as the bare `@user` short form, while the full address that names the
  account lives only in the anchor the strip throws away — and in the object's
  `tag` array. Stripped naively, `@herrkaschke` is just a word, and the renderer
  deliberately leaves a bare `@name` in remote content unlinked (it would point
  at whatever vutuv member shares the handle). So `to_text/3` takes those
  `Mention` tags and widens each short form to the full `@user@host`, which the
  renderer then links to the remote profile like any typed fediverse handle —
  **including a mention of one of our own members**, whose address on our host
  the renderer now resolves to their profile (issue #1560); it used to be left
  short, because the full form was linked straight back at this server as
  `https://host/@user`, a path vutuv does not serve.
  """

  alias Vutuv.Mentions
  alias Vutuv.SocialFeed.Post

  # The bare `@user` short form a remote server renders a mention as. The
  # boundaries mirror the shared entity grammar (`Vutuv.Mentions`): not
  # mid-token (no email `a@b`, no URL `/@user`), and not the first half of an
  # already-full `@user@host`.
  @short_mention ~r{(?<![A-Za-z0-9_@/])@([A-Za-z0-9_]+)(?![A-Za-z0-9_@])}

  # A hostile server could park thousands of Mention tags on one delivery;
  # nothing real mentions more than a handful.
  @max_mention_tags 50

  # A run of custom-emoji shortcodes as these networks spell them:
  # `[a-zA-Z0-9_]{2,}` between colons, one or more in a row because two adjacent
  # emoji are written `:blobcat::heart:` with no space between them.
  #
  # The delimiters are the whole point — they are what keeps a time ("10:30:45")
  # and a scheme ("daniel:// stenberg://") out of it. A **colon** is not one of
  # them, or `std::vector::size` would read as a `:vector:` emoji between two
  # colons and come out `std::size`.
  @shortcode ~r/(?<![\w:])(?::[a-zA-Z0-9_]{2,}:)+(?![\w:])/

  @doc """
  Reduces a remote server's HTML to clamped plain text, at most `max`
  characters (the shared social-feed clamp by default).

  `tags` is the object's ActivityPub `tag` value (or the REST `mentions` list
  normalized to that shape): each `Mention` in it widens the bare `@user` the
  content shows to the full `@user@host` the renderer can link. Expansion runs
  before the clamp, so the cap bounds the stored result either way.
  """
  def to_text(html, max \\ nil, tags \\ [])

  def to_text(html, max, tags) when is_binary(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, "")
    # An element left open runs to the end of the document by definition, so
    # there is nothing after it worth keeping either.
    |> String.replace(~r{<(script|style)\b[^>]*>.*}is, "")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>}i, "\n\n")
    |> HtmlSanitizeEx.strip_tags()
    |> scrub_nul()
    |> decode_entities()
    |> String.trim()
    |> strip_shortcodes()
    |> expand_mentions(tags)
    |> clamp(max)
  end

  def to_text(_html, _max, _tags), do: ""

  # `name="value"` / `name='value'` / `name=value`, any order, any case.
  @attribute_regex ~r/([a-zA-Z0-9_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/

  @doc """
  `text` — already plain, not HTML — with its custom-emoji shortcodes taken out
  and the gap each one leaves closed.

  Those networks let an account put its **own server's** emoji in a post and
  send it as a shortcode (`":tux:"`), with the picture it stands for in the
  object's `tag` array. That picture is that server's, and vutuv shows no remote
  picture it has not cached and put past the AI gate, so the token has nothing
  to render as and reads on the card as a literal `":tux:"`.

  `to_text/3` applies it to everything that arrives as HTML. It is public for
  the two plain-text paths that never see any: a poll's option names
  (`Vutuv.Fediverse`) and a Mastodon status' content warning (`Vutuv.Mastodon`),
  which the REST API sends as text. Everything a remote server wrote and vutuv
  stores goes through one of those three.

  Cleaned on the way **in**, unlike a display name (`Handle.display_name/1`,
  which calls this too) — the name is re-derived from its column on every
  render, while this text *is* the column, and every reader of it would
  otherwise need the same repair. Text carrying no shortcode comes back
  untouched rather than merely unchanged: `translations.source_sha256` keys a
  cached translation to the exact string, so a cosmetic byte would re-run the
  whole stored corpus past Ollama.
  """
  def strip_shortcodes(text) when is_binary(text) do
    # One whole-text `match?` before the line pass, and `match?` rather than a
    # replace whose result is thrown away: nearly every post carries no
    # shortcode at all, and for those this is the only work done (measured: 16
    # reductions against 235 for splitting into lines and letting each line
    # answer for itself, which grows with the post).
    if Regex.match?(@shortcode, text) do
      text
      |> String.split("\n")
      |> Enum.flat_map(&strip_line/1)
      |> Enum.join("\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()
    else
      text
    end
  end

  defp clamp(text, nil), do: Post.truncate(text)
  defp clamp(text, max), do: Post.truncate(text, max)

  @doc """
  Removes NUL bytes from text taken off a remote server.

  A NUL is valid UTF-8 and Postgres refuses it (`22021
  character_not_in_repertoire`), so one in here is not a display problem, it is
  a raise on `Repo.insert` — and this text is stored: `Vutuv.Fediverse`'s
  `remote_text/3` writes it into a delivered post's body, so any federating
  server can reach that by putting `&#0;` in a Note.

  **Its own step, and not part of `decode_entities/1`**, where the same guard
  already lives (`entity_text/2` refuses to build a NUL). That guard cannot
  help, because a NUL arrives by two routes that both bypass it:
  `strip_tags/1` decodes numeric entities **itself**, so `&#0;` is already a
  raw byte by the time the decoder runs, and a `<meta content>` or `<title>`
  can simply contain the byte, which is not an entity at all. A guard the
  pipeline steps around is not a guard.

  **Public, and that is the point.** `Vutuv.OpenGraph.normalise/2` is the
  second door into the same column — its output lands in
  `Screenshots.mark_ready/2`'s `{:ok, _} = Repo.update()`, which on a raise
  leaves the job `capturing` for `resume_stuck/0` to hand back *without*
  counting an attempt, i.e. the unbounded retry loop `result_changeset/2`
  exists to avoid. Leaving this private would have made every caller that needs
  it write its own, which is the shape issue #1741 was about.

  It does **not** cover every path from a stranger's bytes to a text column —
  a remote actor's `preferred_username` and `name`, and a YouTube oEmbed title,
  still reach `Repo` unscrubbed. That belongs at the changeset layer; see the
  follow-up issue.
  """
  def scrub_nul(text) when is_binary(text), do: String.replace(text, <<0>>, "")

  @entity_regex ~r/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);/

  @doc """
  The HTML entities in a fragment of a stranger's markup, resolved to the text
  they stand for. An entity nothing knows is left standing rather than
  swallowed.

  Here rather than in each caller, for the reason `tag_attributes/1` is here
  (issue #1741): every module in this stack reads somebody else's markup and
  every one of them meets `&rsquo;`. `to_text/3` needs it because
  `HtmlSanitizeEx.strip_tags/1` hands back text with named entities still
  escaped, and `Vutuv.OpenGraph` needs it because a `content` attribute and a
  `<title>` are entity-encoded — without it a card headline reads
  `Bild &amp; Ton`, and an `&amp;` inside an `og:image` URL breaks the fetch.

  **One pass, not a chain of replacements.** A chain has to decode `&amp;`
  LAST or a literal `&amp;amp;` unescapes twice, and that ordering is a rule
  somebody has to keep obeying — it lived in a comment above the version this
  replaced. A single pass cannot double-decode at all, because `Regex.replace/3`
  does not re-scan what it has written.
  """
  def decode_entities(text) when is_binary(text) do
    Regex.replace(@entity_regex, text, fn whole, body -> entity(body, whole) end)
  end

  # `:mochiweb_charref` is the full HTML5 table, and it already ships here —
  # `:html_sanitize_ex` depends on it and `strip_tags/1` above leans on it. It
  # answers all three spellings the regex captures (`rsquo`, `#8217`, `#x2019`)
  # and `:undefined` for anything it does not know.
  #
  # The two versions this replaced were a six-entry table typed out by hand and
  # a slightly longer one beside it, and the hand-typed version is what shipped
  # `Google&rsquo;s new phone` into a card headline: six entries where the web
  # has two thousand. Extending it by another forty names would only have moved
  # the edge — `&frac12;`, `&sup2;`, `&eacute;` were all one page away from the
  # same bug.
  #
  # Case matters and is not folded: `&Aacute;` is Á and `&aacute;` is á.
  defp entity(body, whole) do
    case :mochiweb_charref.charref(body) do
      :undefined -> whole
      codepoint -> entity_text(codepoint, whole)
    end
  end

  # A lone surrogate is not a codepoint `<<n::utf8>>` can build (it raises), and
  # neither is a number past the Unicode range: those stay text.
  #
  # **`0` is refused with them**, for the reason `scrub_nul/1` sets out above —
  # here it stops `&#0;` in a linked page's `<title>` from raising inside
  # `Screenshots.mark_ready/2` and leaving that job stuck `capturing`.
  defp entity_text(number, _whole)
       when is_integer(number) and (number in 1..0xD7FF or number in 0xE000..0x10FFFF),
       do: <<number::utf8>>

  # A few entities are two codepoints (`&NotEqualTilde;` is ≂ plus a combining
  # slash); each half goes through the same guard.
  defp entity_text(numbers, whole) when is_list(numbers) do
    Enum.map_join(numbers, &entity_text(&1, whole))
  end

  defp entity_text(_number, whole), do: whole

  @doc """
  Every attribute of one HTML tag, as a map from the downcased attribute name to
  its value — tolerating double, single and unquoted values in any order and
  any case.

  Here rather than in either caller because both read a stranger's markup
  **without** parsing it (no HTML library is a dependency): `Vutuv.OpenGraph`
  wants `property`/`name`/`content` off a `<meta>` tag and
  `Vutuv.WebVerification` wants `rel`/`href` off an `<a>`/`<link>` one. Two
  copies of the quoting grammar means a fix to one silently leaves the other
  wrong, which is the whole reason this module exists for the text half.
  """
  def tag_attributes(tag) when is_binary(tag) do
    @attribute_regex
    |> Regex.scan(tag)
    |> Enum.reduce(%{}, fn [_whole, name | values], acc ->
      # The three value alternatives are mutually exclusive; the unmatched ones
      # come back as "". First declaration of a name wins, as in a browser.
      Map.put_new(acc, String.downcase(name), Enum.find(values, "", &(&1 != "")))
    end)
  end

  defp expand_mentions(text, tags) do
    map = mention_map(tags)

    if map_size(map) == 0 or not String.contains?(text, "@") do
      text
    else
      Regex.replace(@short_mention, text, fn whole, user ->
        Map.get(map, String.downcase(user), whole)
      end)
    end
  end

  # short form (downcased) => the one full `@user@host` it names.
  defp mention_map(tags) do
    tags
    |> List.wrap()
    |> Enum.take(@max_mention_tags)
    |> Enum.flat_map(&mention_handle/1)
    |> Enum.group_by(fn {user, _host} -> String.downcase(user) end)
    |> Enum.flat_map(&expansion/1)
    |> Map.new()
  end

  # Two mentioned accounts sharing a short name are indistinguishable in the
  # stripped text, so neither is expanded — never guess which the author meant.
  defp expansion({short, pairs}) do
    case Enum.uniq_by(pairs, fn {_user, host} -> host end) do
      [{user, host}] -> [{short, "@#{user}@#{host}"}]
      _ambiguous -> []
    end
  end

  defp mention_handle(%{"type" => "Mention", "name" => name, "href" => href})
       when is_binary(name) and is_binary(href) do
    with {user, host} <- split_mention(name, href),
         true <- linkable?(user, host) do
      [{user, host}]
    else
      _ -> []
    end
  end

  defp mention_handle(_tag), do: []

  # `name` carries the full `user@host` for a cross-server mention and only the
  # bare user for a same-server one, where the host comes from the href.
  defp split_mention(name, href) do
    case name |> String.trim() |> String.trim_leading("@") |> String.split("@") do
      [user, host] when user != "" and host != "" ->
        {user, String.downcase(host)}

      [user] when user != "" ->
        case href_host(href) do
          nil -> :error
          host -> {user, host}
        end

      _ ->
        :error
    end
  end

  defp href_host(href) do
    case URI.parse(href) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        nil
    end
  end

  # Only an expansion the renderer will actually link is worth writing into the
  # text: the full handle must match the shared entity grammar as one whole
  # fediverse handle (which also validates both charsets — a dotted Misskey
  # user name, say, would come out a plain word plus a broken half-link).
  defp linkable?(user, host) do
    handle = "@#{user}@#{host}"

    case Regex.run(Mentions.entity_regex(), handle) do
      [^handle, u, h | _] -> u != "" and h != ""
      _ -> false
    end
  end

  # A line with no shortcode in it is left byte for byte alone, so the repair
  # can only ever touch the lines it emptied out.
  defp strip_line(line) do
    case String.replace(line, @shortcode, "") do
      ^line -> [line]
      stripped -> close_gap(stripped)
    end
  end

  # What the removed token leaves behind: a doubled space mid-sentence, a space
  # in front of the comma that followed it, an indent at the start of the line
  # it opened. A line that was **nothing but** emoji goes with them — the author
  # gave it a line of its own, so an empty one in its place is not what they
  # wrote either. (`strip_line/1` only calls this for a line that carried one,
  # so an empty result here always means "emoji and nothing else".)
  defp close_gap(stripped) do
    repaired =
      stripped
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/ +(?=[,.)\]])/u, "")
      |> String.trim()

    if repaired == "", do: [], else: [repaired]
  end
end
