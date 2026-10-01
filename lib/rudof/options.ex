defmodule Rudof.Options do
  @moduledoc false

  @max_u64 18_446_744_073_709_551_615

  def validate(opts, rules) do
    if Keyword.keyword?(opts) do
      with :ok <- unique_keys(opts) do
        Enum.find_value(opts, :ok, fn {key, value} ->
          case Keyword.fetch(rules, key) do
            {:ok, rule} ->
              if not valid?(value, rule), do: error("invalid #{key}: #{inspect(value)}")

            :error ->
              error("unknown option: #{inspect(key)}")
          end
        end)
      end
    else
      error("options must be a keyword list")
    end
  end

  defp unique_keys(opts) do
    case Enum.find(Keyword.keys(opts), fn key ->
           Keyword.has_key?(Keyword.delete_first(opts, key), key)
         end) do
      nil -> :ok
      key -> error("duplicate option: #{inspect(key)}")
    end
  end

  def error(message), do: {:error, %Rudof.Error{kind: :invalid_argument, message: message}}

  defp valid?(value, :input) when is_binary(value), do: String.valid?(value)
  defp valid?(:stdin, :input), do: true

  defp valid?({kind, value}, :input) when kind in [:string, :file, :url],
    do: valid?(value, :string)

  defp valid?(_, :input), do: false
  defp valid?(nil, :optional_input), do: true
  defp valid?(value, :optional_input), do: valid?(value, :input)
  defp valid?(value, :inputs), do: is_list(value) and Enum.all?(value, &valid?(&1, :input))
  defp valid?(value, :string), do: is_binary(value) and String.valid?(value)
  defp valid?(nil, :optional_string), do: true
  defp valid?(value, :optional_string), do: valid?(value, :string)
  defp valid?(value, :strings), do: is_list(value) and Enum.all?(value, &valid?(&1, :string))
  defp valid?(value, :keyword), do: Keyword.keyword?(value)

  defp valid?(value, :positive_integer),
    do: is_integer(value) and value > 0 and value <= @max_u64

  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(nil, :optional_positive_integer), do: true

  defp valid?(value, :optional_positive_integer),
    do: valid?(value, :positive_integer)

  defp valid?(nil, :optional_u64), do: true

  defp valid?(value, :optional_u64),
    do: is_integer(value) and value >= 0 and value <= @max_u64

  defp valid?(value, choices) when is_list(choices), do: value in choices
end
