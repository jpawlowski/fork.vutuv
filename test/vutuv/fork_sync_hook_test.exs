defmodule Vutuv.ForkSyncHookTest do
  @moduledoc """
  `.claude/hooks/fork-sync.sh` blocks a `git push` / `gh pr create` from a fork
  whose branch was never rebased onto `upstream/main`.

  It is registered in `.claude/settings.json`, so it runs for everybody — and
  the property that matters is therefore not what it prints in a fork but that
  it does **nothing at all** when `origin` is the canonical repository, which
  is how this repository itself is cloned. A guard that inserts itself into the
  maintainer's own workflow to serve the fork case would deserve to be removed.

  The second case is the one its sibling `precommit-before-push.sh` got wrong
  (2026-08-02) and whose tokeniser this file reuses: a push must be recognised
  by the shape of the command, not by the substring `"git push"` — which blocks
  a plain `grep` for it and misses `git -C <dir> push` entirely.

  `--explain` prints the decision without touching the network; the
  settings.json invocation passes no such flag, so it cannot be reached in
  normal use.
  """
  use ExUnit.Case, async: true

  @hook ".claude/hooks/fork-sync.sh"

  setup do
    root = File.cwd!()
    {:ok, root: root, hook: Path.join(root, @hook)}
  end

  describe "the canonical checkout is untouched" do
    test "no push is ever blocked there", ctx do
      repo = clone_of("https://github.com/wintermeyer/vutuv.git")

      assert decide(ctx, "git -C #{repo} push") == "ALLOW canonical checkout"
    end

    test "and the session-start status stays silent", ctx do
      # Both URL spellings and GitHub's case-insensitive names must resolve to
      # the same repository — a fork report in the maintainer's own checkout is
      # the one failure mode that would get this hook deleted.
      for url <- [
            "https://github.com/wintermeyer/vutuv.git",
            "git@github.com:wintermeyer/vutuv.git",
            "https://github.com/Wintermeyer/VuTuv"
          ] do
        assert status(ctx, clone_of(url)) == "", "reported a fork for #{url}"
      end
    end
  end

  describe "a fork that has not been set up yet" do
    test "is recognised from origin's URL alone", ctx do
      # No `upstream` remote, no network, no `gh`: a fresh fork is byte-for-byte
      # identical to its parent, so `origin`'s URL is the only local trace of
      # where this checkout came from.
      out = status(ctx, clone_of("https://github.com/someone/vutuv.git"))

      assert out =~ "looks like a fork"
      assert out =~ "bash scripts/fork-setup.sh"
    end

    test "and cannot push until it is", ctx do
      # Without a remote for the canonical repo nothing can tell whether the
      # branch is current, so the answer is "not yet", not "probably fine".
      assert decide(ctx, "git -C #{clone_of("https://github.com/someone/vutuv.git")} push") ==
               "BLOCK unconfigured fork"
    end

    test "unless the downstream opted out", ctx do
      repo = clone_of("https://github.com/someone/vutuv.git")
      {_, 0} = System.cmd("git", ["config", "vutuv.fork-sync", "false"], cd: repo)

      assert status(ctx, repo) == ""
      assert decide(ctx, "git -C #{repo} push") == "ALLOW canonical checkout"
    end
  end

  describe "recognising a push by its shape" do
    test "the spellings a substring match gets wrong", ctx do
      # Blocked by the old rule though it is not a push at all:
      assert decide(ctx, ~s{grep -rn "git push" .claude/}) == "ALLOW"
      # Missed by the old rule though it is one:
      assert decide(ctx, "git -C #{ctx.root} push") == "HIT push #{ctx.root}"
      assert decide(ctx, "mix test && git push") == "HIT push #{ctx.root}"
    end

    test "opening a pull request counts, merging one does not", ctx do
      # `gh pr create` fixes the PR's base, which is what a stale branch gets
      # wrong. By merge time the branch is pushed and `/deploy` step 11 owns
      # the version re-check.
      assert decide(ctx, "gh pr create --fill-first") == "HIT pr-create #{ctx.root}"
      assert decide(ctx, "gh pr merge 1550 --squash") == "ALLOW"
    end
  end

  test "a degraded path allows rather than blocks", ctx do
    # The opposite posture from `precommit-before-push.sh` on purpose: that one
    # answers "is this code verified" and must fail closed; this one answers
    # "is this branch fresh", and not knowing must not stop the work.
    assert decide(ctx, "git push", cwd: "/nonexistent/worktree") == "ALLOW not a worktree"
  end

  # A throwaway repository with the given `origin` and no other remote — the
  # shape of every clone before anybody has set an `upstream` up.
  defp clone_of(origin_url) do
    dir = Path.join(System.tmp_dir!(), "fork-sync-clone-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {_, 0} = System.cmd("git", ["init", "--quiet", dir])
    {_, 0} = System.cmd("git", ["remote", "add", "origin", origin_url], cd: dir)
    dir
  end

  # Runs `push-gate --explain` against a payload. `System.cmd/3` cannot feed
  # stdin, so the payload goes in through a redirect.
  defp decide(ctx, command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ctx.root)
    payload = Jason.encode!(%{"cwd" => cwd, "tool_input" => %{"command" => command}})

    file =
      Path.join(System.tmp_dir!(), "fork-sync-payload-#{System.unique_integer([:positive])}.json")

    File.write!(file, payload)
    on_exit(fn -> File.rm(file) end)

    {out, _status} =
      System.cmd(
        "sh",
        ["-c", "bash #{quote_arg(ctx.hook)} push-gate --explain < #{quote_arg(file)}"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp status(ctx, cwd) do
    {out, _status} = System.cmd("bash", [ctx.hook, "status"], cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
end
