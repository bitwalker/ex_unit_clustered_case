defmodule ExUnit.ClusteredCase.Node.Ports.Port do
  @moduledoc false

  require Logger

  def child_spec(args) do
    %{id: __MODULE__,
      type: :worker,
      start: {__MODULE__, :start_link, [args]}}
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
    :proc_lib.init_ack(parent, {:ok, self()})
    loop(parent, debug, port, owner, opts)
  end

  defp open_port(opts) do
    # Open port
    erl = System.find_executable("erl")
    port_opts = [:stream | [env: opts.env, args: opts.erl_flags]]
    Port.open({:spawn_executable, erl}, port_opts)
  end

  defp loop(parent, debug, port, owner, opts) do
    name = opts.name
    heart? = opts.heart
    receive do
      {:system, from, req} ->
        :sys.handle_system_msg(req, from, parent, __MODULE__, debug, {port, owner, opts})
      {:EXIT, ^parent, reason} ->
        exit(reason)
      {:EXIT, ^port, _reason} when heart? ->
        # If port closes and heart option is active, restart node
        port = open_port(opts)
        loop(parent, debug, port, owner, opts)
      {:EXIT, ^port, reason} ->
        # If heart option is not active, terminate when port closes
        exit(reason)
      {:EXIT, ^owner, reason} ->
        # If the owning process terminates, we terminate too
        exit(reason)
      {^port, {:data, data}} ->
        # We're receiving logged output from the port, relay it
        IO.puts(["#{name}: ", data])
        loop(parent, debug, port, owner, opts)
      msg ->
        Logger.warn "Unexpected message received by #{__MODULE__} for #{name}: #{inspect msg}"
        loop(parent, debug, port, owner, opts)
    end
  end

  # :sys callbacks

  @doc false
  def system_continue(parent, debug, {port, owner, opts}) do
    loop(parent, debug, port, owner, opts)
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
end
