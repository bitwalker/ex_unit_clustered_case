defmodule ExUnit.ClusteredCase.Node.Ports.Port do
  @moduledoc false

  require Logger

  ## API

  # Fetch the captured log
  def get_captured_log(pid), do: server_call(pid, :get_captured_log)

  ## Server

  def child_spec(args) do
    %{id: __MODULE__, type: :worker, start: {__MODULE__, :start_link, [args]}}
  end

  def start_link([owner_pid, opts, owner_opts]) do
    :proc_lib.start_link(__MODULE__, :init, [self(), owner_pid, opts, owner_opts])
  end

  def init(parent, owner, opts, owner_opts) do
    Process.flag(:trap_exit, true)
    debug = :sys.debug_options([])
    port = open_port(opts)

    if Keyword.get(owner_opts, :link, false) do
      Process.link(owner)
    end

    stdout =
      case opts.stdout do
        o when o in [nil, false] ->
          false
        o when o in [:standard_error, :stderr] ->
          :standard_error
        o when o in [:standard_io, :stdio] ->
          :standard_io
        o when is_pid(o) ->
          o
        o ->
          Logger.warn "Invalid :stdout config option '#{inspect o}', no output will be logged"
          false
      end
    opts = %{opts | stdout: stdout}

    :proc_lib.init_ack(parent, {:ok, self()})
    loop(parent, debug, port, owner, opts, [])
  end

  defp open_port(opts) do
    # Open port
    erl = System.find_executable("erl")
    port_opts = [:stream | [env: opts.env, args: opts.erl_flags]]
    Port.open({:spawn_executable, erl}, port_opts)
  end

  defp loop(parent, debug, port, owner, opts, log) do
    name = opts.name
    heart? = opts.heart
    capture? = opts.capture_log
    stdout = opts.stdout

    receive do
      {:system, from, req} ->
        :sys.handle_system_msg(req, from, parent, __MODULE__, debug, {port, owner, opts, log})

      {:EXIT, ^parent, reason} ->
        exit(reason)

      {:EXIT, ^port, _reason} when heart? ->
        # If port closes and heart option is active, restart node
        port = open_port(opts)
        loop(parent, debug, port, owner, opts, log)

      {:EXIT, ^port, reason} ->
        # If heart option is not active, terminate when port closes
        exit(reason)

      {:EXIT, ^owner, reason} ->
        # If the owning process terminates, we terminate too
        exit(reason)

      # We're receiving logged output from the port
      # Do one of the following:
      {^port, {:data, data}} when capture? ->
        # Capture the output and also redirect to the given stdout device
        if stdout do
          write_output(stdout, ["#{name}: ", data])
        end
        loop(parent, debug, port, owner, opts, [data | log])

      {^port, {:data, _data}} when stdout == false ->
        # Suppress the logged output
        loop(parent, debug, port, owner, opts, log)

      {^port, {:data, data}} ->
        # Simply redirect to the given stdout device
        write_output(stdout, ["#{name}: ", data])
        loop(parent, debug, port, owner, opts, log)

      {from, :get_captured_log} when is_pid(from) ->
        data = log |> Enum.reverse |> IO.chardata_to_string()
        send(from, {self(), {:ok, data}})
        loop(parent, debug, port, owner, opts, [])

      msg ->
        Logger.warn("Unexpected message received by #{__MODULE__} for #{name}: #{inspect(msg)}")
        loop(parent, debug, port, owner, opts, log)
    end
  end

  # :sys callbacks

  @doc false
  def system_continue(parent, debug, {port, owner, opts, log}) do
    loop(parent, debug, port, owner, opts, log)
  end

  @doc false
  def system_get_state(state), do: {:ok, state}

  @doc false
  def system_replace_state(fun, state) do
    new_state = fun.(state)
    {:ok, new_state, new_state}
  end

  @doc false
  def system_code_change(state, _mod, _old, _extra) do
    {:ok, state}
  end

  @doc false
  def system_terminate(reason, _parent, _debug, _state) do
    reason
  end

  defp server_call(pid, msg, timeout \\ 10_000) do
    ref = Process.monitor(pid)
    send(pid, {self(), msg})
    receive do
      {:DOWN, ^ref, _type, _pid, _reason} ->
        exit({:noproc, {__MODULE__, :server_call, [pid, msg, timeout]}})
      {^pid, result} ->
        result
    after
      timeout ->
        exit({:timeout, {__MODULE__, :server_call, [pid, msg, timeout]}})
    end
  end

  defp write_output(device, content) when is_pid(device) or device in [:standard_error, :standard_io] do
    IO.puts(device, content)
  catch
    _, _ ->
    # If this fails, it means the device is already closed, so just pretend we're fine
    :ok
  end
end
