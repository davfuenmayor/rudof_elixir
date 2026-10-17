# Cell checks; check_livebooks.exs additionally uses Livebook's actual runtime.
root = Path.expand("..", __DIR__)
offline? = System.argv() == ["--offline"]
unless System.argv() in [[], ["--offline"]], do: raise("usage: [--offline]")
Mix.install([{:rudof_elixir, path: root}, {:kino, "== 0.19.0"}])

results =
  for path <- Path.wildcard(Path.join(root, "livebooks/**/*.livemd")) do
    text = File.read!(path)

    cells =
      Regex.scan(~r/^```elixir\n(.*?)^```/ms, text, capture: :all_but_first) |> List.flatten()

    Enum.each(cells, &Code.string_to_quoted!/1)
    name = Path.relative_to(path, root)

    cond do
      cells == [] ->
        IO.puts("REFERENCE #{name}")
        :ok

      offline? and Regex.match?(~r/Session\.(read_endpoint|load_service_description)\(/, text) ->
        IO.puts("NETWORK #{name}: not evaluated in --offline mode")
        :ok

      true ->
        parent = self()

        {pid, ref} =
          spawn_monitor(fn ->
            for _ <- 1..2 do
              # Dependency setup is identical to the checker's Mix.install call.
              initial = {[], Code.env_for_eval(file: path)}

              Enum.reduce(Enum.drop(cells, 1), initial, fn source, {binding, env} ->
                {_, binding, env} =
                  Code.eval_quoted_with_env(Code.string_to_quoted!(source), binding, env)

                {binding, env}
              end)
            end

            send(parent, {:passed, self()})
          end)

        receive do
          {:passed, ^pid} ->
            Process.demonitor(ref, [:flush])
            IO.puts("PASS #{name}: #{length(cells)} cells, twice")
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            IO.puts("FAIL #{name}: #{inspect(reason)}")
            :error
        after
          120_000 ->
            Process.exit(pid, :kill)
            IO.puts("FAIL #{name}: exceeded 120 seconds (including public endpoints)")
            :error
        end
    end
  end

if :error in results, do: raise("Livebook cell checks failed; see results above")
