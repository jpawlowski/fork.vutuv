defmodule Vutuv.RemoteHtmlTest do
  @moduledoc """
  The one place HTML written by a remote server becomes text vutuv will store
  and show — shared by the Mastodon profile feed and the inbound Fediverse
  replies (issue #1069), so it is worth testing on its own rather than only
  through either caller.
  """
  use ExUnit.Case, async: true

  alias Vutuv.RemoteHtml

  test "paragraphs and line breaks survive as line breaks" do
    assert RemoteHtml.to_text("<p>Hallo <b>Welt</b></p><p>Zweiter</p>") == "Hallo Welt\n\nZweiter"
    assert RemoteHtml.to_text("eins<br>zwei<br/>drei") == "eins\nzwei\ndrei"
  end

  test "the base entities are decoded exactly once" do
    assert RemoteHtml.to_text("<p>Tom &amp; Jerry &lt;3</p>") == "Tom & Jerry <3"
    assert RemoteHtml.to_text("<p>&amp;amp;</p>") == "&amp;"
  end

  describe "script and style go with their contents" do
    test "a paired element leaves nothing behind" do
      assert RemoteHtml.to_text("<script>alert(1)</script><p>safe</p>") == "safe"
      assert RemoteHtml.to_text("<style>body{color:red}</style><p>safe</p>") == "safe"
    end

    test "the tag may carry attributes and odd casing" do
      assert RemoteHtml.to_text(~s(<SCRIPT type="text/javascript">x=1</SCRIPT>hi)) == "hi"
    end

    test "an unclosed element takes the rest with it" do
      # It runs to the end of the document by definition, so there is nothing
      # after it worth keeping.
      assert RemoteHtml.to_text("<p>before</p><script>alert(1)") == "before"
    end

    test "a member's own text mentioning the word is untouched" do
      assert RemoteHtml.to_text("<p>Ich schreibe ein Script.</p>") == "Ich schreibe ein Script."
    end
  end

  test "everything else is stripped, attributes included" do
    assert RemoteHtml.to_text("<img src=x onerror=alert(2)>danach") == "danach"
    refute RemoteHtml.to_text(~s(<a href="javascript:x">klick</a>)) =~ "javascript:"
  end

  test "the result is clamped to the requested length" do
    long = "<p>" <> String.duplicate("a", 200) <> "</p>"

    assert String.length(RemoteHtml.to_text(long, 50)) == 50
    assert String.ends_with?(RemoteHtml.to_text(long, 50), "…")
  end

  test "anything that is not a string reduces to nothing" do
    assert RemoteHtml.to_text(nil) == ""
    assert RemoteHtml.to_text(42) == ""
  end
end
