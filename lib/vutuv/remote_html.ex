defmodule Vutuv.RemoteHtml do
  @moduledoc """
  The one place where HTML written by a *remote* server becomes something vutuv
  is willing to store and show: plain text.

  Two callers, one rule. `Vutuv.Mastodon` reduces the statuses of a member's own
  linked account for their profile feed, and `Vutuv.Fediverse` reduces a reply
  written on another network under a member's post (issue #1069). Both hold text
  an attacker controls, and neither has any use for the remote markup, so the
  answer to "how do we sanitise this safely" is to not keep HTML at all:

    * `<script>` and `<style>` elements go **with their contents**,
    * `<br>` and `</p>` become the line breaks that carried the meaning,
    * every remaining tag is stripped (`HtmlSanitizeEx.strip_tags/1`), so there
      is no allowlist to get wrong and nothing to render `raw`,
    * the base entities are decoded exactly **once**, and
    * the result is clamped, so one hostile delivery cannot park a novel.

  The script/style pass matters because `strip_tags/1` removes the *tags* and
  keeps the *text between them*: without it `<script>alert(1)</script>Hallo`
  reduces to the literal `alert(1)Hallo`. That was never an execution risk (the
  output is escaped again on the way to the page), but it let a remote server
  push arbitrary invisible text into a member's profile feed, and it would have
  put the same junk into a stored reply.

  What comes out is plain text that HEEx escapes again on the way to the page,
  and that the agent-format siblings can carry unchanged. Links survive as bare
  URLs, which `VutuvWeb.Markdown` linkifies anyway — including the `@user@host`
  handles of those networks, which it maps to the right remote profile.
  """

  alias Vutuv.SocialFeed.Post

  @doc """
  Reduces a remote server's HTML to clamped plain text, at most `max`
  characters (the shared social-feed clamp by default).
  """
  def to_text(html, max \\ nil)

  def to_text(html, max) when is_binary(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, "")
    # An element left open runs to the end of the document by definition, so
    # there is nothing after it worth keeping either.
    |> String.replace(~r{<(script|style)\b[^>]*>.*}is, "")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>}i, "\n\n")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_entities()
    |> String.trim()
    |> clamp(max)
  end

  def to_text(_html, _max), do: ""

  defp clamp(text, nil), do: Post.truncate(text)
  defp clamp(text, max), do: Post.truncate(text, max)

  # strip_tags/1 returns text with the base named entities still escaped (the
  # numeric ones it decodes itself); undo them exactly once. `&amp;` must come
  # last so a literal "&amp;amp;" cannot double-unescape.
  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end
end
