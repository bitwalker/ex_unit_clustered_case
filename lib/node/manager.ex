defmodule ExUnit.ClusteredCase.Node.Manager do
  @moduledoc false
  require Logger

  alias ExUnit.ClusteredCaseError
  alias ExUnit.ClusteredCase.Utils
  alias ExUnit.ClusteredCase.Node.Agent, as: NodeAgent
  alias ExUnit.ClusteredCase.Node.Ports

  defstruct [
    :name,
    :cookie,
    :manager_name,
    :agent_name,
    :heart,
    :boot_timeout,
    :init_timeout,
    :post_start_functions,
    :erl_flags,
    :env,
    :config,
    :port,
    :capture_log,
    :stdout,
    :alive?
  ]

  @doc """
  Converts a given node name into the name of the associated manager process
  """
  def name_of(name), do: Utils.nodename(name)

  @doc """
  Starts a new node and it's corresponding management process
  """
  @spec start_link(ExUnit.ClusteredCase.Node.node_opts()) :: {:ok, pid} | {:error, term}
  def start_link(opts) do
    :proc_lib.start_link(__MODULE__, :init, [self(), opts])
  end

  @doc """
  Same as `start_link/1`, but does not link the process
  """
  @spec start_nolink(ExUnit.ClusteredCase.Node.node_opts()) :: {:ok, pid} | {:error, term}
  def start_nolink(opts) do
    :proc_lib.start(__MODULE__, :init, [self(), opts])
  end

  @doc """
  Instructs the manager to terminate the given node
  """
  def stop(name), do: server_call(name, :stop)

  @doc """
  Instructs the manager to terminate the given node brutally.
  """
  def kill(name), do: server_call(name, :kill)

  @doc """
  Returns the name of the node managed by the given process
  """
  def name(name) when is_pid(name), do: server_call(name, :get_name)

  @doc """
  Returns the captured log output of the given node.

  If the node was not configured to capture logs, this will be an empty string.
  """
  def log(name) do 
    port = server_call(name, :get_port_pid)
    Ports.get_captured_log(port)
  end

  @doc """
  Determines if the given node is alive or dead
  """
  def alive?(name) do
    server_call(name, :is_alive)
  rescue
    ArgumentError ->
      false
  end

  @doc """
  Runs the given function on a node by spawning a process remotely with it
  """
  def call(name, fun, opts \\ [])

  def call(name, fun, opts) when is_function(fun) do
    server_call(name, {:spawn_fun, fun, opts})
  end

  def call(name, {m, f, a}, opts), do: call(name, m, f, a, opts)

  @doc """
  Applies the given module/function/args on the given node and returns the result
  """
  def call(name, m, f, a, opts \\ []) when is_atom(m) and is_atom(f) and is_list(a) do
    server_call(name, {:apply, m, f, a, opts})
  end

  @doc """
  Connects a node to other nodes in the given list
  """
  def connect(name, nodes) when is_list(nodes) do
    nodes =
      for n <- nodes do
        if is_pid(n) do
          name(n)
        else
          Utils.nodename(n)
        end
      end

    server_call(name, {:connect, nodes})
  end

  @doc """
  Disconnects a node to other nodes in the given list
  """
  def disconnect(name, nodes) when is_list(nodes) do
    nodes =
      for n <- nodes do
        if is_pid(n) do
          name(n)
        else
          Utils.nodename(n)
        end
      end

    server_call(name, {:disconnect, nodes})
  end

  @doc false
  def init(parent, opts) do
    Process.flag(:trap_exit, true)
    opts = to_node_opts(opts)

    case register_name(opts.manager_name) do
      {:error, reason} = err ->
        :proc_lib.init_ack(parent, reason)
        err

      :ok ->
        # Spawn node
        with {:ok, port} <- Ports.open_link(opts),
             opts = %{opts | port: port, alive?: true},
             debug = :sys.debug_options([]),
             {:ok, agent_pid} <- init_node(parent, opts),
             :ok <- configure_node(parent, agent_pid, opts) do
          :proc_lib.init_ack(parent, {:ok, self()})
          handle_node_initialized(parent, debug, agent_pid, opts)
        else
          {:error, reason} ->
            :proc_lib.init_ack(parent, reason)
        end
    end
  end

  defp register_name(name) do
    try do
      Process.register(self(), name)
      :ok
    rescue
      _ ->
        {:error, {:already_registered, Process.whereis(name)}}
    end
  end

  defp init_node(parent, %{port: port, name: agent_node} = opts) do
    boot_timeout = opts.boot_timeout

    receive do
      # If our parent dies, just exit
      {:EXIT, ^parent, reason} ->
        exit(reason)

      # If the port dies, just exit
      {:EXIT, ^port, reason} ->
        exit(reason)

      {^agent_node, _agent_pid, {:init_failed, err}} ->
        msg =
          if is_binary(err) do
            err
          else
            "#{inspect(err)}"
          end

        Logger.error("""
        Failed to boot node #{inspect(agent_node)}! More detail below:

        #{msg}
        """)

        {:error, {:init_failed, err}}

      {^agent_node, agent_pid, :node_booted} ->
        # If we booted, send config overrides
        send(agent_pid, {self(), :configure, opts.config})
        {:ok, agent_pid}
    after
      boot_timeout ->
        {:error, :boot_timeout}
    end
  end

  defp configure_node(parent, agent_pid, %{port: port, name: agent_node} = opts) do
    init_timeout = opts.init_timeout

    receive do
      {:EXIT, ^parent, reason} ->
        exit(reason)

      {:EXIT, ^port, reason} ->
        exit(reason)

      {^agent_node, ^agent_pid, :node_configured} ->
        # At this point the node is ready for use
        :ok
    after
      init_timeout ->
        {:error, :init_timeout}
    end
  end

  defp handle_node_initialized(parent, debug, agent_pid, opts) do
    # If we are running coverage, make sure the managed node is included
    if Process.whereis(:cover_server) do
      cover_main_node = :cover.get_main_node()
      :rpc.call(cover_main_node, :cover, :start, [opts.name])
    end

    # Start monitoring the node
    :net_kernel.monitor_nodes(true, node_type: :all)
    # Invoke all of the post-start functions
    for fun <- opts.post_start_functions do
      case fun do
        {m, f, a} ->
          :rpc.call(opts.name, m, f, a)

        fun when is_function(fun, 0) ->
          Node.spawn(opts.name, fun)
      end
    end

    # Enter main loop
    loop(parent, debug, agent_pid, opts)
  end

  defp loop(parent, debug, agent_pid, %{port: port, name: agent_node} = opts) do
    heart? = opts.heart
    alive? = opts.alive?

    receive do
      {:system, from, req} ->
        :sys.handle_system_msg(req, from, parent, __MODULE__, debug, {agent_pid, opts})

      {:EXIT, ^parent, reason} ->
        exit(reason)

      {:EXIT, ^port, reason} ->
        exit(reason)
        
      {:EXIT, _, _} ->
        # Some child process terminated
        loop(parent, debug, agent_pid, opts)

      {:nodedown, ^agent_node, _} ->
        loop(parent, debug, agent_pid, %{opts | alive?: false})

      {:nodedown, _, _} ->
        # ignore..
        loop(parent, debug, agent_pid, opts)

      {:nodeup, ^agent_node, _} ->
        # Node was restarted by us or by init
        with {:ok, agent_pid} <- init_node(parent, opts),
             :ok <- configure_node(parent, agent_pid, opts) do
          handle_node_initialized(parent, debug, agent_pid, %{opts | alive?: true})
        else
          {:error, reason} ->
            exit(reason)
        end

      {:nodeup, _, _} ->
        # ignore..
        loop(parent, debug, agent_pid, opts)

      {from, :is_alive} ->
        send(from, {self(), alive?})
        loop(parent, debug, agent_pid, opts)

      {from, :get_name} ->
        send(from, {self(), opts.name})
        loop(parent, debug, agent_pid, opts)

      {from, :get_port_pid} ->
        send(from, {self(), port})
        loop(parent, debug, agent_pid, opts)

      {from, {:spawn_fun, fun, fun_opts}} when alive? ->
        send(agent_pid, {self(), :spawn_fun, fun, fun_opts})
        wait_for_fun(parent, debug, agent_pid, opts, from)

      {from, {:apply, m, f, a, mfa_opts}} when alive? ->
        send(agent_pid, {self(), :apply_fun, {m,f,a}, mfa_opts})
        wait_for_fun(parent, debug, agent_pid, opts, from)

      {from, {:connect, nodes}} when alive? ->
        send(agent_pid, {self(), :connect, nodes})
        wait_for_connected(parent, debug, agent_pid, opts, from, nodes)

      {from, {:disconnect, nodes}} when alive? ->
        send(agent_pid, {self(), :disconnect, nodes})
        wait_for_disconnected(parent, debug, agent_pid, opts, from, nodes)

      {from, stop} when stop in [:stop, :kill] ->
        result = terminate_node(agent_pid, opts, brutal: stop == :kill)
        send(from, {self(), result})

        if heart? do
          loop(parent, debug, agent_pid, %{opts | :alive? => false})
        else
          :ok
        end

      {from, _msg} when not alive? ->
        send(from, {self(), {:error, :nodedown}})
        loop(parent, debug, agent_pid, opts)

      msg ->
        Logger.warn("Unexpected message in #{__MODULE__}: #{inspect(msg)}")
        loop(parent, debug, agent_pid, opts)
    end
  end
  
  defp wait_for_fun(parent, debug, agent_pid, opts, from) do
    receive do
      {:EXIT, ^parent, reason} ->
        exit(reason)
      {_, ^agent_pid, reply} ->
        send(from, {self(), reply})
        loop(parent, debug, agent_pid, opts)
    end
  end

  defp wait_for_connected(parent, debug, agent_pid, opts, from, []) do
    send(from, {self(), :ok})
    loop(parent, debug, agent_pid, opts)
  end

  defp wait_for_connected(parent, debug, agent_pid, opts, from, nodes) do
    receive do
      {:EXIT, ^parent, reason} ->
        exit(reason)

      {_, ^agent_pid, {:connected, n}} ->
        wait_for_connected(parent, debug, agent_pid, opts, from, Enum.reject(nodes, &(&1 == n)))

      {_, ^agent_pid, {:connect_failed, n, _reason}} ->
        wait_for_connected(parent, debug, agent_pid, opts, from, Enum.reject(nodes, &(&1 == n)))
    end
  end

  defp wait_for_disconnected(parent, debug, agent_pid, opts, from, []) do
    send(from, {self(), :ok})
    loop(parent, debug, agent_pid, opts)
  end

  defp wait_for_disconnected(parent, debug, agent_pid, opts, from, nodes) do
    receive do
      {:EXIT, ^parent, reason} ->
        exit(reason)

      {_, ^agent_pid, {:disconnected, n}} ->
        wait_for_disconnected(
          parent,
          debug,
          agent_pid,
          opts,
          from,
          Enum.reject(nodes, &(&1 == n))
        )

      {_, ^agent_pid, {:disconnect_failed, n, _reason}} ->
        wait_for_disconnected(
          parent,
          debug,
          agent_pid,
          opts,
          from,
          Enum.reject(nodes, &(&1 == n))
        )
    end
  end

  defp terminate_node(agent_pid, opts, terminate_opts) do
    agent_node = opts.name

    {cover?, main_cover_node} =
      if Process.whereis(:cover_server) do
        main_cover_node = :cover.get_main_node()
        :rpc.call(main_cover_node, :cover, :flush, [agent_node])
        {true, main_cover_node}
      else
        {false, nil}
      end

    send(agent_pid, {:terminate, terminate_opts})

    receive do
      {:nodedown, ^agent_node, _} ->
        if cover? do
          :rpc.call(main_cover_node, :cover, :stop, [agent_node])
        end

        :ok
    after
      30_000 ->
        {:error, :shutdown_timeout}
    end
  end

  # :sys callbacks

  @doc false
  def system_continue(parent, debug, {agent_pid, opts}) do
    loop(parent, debug, agent_pid, opts)
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
  def system_terminate(reason, _parent, _debug, {_agent_pid, _opts}) do
    reason
  end

  # Private

  defp to_node_opts(opts) when is_list(opts) do
    name =
      case Keyword.get(opts, :name) do
        nil ->
          Utils.generate_name()

        n ->
          Utils.nodename(n)
      end

    cookie =
      case Keyword.get(opts, :cookie, Node.get_cookie()) do
        c when is_binary(c) ->
          String.to_atom(c)

        c when is_atom(c) ->
          c

        other ->
          raise ClusteredCaseError,
                "must provide valid cookie (atom or string) to #{__MODULE__}.start/1, got: #{
                  inspect(other)
                }"
      end

    config = Keyword.get(opts, :config, [])

    %__MODULE__{
      name: name,
      cookie: cookie,
      manager_name: name,
      agent_name: NodeAgent.name_of(),
      heart: Keyword.get(opts, :heart, false),
      boot_timeout: Keyword.get(opts, :boot_timeout, 2_000),
      init_timeout: Keyword.get(opts, :init_timeout, 10_000),
      post_start_functions: Keyword.get(opts, :post_start_functions, []),
      erl_flags: to_port_args(name, cookie, Keyword.get(opts, :erl_flags, [])),
      env: to_port_env(Keyword.get(opts, :env, [])),
      config: config,
      alive?: false,
      capture_log: Keyword.get(opts, :capture_log, false),
      stdout: Keyword.get(opts, :stdout, false)
    }
  end

  defp to_port_env(env) when is_list(env),
    do: to_port_env(env, [])

  defp to_port_env([], acc), do: acc

  defp to_port_env([{name, val} | rest], acc) when is_binary(name) and is_binary(val) do
    to_port_env(rest, [{String.to_charlist(name), String.to_charlist(val)} | acc])
  end

  defp to_port_env([invalid | _], _) do
    raise ClusteredCaseError,
          "invalid env configuration, expected tuple of strings (name, value), got: #{
            inspect(invalid)
          }"
  end

  defp to_port_args(name, cookie, args) when is_list(args) do
    # ["-detached", 
    base_args = [
      "-noinput",
      "-#{Utils.name_type()}",
      "#{name}",
      "-setcookie",
      "#{cookie}",
      "-id",
      "#{name}",
      "-loader",
      "inet",
      "-hosts",
      "127.0.0.1",
      "-s",
      "#{NodeAgent}",
      "start",
      "#{Node.self()}"
    ]

    code_paths =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    final_args =
      code_paths
      |> Enum.concat(base_args)
      |> Enum.concat(args)

    for a <- final_args do
      if is_binary(a) do
        String.to_charlist(a)
      else
        a
      end
    end
  end

  # Standardizes calls to the manager
  defp server_call(pid, msg) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, {self(), msg})
    receive do
      {:DOWN, ^ref, _type, _pid, _info} ->
        exit({:noproc, {__MODULE__, :server_call, [pid, msg]}})

      {^pid, result} ->
        Process.demonitor(ref, [:flush])
        result
    end
  end

  defp server_call(name, msg) do
    name = Utils.nodename(name)
    case Process.whereis(name) do
      nil ->
        exit({:noproc, {__MODULE__, :server_call, [name, msg]}})

      pid ->
        server_call(pid, msg)
    end
  end
end
