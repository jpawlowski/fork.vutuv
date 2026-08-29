defmodule Vutuv.AvatarMemoTest do
  @moduledoc """
  `Vutuv.Avatar.binary/2` opens the original and runs the whole libvips
  pipeline, so a document that renders the same picture twice must pay once.

  Not async: these set the global `:uploads_dir_prefix` (the constraint
  `Vutuv.UploadsIntegrationTest` carries) and share the app-wide memo table.
  Sharing it is safe because a key is `{user_id, version, fingerprint}` and
  every test mints its own member.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Avatar
  alias Vutuv.Repo
  alias Vutuv.Uploads.AvatarCache

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_avatar_memo_#{System.unique_integer([:positive])}")
    prev = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    AvatarCache.reset()

    on_exit(fn ->
      File.rm_rf(tmp)
      AvatarCache.reset()

      case prev do
        {:ok, was} -> Application.put_env(:vutuv, :uploads_dir_prefix, was)
        :error -> Application.delete_env(:vutuv, :uploads_dir_prefix)
      end
    end)

    user = insert(:activated_user, avatar: "me.jpg", avatar_fingerprint: "fp-one")
    write_original(tmp, user, [10, 120, 200])

    {:ok, user: user, tmp: tmp}
  end

  defp write_original(tmp, user, colour) do
    dir = Path.join(tmp, "originals/avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(600, 600, color: colour)
    {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))
    dir
  end

  # Every claim below is made by taking the original away rather than by
  # timing. `Avatar.binary/2` resolves the file with a wildcard before libvips
  # is involved, so a deleted original can only produce the placeholder — a
  # read that still returns the photo can only have come from the memo, and one
  # that returns the placeholder can only have derived. libvips keeps an
  # operation cache of its own keyed by filename and mtime, which makes any
  # relative cost bound here measure that cache as much as ours.
  defp original_dir(ctx), do: Path.join(ctx.tmp, "originals/avatars/#{ctx.user.id}")

  defp photo?(uri), do: String.starts_with?(uri, "data:image/jpeg;base64,")

  test "the same picture is derived once and remembered", ctx do
    first = Avatar.binary(ctx.user, :medium)
    assert photo?(first)

    File.rm_rf!(original_dir(ctx))
    assert Avatar.binary(ctx.user, :medium) == first
  end

  test "a changed fingerprint is a different key, so the next read derives again", ctx do
    assert photo?(Avatar.binary(ctx.user, :medium))

    File.rm_rf!(original_dir(ctx))

    changed =
      ctx.user
      |> Ecto.Changeset.change(%{avatar_fingerprint: "fp-two"})
      |> Repo.update!()

    refute photo?(Avatar.binary(changed, :medium)),
           "a changed fingerprint was answered from the memo"
  end

  test "a row with no fingerprint is never remembered", ctx do
    unkeyed =
      ctx.user
      |> Ecto.Changeset.change(%{avatar_fingerprint: nil})
      |> Repo.update!()

    assert photo?(Avatar.binary(unkeyed, :medium))

    File.rm_rf!(original_dir(ctx))

    # Nothing would tell us that picture changed, so remembering it would be a
    # promise we cannot keep.
    refute photo?(Avatar.binary(unkeyed, :medium)),
           "an avatar with no fingerprint was remembered anyway"
  end

  test "a picture waiting for the scan is answered before the memo is consulted", ctx do
    pending = %{ctx.user | avatar_moderation: "pending"}
    placeholder = Avatar.binary(pending, :medium)

    approved = %{ctx.user | avatar_moderation: "approved"}
    assert Avatar.binary(approved, :medium) != placeholder
  end

  test "with no table at all every read simply derives", ctx do
    assert AvatarCache.lookup({ctx.user.id, :medium, "fp-one"}, :no_such_table) == :miss
    assert photo?(Avatar.binary(ctx.user, :medium))
  end
end
