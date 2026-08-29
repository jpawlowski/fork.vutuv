defmodule VutuvWeb.HelpImagesTest do
  @moduledoc """
  Every picture a help page points at has to be **committed**, not merely
  present on the author's disk.

  `/priv/static/` is gitignored wholesale (the asset pipeline owns it), so an
  authored image has to be force-added — and forgetting that is invisible
  locally: the file is right there, the page renders, every test passes. It
  fails only on CI and in production, as a broken image on a page written to
  reassure a member who is setting up their phone. The CardDAV guide shipped
  with all four of its iPhone screenshots in exactly that state.
  """
  use ExUnit.Case, async: true

  @help_dir "priv/help"

  test "every image a help page references exists and is tracked by git" do
    missing =
      for path <- Path.wildcard(Path.join(@help_dir, "*.md")),
          [_, src] <- Regex.scan(~r/!\[[^\]]*\]\((\/[^)\s]+)\)/, File.read!(path)),
          file = Path.join("priv/static", String.trim_leading(src, "/")),
          reason = check(file),
          do: "#{Path.basename(path)} -> #{src} (#{reason})"

    assert missing == []
  end

  defp check(file) do
    cond do
      not File.exists?(file) -> "no such file"
      not tracked?(file) -> "not committed — needs `git add -f`"
      true -> nil
    end
  end

  defp tracked?(file) do
    case System.cmd("git", ["ls-files", "--error-unmatch", file], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end
end
