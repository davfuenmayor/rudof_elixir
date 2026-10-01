defmodule Rudof.Session.Server do
  @moduledoc false
  use GenServer

  alias Rudof.{Error, Native}

  def start(config), do: GenServer.start(__MODULE__, {self(), config})

  def call(pid, request) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, {reason, {GenServer, :call, _args}} ->
      call_error(reason)
  end

  defp call_error(reason) when reason in [:normal, :shutdown, :noproc],
    do: {:error, %Error{kind: :closed, message: "session is closed"}}

  defp call_error(reason),
    do:
      {:error,
       %Error{
         kind: :server_failure,
         message:
           "session server stopped unexpectedly: #{inspect(reason, limit: 5, printable_limit: 200)}"
       }}

  def handle_result({:error, %Error{kind: kind}} = result, state)
      when kind in [:panic, :poisoned],
      do: {:stop, :normal, result, state}

  def handle_result(result, state), do: {:reply, result, state}

  @impl true
  def init({owner, config}) do
    monitor = Process.monitor(owner)

    case Native.new(config) do
      {:ok, ref} -> {:ok, %{ref: ref, monitor: monitor}}
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:close, _from, state) do
    result = Native.close(state.ref)
    {:stop, :normal, result, %{state | ref: nil}}
  end

  def handle_call({operation, args}, _from, state) do
    result =
      case {operation, args} do
        {:api_call, [name, options]} -> Rudof.Render.call(state.ref, name, options)
        _ -> apply(Native, operation, [state.ref | args])
      end

    handle_result(result, state)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{ref: nil}), do: :ok
  def terminate(_reason, %{ref: ref}), do: Native.close(ref)
end
