defmodule Vutuv.PrecommitHookTest do
  @moduledoc """
  `.claude/hooks/precommit-before-push.sh` is the last automatic gate before a
  push, and a push to `main` auto-deploys to production. It shipped with two
  defects that this covers (both found 2026-08-02):

    * it ran `mix precommit` in `$CLAUDE_PROJECT_DIR` rather than in the
      worktree the push came from, so with several worktrees on one repository
      it could report green for code it had never compiled;
    * it recognised a push by the substring `"git push"`, which blocked a plain
      `grep "git push"` and, far worse, missed `git -C <dir> push` entirely.

  The three shapes asserted here are the ones a guard like this fails in:
  the exemption belonging to a *different* unit of the command line, the
  forbidden effect spelled a way the rule does not literally name, and a
  degraded path (missing dependency, unresolvable directory) that must fail
  closed rather than wave the push through.

  The hook's `--explain` mode prints its decision without running precommit;
  that mode exists for this test, and the settings.json invocation passes no
  arguments so it can never be reached in normal use.
  """
  use ExUnit.Case, async: true

  @hook ".claude/hooks/precommit-before-push.sh"

  setup do
    root = File.cwd!()
    {:ok, root: root, hook: Path.join(root, @hook)}
  end

  describe "commands that are not a push" do
    test "an ordinary command is allowed", ctx do
      assert decide(ctx, "echo hello") == "ALLOW"
    end

    test "a command that merely mentions the words is allowed", ctx do
      # The exemption belongs to a different unit: `git push` appears as grep's
      # argument, not as the command being run. The substring match blocked this.
      assert decide(ctx, ~s{grep -rn "git push" .claude/}) == "ALLOW"
      assert decide(ctx, ~s{echo "run git push when done"}) == "ALLOW"
    end

    test "other git subcommands are allowed", ctx do
      assert decide(ctx, "git status") == "ALLOW"
      assert decide(ctx, "git log --oneline") == "ALLOW"
      assert decide(ctx, "git log --grep push") == "ALLOW"
    end
  end

  describe "pushes, however they are spelled" do
    test "a plain push resolves to the tool call's own directory", ctx do
      assert decide(ctx, "git push") == "PUSH #{ctx.root}"
      assert decide(ctx, "git push origin main") == "PUSH #{ctx.root}"
    end

    test "`git -C <dir> push` is a push and names its own tree", ctx do
      # The spelling the old substring rule could not see at all.
      assert decide(ctx, "git -C #{ctx.root} push") == "PUSH #{ctx.root}"
      assert decide(ctx, "git -C#{ctx.root} push origin HEAD") == "PUSH #{ctx.root}"
    end

    test "a push behind a chain operator is still a push", ctx do
      assert decide(ctx, "mix test && git push") == "PUSH #{ctx.root}"
      assert decide(ctx, "echo one; git push") == "PUSH #{ctx.root}"
    end

    test "a leading cd governs the push that follows it", ctx do
      assert decide(ctx, "cd #{ctx.root} && git push") == "PUSH #{ctx.root}"
    end

    test "environment assignments before git do not hide the push", ctx do
      assert decide(ctx, "GIT_TRACE=1 git push") == "PUSH #{ctx.root}"
    end

    test "global options that swallow a word do not hide the push", ctx do
      assert decide(ctx, "git -c user.name=x push") == "PUSH #{ctx.root}"
    end
  end

  describe "degraded paths fail closed" do
    test "an unresolvable working directory blocks instead of allowing", ctx do
      decision = decide(ctx, "git push", cwd: "/nonexistent/worktree")

      assert decision =~ "BLOCK",
             "a push whose tree cannot be resolved must be blocked, got: #{decision}"

      assert decision =~ "cannot tell which git worktree"
    end

    test "a push from a tree that is not the project blocks", ctx do
      # Resolvable as a git repo is not enough — it must be the vutuv checkout,
      # or precommit would vouch for the wrong thing.
      tmp =
        System.tmp_dir!()
        |> Path.join("precommit-hook-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {_, 0} = System.cmd("git", ["init", "--quiet", tmp])

      decision = decide(ctx, "git -C #{tmp} push")

      assert decision =~ "BLOCK", "expected a block, got: #{decision}"
      assert decision =~ "not the vutuv project root"
    end

    test "without jq a push is refused rather than waved through", ctx do
      # The dependency this hook reads its input with, removed. Silence must
      # mean "block", never "allow".
      path = path_without_jq()

      assert decide(ctx, "git push", path: path) =~ "BLOCK"
      assert decide(ctx, "git push", path: path) =~ "jq"
      # A harmless command still gets through, so a missing jq does not brick
      # every Bash call in the session.
      assert decide(ctx, "echo hello", path: path) == "ALLOW"
    end
  end

  describe "the fork freshness check that runs before precommit" do
    # A branch that was never rebased onto the canonical repository's `main`
    # collides on the version number without producing a merge conflict, so
    # spending five minutes of `mix precommit` on it is wasted either way.
    # These drive the real path, not `--explain`: the check blocks before
    # `mix precommit` is ever reached, so no build happens here.
    test "a fork with no remote for the canonical repository is blocked", ctx do
      repo = fake_project("https://github.com/someone/vutuv.git")

      decision = run(ctx, "git -C #{repo} push")

      assert decision =~ "BLOCKED"
      assert decision =~ "./scripts/fork_setup.sh"
    end

    test "a clone of the canonical repository is untouched", ctx do
      # The one case that must never regress: whoever works on this repository
      # directly sees none of this. Proven by the push getting past the check
      # and into `mix precommit` — stubbed here so no build runs.
      repo = fake_project("https://github.com/wintermeyer/vutuv.git")

      # Reaching the (stubbed) precommit run is the proof it got past the check.
      decision = run(ctx, "git -C #{repo} push", path: path_with_stub_mise())

      assert decision =~ "Running mix precommit"
      refute decision =~ "BLOCKED"
    end

    test "a fork can opt out", ctx do
      repo = fake_project("https://github.com/someone/vutuv.git")
      {_, 0} = System.cmd("git", ["config", "vutuv.fork-sync", "false"], cd: repo)

      # Reaching the (stubbed) precommit run is the proof it got past the check.
      decision = run(ctx, "git -C #{repo} push", path: path_with_stub_mise())

      assert decision =~ "Running mix precommit"
      refute decision =~ "BLOCKED"
    end
  end

  # A throwaway repository that looks enough like this project for the hook to
  # accept it (it insists on a `mix.exs`), with the given `origin`.
  defp fake_project(origin_url) do
    dir = Path.join(System.tmp_dir!(), "precommit-fork-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "mix.exs"), "# fixture\n")
    {_, 0} = System.cmd("git", ["init", "--quiet", dir])
    {_, 0} = System.cmd("git", ["remote", "add", "origin", origin_url], cd: dir)
    dir
  end

  # The hook shells out to `mise exec -- mix precommit`; a stub that exits 0
  # stands in for it so a passing check does not trigger a real build.
  defp path_with_stub_mise do
    dir = Path.join(System.tmp_dir!(), "precommit-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for tool <- ~w(bash sh awk git cat sed grep env jq) do
      case System.find_executable(tool) do
        nil -> :ok
        path -> File.ln_s!(path, Path.join(dir, tool))
      end
    end

    File.write!(Path.join(dir, "mise"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(dir, "mise"), 0o755)
    dir
  end

  # Like `decide/3` but without `--explain`, so the checks actually run.
  defp run(ctx, command, opts \\ []) do
    decide(ctx, command, Keyword.put(opts, :explain, false))
  end

  # Runs the hook in `--explain` mode against a payload and returns its verdict.
  # `System.cmd/3` cannot feed stdin, so the payload goes in through a file
  # redirect run by `sh`.
  defp decide(ctx, command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ctx.root)
    payload = Jason.encode!(%{"cwd" => cwd, "tool_input" => %{"command" => command}})

    payload_file =
      Path.join(
        System.tmp_dir!(),
        "precommit-hook-payload-#{System.unique_integer([:positive])}.json"
      )

    File.write!(payload_file, payload)
    on_exit(fn -> File.rm(payload_file) end)

    env =
      case Keyword.fetch(opts, :path) do
        {:ok, path} -> [{"PATH", path}]
        :error -> []
      end

    flag = if Keyword.get(opts, :explain, true), do: " --explain", else: ""
    script = "bash #{shell_quote(ctx.hook)}#{flag} < #{shell_quote(payload_file)}"

    {out, _status} =
      System.cmd("sh", ["-c", script], cd: ctx.root, env: env, stderr_to_stdout: true)

    String.trim(out)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  # A PATH holding every binary the hook needs except `jq`.
  defp path_without_jq do
    dir =
      Path.join(
        System.tmp_dir!(),
        "precommit-hook-nojq-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for tool <- ~w(bash sh awk git cat sed grep env) do
      case System.find_executable(tool) do
        nil -> :ok
        path -> File.ln_s!(path, Path.join(dir, tool))
      end
    end

    dir
  end
end
