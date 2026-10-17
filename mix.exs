defmodule RudofElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :rudof_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "RudofElixir",
      description: "Elixir bindings for rudof: RDF, SPARQL, ShEx and SHACL.",
      start_permanent: Mix.env() == :prod,
      compilers: [:rudof_native] ++ Mix.compilers(),
      deps: [
        {:rustler, "~> 0.38.0", runtime: false},
        {:ex_doc, "~> 0.38", only: :dev, runtime: false}
      ],
      docs: [main: "Rudof", extras: ["README.md", "API_COVERAGE.md", "KNOWN_ISSUES.md"]],
      package: [
        licenses: ["MIT"],
        build_tools: ["mix"],
        links: %{"Upstream rudof" => "https://github.com/rudof-project/rudof"},
        files: [
          "lib",
          "livebooks",
          "scripts",
          "mix.exs",
          "README.md",
          "API_COVERAGE.md",
          "KNOWN_ISSUES.md",
          "MULTIPLATFORM.md",
          "native/precompiled",
          "LICENSE",
          ".formatter.exs",
          "native/rudof_nif/Cargo.toml",
          "native/rudof_nif/Cargo.lock",
          "native/rudof_nif/LICENSE-RUDOF-MIT",
          "native/rudof_nif/src"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end

defmodule Mix.Tasks.Compile.RudofNative do
  use Mix.Task.Compiler

  def run(_) do
    if System.get_env("RUDOF_BUILD") in ["1", "true"] do
      {output, status} = System.cmd("bash", ["scripts/build_native.sh"], stderr_to_stdout: true)
      if status != 0, do: Mix.raise(output)
      Mix.shell().info(output)
    end

    if :erlang.system_info(:wordsize) != 8,
      do: Mix.raise("rudof_elixir requires a 64-bit Erlang runtime")

    os = :os.type()

    arch =
      if os == {:win32, :nt},
        do: System.get_env("PROCESSOR_ARCHITECTURE", "unknown"),
        else: to_string(:erlang.system_info(:system_architecture))

    target = target(os, arch)

    archive =
      System.get_env("RUDOF_ELIXIR_BUNDLE") || "native/precompiled/rudof-0.3.24-#{target}.tar.gz"

    unless File.regular?(archive),
      do:
        Mix.raise(
          "Missing #{target} Rudof bundle. See MULTIPLATFORM.md; RUDOF_BUILD=1 enables a local Rust build."
        )

    {:ok, _} = Application.ensure_all_started(:crypto)
    expected = File.read!(archive <> ".sha256") |> String.trim()
    actual = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    if actual != expected, do: Mix.raise("Rudof native archive checksum mismatch")
    extension = if os == {:win32, :nt}, do: "dll", else: "so"
    helper = if os == {:win32, :nt}, do: "rudof_render.exe", else: "rudof_render"

    installed? = fn ->
      File.read("priv/native/.bundle") == {:ok, expected} and
        Enum.all?(
          ["rudof_nif.#{extension}", helper],
          &File.regular?(Path.join("priv/native", &1))
        )
    end

    unless installed?.() do
      staging = "_build/.rudof-unpack-#{System.pid()}-#{System.unique_integer([:positive])}"
      File.mkdir_p!(staging)

      try do
        case :erl_tar.extract(String.to_charlist(archive), [
               :compressed,
               {:cwd, String.to_charlist(staging)}
             ]) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("Cannot unpack Rudof native bundle: #{inspect(reason)}")
        end

        native = Path.join(staging, "native")

        unless File.read(Path.join(native, "target")) == {:ok, target <> "\n"},
          do: Mix.raise("Rudof bundle does not match #{target}")

        unless Enum.all?(
                 ["rudof_nif.#{extension}", helper],
                 &File.regular?(Path.join(native, &1))
               ),
               do: Mix.raise("Rudof bundle is missing its NIF or renderer")

        File.write!(Path.join(native, ".bundle"), expected)

        unless installed?.() do
          File.rm_rf!("priv/native")
          File.mkdir_p!("priv")

          case File.rename(native, "priv/native") do
            :ok ->
              :ok

            {:error, reason} ->
              unless installed?.(),
                do: Mix.raise("Cannot install Rudof bundle: #{inspect(reason)}")
          end
        end
      after
        File.rm_rf!(staging)
      end
    end

    Mix.Project.build_structure()
    app_priv = Path.join(Mix.Project.app_path(), "priv")

    unless File.read(Path.join(app_priv, "native/.bundle")) == {:ok, expected},
      do: File.cp_r!("priv", app_priv)

    {:ok, []}
  end

  def clean do
    File.rm_rf!("priv/native")
    :ok
  end

  def target(os, arch) do
    cpu = arch |> String.split("-") |> hd()

    case {os, cpu, String.contains?(arch, "musl")} do
      {{:unix, :linux}, "x86_64", false} -> "linux-x86_64"
      {{:unix, :linux}, "aarch64", false} -> "linux-aarch64"
      {{:unix, :darwin}, "x86_64", false} -> "macos-x86_64"
      {{:unix, :darwin}, cpu, false} when cpu in ["arm64", "aarch64"] -> "macos-aarch64"
      {{:win32, :nt}, cpu, false} when cpu in ["AMD64", "amd64", "x86_64"] -> "windows-x86_64"
      _ -> Mix.raise("Unsupported Rudof platform: #{inspect(os)} / #{arch}. See MULTIPLATFORM.md")
    end
  end
end
