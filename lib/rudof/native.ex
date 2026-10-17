defmodule Rudof.Native do
  @moduledoc false
  use Rustler,
    otp_app: :rudof_elixir,
    crate: "rudof_nif",
    binaries: ["rudof_render"],
    skip_compilation?: true,
    load_from: {:rudof_elixir, "priv/native/rudof_nif"}

  def api_call(_session, _operation, _options), do: :erlang.nif_error(:nif_not_loaded)
  def object_text(_reference, _debug), do: :erlang.nif_error(:nif_not_loaded)

  def new(_config), do: :erlang.nif_error(:nif_not_loaded)
  def close(_session), do: :erlang.nif_error(:nif_not_loaded)
  def version(_session), do: :erlang.nif_error(:nif_not_loaded)
  def reset(_session, _kind), do: :erlang.nif_error(:nif_not_loaded)

  def list_endpoints(_session), do: :erlang.nif_error(:nif_not_loaded)
  def prefixes(_session), do: :erlang.nif_error(:nif_not_loaded)

  def prefix(_session, _operation, _alias, _value), do: :erlang.nif_error(:nif_not_loaded)

  def node_info(_session, _node, _opts), do: :erlang.nif_error(:nif_not_loaded)

  def node_neighborhood(_session, _node, _opts), do: :erlang.nif_error(:nif_not_loaded)
end
