defmodule Rudof.Render do
  @moduledoc false
  alias Rudof.{Error, Native}

  # Run external renderers in a subprocess so the BEAM does not manage their
  # child processes or signals.
  def call(reference, operation, options) do
    if image?(operation, options) do
      request = Map.put(options, :operation, operation)

      with {:ok, snapshot} <- Native.api_call(reference, "render_snapshot", JSON.encode!(request)),
           do: render(snapshot, operation)
    else
      Native.api_call(reference, operation, JSON.encode!(options))
    end
  end

  defp image?(operation, %{format: format})
       when operation in ["serialize_data", "serialize_shex_schema"] and format in [:svg, :png],
       do: true

  defp image?("show_schema_conversion", %{from: from, to: :uml, output_format: format})
       when from in [:shex, :dctap] and format in [:svg, :png],
       do: true

  defp image?(_operation, _options), do: false

  defp render(snapshot, operation) do
    kind =
      case operation do
        "serialize_data" -> :data_error
        "serialize_shex_schema" -> :shex_error
        _ -> :conversion_error
      end

    dir =
      Path.join(
        System.tmp_dir!(),
        "rudof-render-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    try do
      File.mkdir!(dir)
      if match?({:unix, _}, :os.type()), do: File.chmod!(dir, 0o700)
      input = Path.join(dir, "snapshot.json")
      output = Path.join(dir, "image")
      File.write!(input, snapshot)
      suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""
      helper = Application.app_dir(:rudof_elixir, "priv/native/rudof_render" <> suffix)

      case System.cmd(helper, [input, output], stderr_to_stdout: true) do
        {_, 0} ->
          {:ok, File.read!(output)}

        {message, status} ->
          {:error, %Error{kind: kind, message: "native renderer exited #{status}: #{message}"}}
      end
    rescue
      error -> {:error, %Error{kind: kind, message: Exception.message(error)}}
    after
      File.rm_rf(dir)
    end
  end
end
