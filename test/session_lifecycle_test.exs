defmodule Rudof.SessionLifecycleTest do
  use ExUnit.Case, async: true

  alias Rudof.{Error, Native, Session}
  alias Rudof.Session.Server

  setup do
    session = Session.new!()
    on_exit(fn -> Session.close(session) end)
    %{session: session}
  end

  test "close releases native state and terminates the server", %{session: s} do
    %{ref: ref} = :sys.get_state(s.pid)
    monitor = Process.monitor(s.pid)

    assert :ok = Session.close(s)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert {:error, %Error{kind: :closed}} = Native.version(ref)
    assert :ok = Session.close(s)
  end

  for reason <- [:normal, :kill] do
    test "creator exiting with #{reason} releases native state" do
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:created, Session.new!()})

          receive do
            :done -> :ok
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:created, s}, 5_000
      %{ref: ref} = :sys.get_state(s.pid)
      monitor = Process.monitor(s.pid)

      case unquote(reason) do
        :normal -> send(owner, :done)
        :kill -> Process.exit(owner, :kill)
      end

      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5_000
      assert {:error, %Error{kind: :closed}} = Native.version(ref)
      assert {:error, %Error{kind: :closed}} = Session.version(s)
    end
  end

  test "a session cannot outlive the Task that created it" do
    s = Task.async(fn -> Session.new!() end) |> Task.await()
    monitor = Process.monitor(s.pid)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert {:error, %Error{kind: :closed}} = Session.version(s)
  end

  test "borrowers exiting do not close their creator's session", %{session: s} do
    assert {:ok, "0.3.24"} = Task.async(fn -> Session.version(s) end) |> Task.await()
    assert {:ok, "0.3.24"} = Session.version(s)
  end

  test "server failure does not exit the creator or callers", %{session: s} do
    monitor = Process.monitor(s.pid)
    Process.exit(s.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert {:error, %Error{kind: :closed}} = Session.version(s)
    assert :ok = Session.close(s)
  end

  test "a caller already waiting receives a closed error if the server dies", %{session: s} do
    :sys.suspend(s.pid)

    try do
      task =
        Task.async(fn ->
          receive do
            :go -> Session.version(s)
          end
        end)

      # Observe the actual call being sent, rather than sleep and hope it queued.
      :erlang.trace(task.pid, true, [:send])
      send(task.pid, :go)
      caller = task.pid
      server = s.pid
      assert_receive {:trace, ^caller, :send, {:"$gen_call", _, {:version, []}}, ^server}, 5_000
      Process.exit(server, :kill)
      assert {:error, %Error{kind: :server_failure, message: message}} = Task.await(task)
      assert message =~ "killed"
    after
      if Process.alive?(s.pid), do: :sys.resume(s.pid)
    end
  end

  test "concurrent closes are idempotent", %{session: s} do
    monitor = Process.monitor(s.pid)
    results = 1..16 |> Task.async_stream(fn _ -> Session.close(s) end) |> Enum.to_list()
    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
  end

  test "queued calls preserve order and do not prevent another session from running", %{
    session: s
  } do
    # Suspending the owner gives us a deterministic queue, without timing a
    # deliberately slow NIF or relying on machine-specific scheduler counts.
    :ok = :sys.suspend(s.pid)

    requests =
      for n <- 1..8,
          operation <- [
            {:api_call,
             [
               "load_data",
               %{inputs: ["<http://e/s> <http://e/p> #{n} ."], format: :turtle, merge: false}
             ]},
            {:api_call, ["query", %{input: "ASK { <http://e/s> <http://e/p> #{n} }"}]}
          ] do
        :gen_server.send_request(s.pid, operation)
      end

    try do
      {:messages, messages} = Process.info(s.pid, :messages)
      assert Enum.count(messages, &match?({:"$gen_call", _, _}, &1)) == 16
      assert {:ok, "0.3.24"} = Session.with_session(&Session.version/1)
    after
      :sys.resume(s.pid)
    end

    for [read, query] <- Enum.chunk_every(requests, 2) do
      assert {:reply, {:ok, :ok}} = :gen_server.wait_response(read, 10_000)
      assert {:reply, {:ok, %{boolean: true}}} = :gen_server.wait_response(query, 10_000)
    end
  end

  test "invalid arguments are rejected before joining the queue", %{session: s} do
    :sys.suspend(s.pid)

    try do
      assert {:error, %Error{kind: :invalid_argument}} = Session.read_data(s, "", format: :bad)

      assert {:error, %Error{message: message}} =
               Session.read_data(s, "", merge: true, merge: false)

      assert message =~ "duplicate option: :merge"
      assert {:messages, []} = Process.info(s.pid, :messages)
    after
      :sys.resume(s.pid)
    end
  end

  test "fatal native errors stop the server while ordinary errors keep it alive", %{session: s} do
    state = :sys.get_state(s.pid)

    for kind <- [:panic, :poisoned] do
      result = {:error, %Error{kind: kind, message: "native failure"}}
      assert {:stop, :normal, ^result, ^state} = Server.handle_result(result, state)
    end

    error = {:error, %Error{kind: :data_error, message: "bad input"}}
    assert {:reply, ^error, ^state} = Server.handle_result(error, state)
    assert Process.alive?(s.pid)
  end

  test "borrowers can observe each other's changes between calls", %{session: s} do
    assert :ok = Session.read_data(s, "<http://e/a> <http://e/p> 1 .", merge: false)
    assert :ok = Session.read_data(s, "<http://e/b> <http://e/p> 2 .", merge: false)

    assert {:ok, %{boolean: false}} =
             Session.query(s, "ASK { <http://e/a> <http://e/p> 1 }")
  end

  test "with_session closes on throw and exit as well as exceptions" do
    assert catch_throw(
             Session.with_session(fn s ->
               send(self(), {:thrown, s})
               throw(:done)
             end)
           ) == :done

    assert catch_exit(
             Session.with_session(fn s ->
               send(self(), {:exited, s})
               exit(:done)
             end)
           ) == :done

    for tag <- [:thrown, :exited] do
      assert_received {^tag, s}
      monitor = Process.monitor(s.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}
      assert {:error, %Error{kind: :closed}} = Session.version(s)
    end
  end

  test "ordinary native errors leave the session usable", %{session: s} do
    assert {:error, %Error{kind: :data_error}} = Session.read_data(s, "broken Turtle")
    assert {:ok, "0.3.24"} = Session.version(s)
    assert :ok = Session.read_data(s, "<http://e/s> <http://e/p> 1 .")
    assert {:ok, %{boolean: true}} = Session.query(s, "ASK { ?s ?p ?o }")
  end

  test "the shared native serializer rejects unfinished upstream formats without poisoning", %{
    session: s
  } do
    assert :ok = Session.read_data(s, "<http://e/s> <http://e/p> 1 .")
    assert :ok = Session.read_shex(s, "<http://e/S> { <http://e/p> . }")
    assert :ok = Session.read_shapemap(s, "<http://e/s>@<http://e/S>")
    %{ref: ref} = :sys.get_state(s.pid)
    monitor = Process.monitor(s.pid)

    assert {:error, %Error{kind: :unsupported_operation}} =
             Server.call(s.pid, {:api_call, ["serialize_shapemap", %{format: :csv}]})

    assert {:ok, "0.3.24"} = Native.version(ref)
    assert {:ok, "0.3.24"} = Session.version(s)
    assert :ok = Session.close(s)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5_000
    assert {:error, %Error{kind: :closed}} = Native.version(ref)
    assert {:error, %Error{kind: :closed}} = Session.version(s)
    assert :ok = Session.close(s)
  end

  test "unrelated messages do not disrupt the session", %{session: s} do
    send(s.pid, :unrelated)
    send(s.pid, {:DOWN, make_ref(), :process, self(), :normal})
    assert {:ok, "0.3.24"} = Session.version(s)
  end
end
