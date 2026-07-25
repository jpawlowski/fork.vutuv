defmodule VutuvWeb.EmailText do
  @moduledoc false
  require EEx
  import VutuvWeb.UserHelpers

  @template_dir "lib/vutuv_web/templates/email"

  # Compile all .text.eex templates into named functions at compile time.
  # Each template "foo.text.eex" becomes a function foo(assigns).
  # Templates starting with "_" are partials and are called via render/1.
  #
  # The wildcard is read once, at compile time, and `function_from_file/5`
  # registers each matched template as an `@external_resource` — so *editing* a
  # template recompiles this module, but *adding* one would not: the new file is
  # not yet a tracked resource, and nothing else in this file changed.
  #
  # `__mix_recompile__?/0` below closes that hole. Without it, adding a template
  # only works where the build happens to be thrown away, and **CI caches
  # `_build`** — which is exactly how the username-change PIN mail (issue #1086)
  # passed a full local `mix precommit` and then failed CI with
  # `function VutuvWeb.EmailText.username_change_email_en/1 is undefined`.
  @template_paths Path.wildcard(Path.join(@template_dir, "*.text.eex"))

  for path <- @template_paths do
    basename = Path.basename(path, ".text.eex")
    func_name = String.to_atom(basename)

    EEx.function_from_file(:def, func_name, path, [:assigns])
  end

  @doc false
  # Mix asks this before reusing the cached artifact: recompile whenever the
  # *set* of templates changed, not only when a tracked one was edited.
  def __mix_recompile__? do
    Path.wildcard(Path.join(@template_dir, "*.text.eex")) != @template_paths
  end

  @doc """
  Renders a text email template by name, e.g. render("login_email_en.text", assigns).
  """
  def render(template, assigns \\ %{}) do
    func =
      template
      |> String.trim_trailing(".text")
      |> String.to_existing_atom()

    apply(__MODULE__, func, [assigns])
  end
end
