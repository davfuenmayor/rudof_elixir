defmodule Rudof.Object do
  @moduledoc "An immutable native snapshot of a Rust object without a Serde representation.\nSHACL IR and property-graph schema getters return these snapshots. They remain\nvalid after the session is reset or closed. `text/2` uses upstream Display or\nDebug; no schema is reconstructed in Elixir.\n"
  @enforce_keys [:kind, :reference]
  defstruct [:kind, :reference]

  @doc "Formats the native snapshot. Set `debug: true` for upstream Debug output."
  def text(%Rudof.Object{reference: reference}, opts \\ []) do
    with :ok <- Rudof.Options.validate(opts, debug: :boolean) do
      Rudof.Native.object_text(reference, Keyword.get(opts, :debug, false))
    end
  end
end
