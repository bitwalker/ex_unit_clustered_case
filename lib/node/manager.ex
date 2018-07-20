defmodule ExUnit.ClusteredCase.Node.Manager do
  @moduledoc false
  require Logger
  
  alias ExUnit.ClusteredCaseError
  alias ExUnit.ClusteredCase.Utils
  alias ExUnit.ClusteredCase.Node.Agent, as: NodeAgent

  defstruct [:name,
             :cookie,
             :manager_name,
             :agent_name,
             :boot_timeout,
             :init_timeout,
             :post_start_functions,
             :erl_flags,
             :env,
             :config]
  
  @doc """
  Converts a given node name into the name of the associated manager process
  """
  def name_of(name), do: Utils.nodename(name)
  
  @doc """
  Starts a new node and it's corresponding management process
  """
  @spec start_link(ExUnit.ClusteredCase.Node.node_opts) :: {:ok, pid} | {:error, term}
  def start_link(opts) do
    :proc_lib.start_link(__MODULE__, :init, [self(), opts])
  end
  
  @doc """
  Same as `start_link/1`, but does not link the process
  """
  @spec start_nolink(ExUnit.ClusteredCase.Node.node_opts) :: {:ok, pid} | {:error, term}
  def start_nolink(opts) do
    :proc_lib.start(__MODULE__, :init, [self(), opts])
  end
  
  @doc """
  Instructs the manager to terminate the given node
  """
  def stop(name), do: call(name, :terminate)
  
  @doc """
  Returns the name of the node managed by the given process
  """
  def name(name) when is_pid(name), do: call(name, :get_name)
  
  @doc """
  Runs the given function on a node by spawning a process remotely with it
  """
  def run(name, fun, opts \\ [])
  def run(name, fun, opts) when is_function(fun) do
    call(name, {:spawn_fun, fun, opts})
  end
  def run(name, {m, f, a}, opts), do: run(name, m, f, a, opts)
  
  @doc """
  Applies the given module/function/args on the given node and returns the result
  """
  def run(name, m, f, a, opts \\ []) when is_atom(m) and is_atom(f) and is_list(a) do
    call(name, {:apply, m, f, a, opts})
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
    call(name, {:connect, nodes})
  end

  @doc false
  def init(parent, opts) do
    Process.flag(:trap_exit, true)
    opts = to_node_opts(opts)
    
    case register_name(opts.manager_name) do
      {:error, _} = err ->
        :proc_lib.init_ack(parent, err)
        err
      :ok ->
        # Spawn node
        manager = self()
        pid = spawn_link(fn -> open_port(manager, opts) end)
        port =
          receive do
            {:EXIT, ^parent, reason} ->
              exit(reason)
            {^pid, port} ->
              port
          end
        # Wait for node to come up
        agent_node = opts.name
        boot_timeout = opts.boot_timeout
        init_timeout = opts.init_timeout
        receive do
          # If our parent dies, just exit
          {:EXIT, ^parent, reason} ->
            exit(reason)
          # Wait until :node_booted, fails to boot, or we reach boot_timeout
          {^agent_node, _agent_pid, {:init_failed, err}} ->
            msg =
              if is_binary(err) do
                err
              else
                "#{inspect err}"
              end
            Logger.error """
            Failed to boot node #{inspect agent_node}! More detail below:

            #{msg}
            """
            :proc_lib.init_ack(parent, {:error, :init_failed})
          {^agent_node, agent_pid, :node_booted} ->
            # If we booted, send config overrides
            send(agent_pid, {self(), :configure, opts.config})
            # Wait for acknowledgement, or until we reach init_timeout
            receive do
              {:EXIT, ^parent, reason} ->
                exit(reason)
              {^agent_node, ^agent_pid, :node_configured} ->
                # At this point the node is ready for use
                :proc_lib.init_ack(parent, {:ok, self()})
                # Start management loop
                handle_node_initialized(parent, :sys.debug_options([]), port, agent_pid, opts)
            after
              init_timeout ->
                :proc_lib.init_ack(parent, {:error, :init_timeout})
            end
        after
          boot_timeout ->
            :proc_lib.init_ack(parent, {:error, :boot_timeout})
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
  
  defp handle_node_initialized(parent, debug, port, agent_pid, opts) do
    # If we are running coverage, make sure the managed node is included
    if Process.whereis(:cover_server) do
      cover_main_node = :cover.get_main_node()
      :rpc.call(cover_main_node, :cover, :start, [opts.name])
    end
    # Start monitoring the node
    Node.monitor(opts.name, true)
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
    loop(parent, debug, port, agent_pid, opts)
  end
  
  defp loop(parent, debug, port, agent_pid, opts) do
    agent_node = opts.name
    receive do
      {:system, from, req} ->
        :sys.handle_system_msg(req, from, parent, __MODULE__, debug, {port, agent_pid, opts})
      {:EXIT, ^parent, reason} ->
        exit(reason)
      {:nodedown, ^agent_node} ->
        exit(:nodedown)
      {from, :get_name} ->
        send(from, {self(), opts.name})
        loop(parent, debug, port, agent_pid, opts)
      {from, {:spawn_fun, fun, fun_opts}} ->
        result = spawn_fun(fun, fun_opts, opts)
        send(from, {self(), result})
        loop(parent, debug, port, agent_pid, opts)
      {from, {:apply, m, f, a, mfa_opts}} ->
        result = apply_fun(m, f, a, mfa_opts, opts)
        send(from, {self(), result})
        loop(parent, debug, port, agent_pid, opts)
      {from, {:connect, nodes}} ->
        send(agent_pid, {self(), :connect, nodes})
        wait_for_connected(parent, debug, port, agent_pid, opts, from, nodes)
      {from, :terminate} ->
        result = terminate_node(port, agent_pid, opts)
        send(from, {self(), result})
    end
  end
  
  defp wait_for_connected(parent, debug, port, agent_pid, opts, from, []) do
    send(from, {self(), :ok})
    loop(parent, debug, port, agent_pid, opts)
  end
  defp wait_for_connected(parent, debug, port, agent_pid, opts, from, nodes) do
    receive do
      {:EXIT, ^parent, reason} ->
        exit(reason)
      {_, ^agent_pid, {:connected, n}} ->
        wait_for_connected(parent, debug, port, agent_pid, opts, from, Enum.reject(nodes, &(&1 == n)))
      {_, ^agent_pid, {:connect_failed, n, _reason}} ->
        wait_for_connected(parent, debug, port, agent_pid, opts, from, Enum.reject(nodes, &(&1 == n)))
    end
  end
  
  defp spawn_fun(fun, fun_opts, opts) when is_function(fun) do
    collect? = Keyword.get(fun_opts, :collect, true)
    parent = self()
    ref = make_ref()
    pid = Node.spawn(opts.name, fn -> 
      try do
        fun.()
      catch
        kind, err ->
          send(parent, {ref, {kind, err}})
      else
        result ->
          if collect? do
            send(parent, {ref, result})
          else
            send(parent, {ref, :ok})
          end
      end
    end)
    pref = Process.monitor(pid)
    receive do
      {:DOWN, ^pref, _type, _pid, info} ->
        {:error, info}
      {^ref, result} ->
        Process.demonitor(pref, [:flush])
        result
    end
  end
  
  defp apply_fun(m, f, a, mfa_opts, opts) do
    collect? = Keyword.get(mfa_opts, :collect, true)
    parent = self()
    ref = make_ref()
    pid = Node.spawn(opts.name, fn -> 
      try do
        apply(m, f, a)
      catch
        kind, err ->
          send(parent, {ref, {kind, err}})
      else
        result ->
          if collect? do
            send(parent, {ref, result})
          else
            send(parent, {ref, :ok})
          end
      end
    end)
    pref = Process.monitor(pid)
    receive do
      {:DOWN, ^pref, _type, _pid, info} ->
        {:error, info}
      {^ref, result} ->
        Process.demonitor(pref, [:flush])
        result
    end
  end
  
  defp terminate_node(port, agent_pid, opts) do
    agent_node = opts.name
    {cover?, main_cover_node} =
      if Process.whereis(:cover_server) do
        main_cover_node = :cover.get_main_node()
        :rpc.call(main_cover_node, :cover, :flush, [agent_node])
        {true, main_cover_node}
      else
        {false, nil}
      end
    Node.monitor(agent_node, true)
    send(agent_pid, :terminate)
    receive do
      {:nodedown, ^agent_node} ->
        if cover? do
          :rpc.call(main_cover_node, :cover, :stop, [agent_node])
        end
        :ok
    after
      30_000 ->
        Port.close(port)
        {:error, :shutdown_timeout}
    end
  end

  
  # :sys callbacks
  
  @doc false
  def system_continue(parent, debug, {port, agent_pid, opts}) do
    loop(parent, debug, port, agent_pid, opts)
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
  def system_terminate(reason, _parent, _debug, {port, _agent_pid, _opts}) do
    Port.close(port)
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
            "must provide valid cookie (atom or string) to #{__MODULE__}.start/1, got: #{inspect other}"
      end
    
    config = Keyword.get(opts, :config, [])
    
    %__MODULE__{
      name: name,
      cookie: cookie,
      manager_name: name,
      agent_name: NodeAgent.name_of(),
      boot_timeout: Keyword.get(opts, :boot_timeout, 2_000),
      init_timeout: Keyword.get(opts, :init_timeout, 10_000),
      post_start_functions: Keyword.get(opts, :post_start_functions, []),
      erl_flags: to_port_args(name, cookie, Keyword.get(opts, :erl_flags, [])),
      env: to_port_env(Keyword.get(opts, :env, [])),
      config: config
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
      "invalid env configuration, expected tuple of strings (name, value), got: #{inspect invalid}"
  end
  
  defp to_port_args(name, cookie, args) when is_list(args) do
    base_args =
      #["-detached", 
      ["-noinput", 
       "-#{Utils.name_type()}", "#{name}", 
       "-setcookie", "#{cookie}",
       "-id", "#{name}",
       "-loader", "inet", "-hosts", "127.0.0.1",
       "-s", "#{NodeAgent}", "start", "#{Node.self}"] 
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
  defp call(pid, msg) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, {self(), msg})
    receive do
      {:DOWN, ^ref, _type, _pid, info} ->
        {:error, info}
      {^pid, result} ->
        Process.demonitor(ref, [:flush])
        result
    end
  end
  defp call(name, msg) do
    name = Utils.nodename(name)
    case Process.whereis(name) do
      nil ->
        raise "no node manager for #{inspect name}"
      pid ->
        call(pid, msg)
    end
  end
  
  defp open_port(manager, opts) do
    env = opts.env
    args = opts.erl_flags
    erl = System.find_executable("erl")
    port_opts = [:stream | [env: env, args: args]]
    port = Port.open({:spawn_executable, erl}, port_opts)
    send(manager, {self(), port})
    watch_port(port, opts)
  end
  
  defp watch_port(port, %{name: name} = opts) do
    receive do
      {^port, {:data, data}} ->
        IO.puts("#{name}: " <> IO.iodata_to_binary(data))
        watch_port(port, opts)
    end
  end
end
