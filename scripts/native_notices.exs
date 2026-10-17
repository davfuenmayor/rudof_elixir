[metadata, destination] = System.argv()
packages = File.read!(metadata) |> JSON.decode!() |> Map.fetch!("packages")
File.mkdir_p!(destination)

for package <- packages do
  root = Path.dirname(package["manifest_path"])
  name = "#{package["name"]}-#{package["version"]}"

  files =
    Path.wildcard(Path.join(root, "**/*"), match_dot: true)
    |> Enum.filter(fn file ->
      File.regular?(file) and
        Regex.match?(~r/^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$/i, Path.basename(file))
    end)

  files =
    if files == [] do
      Stream.iterate(root, &Path.dirname/1)
      |> Enum.take_while(&(&1 != Path.dirname(&1)))
      |> Enum.find_value([], fn dir ->
        found =
          Path.wildcard(Path.join(dir, "{LICENSE,LICENSE-*,LICENSE.*,COPYING,NOTICE}"))
          |> Enum.filter(&File.regular?/1)

        if found != [], do: found
      end)
    else
      files
    end

  for file <- files do
    relative =
      if String.starts_with?(file, root <> "/"),
        do: Path.relative_to(file, root),
        else: Path.basename(file)

    output = Path.join([destination, name, relative])
    File.mkdir_p!(Path.dirname(output))
    File.cp!(file, output)
  end
end

File.write!(
  Path.join(destination, "DEPENDENCIES.txt"),
  Enum.map_join(packages, "\n", fn package ->
    "#{package["name"]} #{package["version"]} | #{package["license"] || "See license files"} | #{package["source"] || "local wrapper"}"
  end) <> "\n"
)
