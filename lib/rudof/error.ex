defmodule Rudof.Error do
  @moduledoc """
  Exception struct returned in `{:error, error}` results or raised by a bang function.

  `kind` identifies the failure category, such as `:invalid_argument`, `:closed`,
  `:server_failure`, `:panic`, or an operation-specific error. `message` contains
  the explanation from the wrapper or upstream Rust library. Inspect these fields
  to handle a specific failure; validation results with `conforms: false` are
  successful results, not errors.
  """
  defexception [:kind, :message]
end
