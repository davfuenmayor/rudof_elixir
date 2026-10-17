defmodule Rudof.NativeBundleTest do
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @compiler Mix.Tasks.Compile.RudofNative

  test "selects only supported 64-bit native targets" do
    for {os, arch, expected} <- [
          {{:unix, :linux}, "x86_64-pc-linux-gnu", "linux-x86_64"},
          {{:unix, :linux}, "aarch64-unknown-linux-gnu", "linux-aarch64"},
          {{:unix, :darwin}, "x86_64-apple-darwin", "macos-x86_64"},
          {{:unix, :darwin}, "arm64-apple-darwin", "macos-aarch64"},
          {{:win32, :nt}, "AMD64", "windows-x86_64"}
        ] do
      assert @compiler.target(os, arch) == expected
    end

    for {os, arch} <- [
          {{:unix, :linux}, "x86_64-unknown-linux-musl"},
          {{:unix, :linux}, "i686-pc-linux-gnu"},
          {{:win32, :nt}, "ARM64"}
        ] do
      assert_raise Mix.Error, ~r/Unsupported Rudof platform/, fn -> @compiler.target(os, arch) end
    end
  end

  @tag :tmp_dir
  test "installed app and renderer work after relocation in a fresh VM", %{tmp_dir: dir} do
    app = Path.join([dir, "moved app", "rudof_elixir-0.1.0"])
    File.mkdir_p!(Path.join(app, "priv"))
    File.cp_r!(Application.app_dir(:rudof_elixir, "ebin"), Path.join(app, "ebin"))
    File.cp_r!(Application.app_dir(:rudof_elixir, "priv/native"), Path.join(app, "priv/native"))

    code = """
    {:ok, _} = Application.ensure_all_started(:rudof_elixir)
    {:ok, %{kind: :ask, boolean: true}} =
      Rudof.query("<http://e/s> <http://e/p> 42 .", "ASK { ?s ?p ?o }")
    helper = Application.app_dir(:rudof_elixir, "priv/native/rudof_render#{if :os.type() == {:win32, :nt}, do: ".exe", else: ""}")
    {output, 1} = System.cmd(helper, [], stderr_to_stdout: true)
    true = String.contains?(output, "expected snapshot and output filenames")
    """

    assert {_, 0} =
             System.cmd(
               System.find_executable("elixir"),
               ["--erl", "+S 1:1", "-pa", Path.join(app, "ebin"), "-e", code],
               cd: dir,
               stderr_to_stdout: true
             )
  end

  @tag :tmp_dir
  test "installs without Cargo and restores a missing payload", %{tmp_dir: dir} do
    archive = project(dir)
    bundle(archive, target())
    assert {_, 0} = install(dir)
    assert File.read!(Path.join(dir, "priv/native/rudof_nif.#{extension()}")) == "fixture NIF"
    assert {_, 0} = install(dir)
    File.rm!(Path.join(dir, "priv/native/rudof_nif.#{extension()}"))
    assert {_, 0} = install(dir)
    assert File.regular?(Path.join(dir, "priv/native/rudof_nif.#{extension()}"))
  end

  @tag :tmp_dir
  test "rejects corrupted archives before installation", %{tmp_dir: dir} do
    archive = project(dir)
    bundle(archive, target())
    File.write!(archive, "tampered", [:append])
    assert {output, status} = install(dir)
    assert status != 0
    assert output =~ "checksum mismatch"
    refute File.exists?(Path.join(dir, "priv/native"))
  end

  @tag :tmp_dir
  test "rejects wrong-target and incomplete archives", %{tmp_dir: dir} do
    archive = project(dir)
    bundle(archive, "wrong-target")
    assert {output, status} = install(dir)
    assert status != 0
    assert output =~ "does not match"
    refute File.exists?(Path.join(dir, "priv/native"))

    bundle(archive, target(), false)
    assert {output, status} = install(dir)
    assert status != 0
    assert output =~ "missing its NIF or renderer"
    refute File.exists?(Path.join(dir, "priv/native"))
  end

  defp target do
    arch =
      if :os.type() == {:win32, :nt},
        do: System.fetch_env!("PROCESSOR_ARCHITECTURE"),
        else: to_string(:erlang.system_info(:system_architecture))

    @compiler.target(:os.type(), arch)
  end

  defp extension, do: if(:os.type() == {:win32, :nt}, do: "dll", else: "so")

  defp project(dir) do
    File.cp!(Path.join(@root, "mix.exs"), Path.join(dir, "mix.exs"))
    archive = Path.join(dir, "native/precompiled/rudof-0.3.24-#{target()}.tar.gz")
    File.mkdir_p!(Path.dirname(archive))
    archive
  end

  defp bundle(archive, platform, complete? \\ true) do
    helper = if :os.type() == {:win32, :nt}, do: "rudof_render.exe", else: "rudof_render"
    files = [{~c"native/target", platform <> "\n"}]

    files =
      if complete?,
        do:
          files ++
            [
              {String.to_charlist("native/rudof_nif.#{extension()}"), "fixture NIF"},
              {String.to_charlist("native/#{helper}"), "fixture helper"}
            ],
        else: files

    :ok = :erl_tar.create(String.to_charlist(archive), files, [:compressed])
    hash = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    File.write!(archive <> ".sha256", hash <> "\n")
  end

  defp install(dir) do
    code = "Mix.start(); Code.require_file(\"mix.exs\"); Mix.Tasks.Compile.RudofNative.run([])"

    System.cmd(System.find_executable("elixir"), ["--erl", "+S 1:1", "-e", code],
      cd: dir,
      stderr_to_stdout: true,
      env: [{"RUDOF_BUILD", nil}, {"RUDOF_ELIXIR_BUNDLE", nil}]
    )
  end
end
