defmodule SlipdockWeb.API.SkillsSignatureTest do
  @moduledoc """
  The skills archive's signature (#2784): a build the release job signed
  serves the bytes it signed at `/api/skills.tar.gz` and their signature at
  `/api/skills.tar.gz.sig`; any other build packs `priv/skills` itself and
  answers the signature with a 404, which the runner daemon reads as
  unsigned.
  """
  # Not async: it points the app's :skills_signed_dir at a folder of its own.
  use SlipdockWeb.ConnCase, async: false

  alias Slipdock.Skills

  @sig "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----\n"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "skills-signed-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    previous = Application.get_env(:slipdock, :skills_signed_dir)
    Application.put_env(:slipdock, :skills_signed_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :skills_signed_dir, previous),
        else: Application.delete_env(:slipdock, :skills_signed_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp sign(dir, bytes, sig \\ @sig) do
    File.write!(Path.join(dir, "slipdock-skills.tar.gz"), bytes)
    if sig, do: File.write!(Path.join(dir, "slipdock-skills.tar.gz.sig"), sig)
  end

  test "a signed build serves the bytes it signed and their signature, without a token", %{
    conn: conn,
    dir: dir
  } do
    sign(dir, "the release job's archive")

    archive = get(conn, ~p"/api/skills.tar.gz")
    assert response(archive, 200) == "the release job's archive"
    assert response_content_type(archive, :gzip) =~ "application/gzip"

    sig = get(build_conn(), ~p"/api/skills.tar.gz.sig")
    assert response(sig, 200) == @sig
    assert get_resp_header(sig, "cache-control") == ["no-cache"]
    assert Skills.signed_tarball() == {:ok, "the release job's archive", @sig}
  end

  test "an unsigned build packs priv/skills and says it has no signature with a 404", %{
    conn: conn
  } do
    archive = get(conn, ~p"/api/skills.tar.gz")
    {:ok, packed} = Skills.tarball()
    # Packed afresh each time, so compare what is in it, not the bytes.
    assert {:ok, files} =
             :erl_tar.extract({:binary, response(archive, 200)}, [:compressed, :memory])

    assert {:ok, ^files} = :erl_tar.extract({:binary, packed}, [:compressed, :memory])
    assert Enum.any?(files, fn {name, _} -> name == ~c"slipdock-loop/SKILL.md" end)

    sig = get(build_conn(), ~p"/api/skills.tar.gz.sig")
    assert response(sig, 404) =~ "not signed with the release key"
    assert Skills.signed_tarball() == :unsigned
  end

  test "an archive left without its signature is not served as signed", %{conn: conn, dir: dir} do
    sign(dir, "an archive with no signature", nil)

    assert Skills.signed_tarball() == :unsigned
    refute response(get(conn, ~p"/api/skills.tar.gz"), 200) == "an archive with no signature"
    assert response(get(build_conn(), ~p"/api/skills.tar.gz.sig"), 404) =~ "not signed"
  end
end
