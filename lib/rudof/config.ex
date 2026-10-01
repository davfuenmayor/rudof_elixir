defmodule Rudof.Config do
  @moduledoc false
  alias Rudof.Options

  @keys [:path, :toml_str, :config]
  def keys, do: @keys
  def rules, do: [path: :string, toml_str: :string, config: :keyword]

  def encode(opts) do
    with :ok <- Options.validate(opts, rules()) do
      case opts do
        [] ->
          {:ok, nil}

        [{:config, values}] ->
          with {:ok, table} <- table(values), do: {:ok, JSON.encode!(%{config: table})}

        [{key, value}] ->
          {:ok, JSON.encode!(%{key => value})}

        _ ->
          Options.error("supply exactly one of :path, :toml_str, or :config")
      end
    end
  end

  defp table(values) do
    if length(Keyword.keys(values)) == length(Enum.uniq(Keyword.keys(values))) do
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case value(value) do
          {:ok, encoded} -> {:cont, {:ok, Map.put(acc, key, encoded)}}
          error -> {:halt, error}
        end
      end)
    else
      Options.error("duplicate configuration keys")
    end
  end

  defp value(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: Options.error("configuration strings must be UTF-8")
  end

  defp value(value) when is_boolean(value) or is_number(value),
    do: {:ok, value}

  defp value([]), do: {:ok, []}

  defp value(values) when is_list(values) do
    if Keyword.keyword?(values) do
      table(values)
    else
      Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
        case value(item) do
          {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end
  end

  defp value(value), do: Options.error("invalid configuration value: #{inspect(value)}")
end
