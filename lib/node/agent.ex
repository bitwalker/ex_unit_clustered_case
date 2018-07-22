defmodule ExUnit.ClusteredCase.Node.Agent do
  @moduledoc false
  
  alias ExUnit.ClusteredCase.Node.Manager
  
  @doc """
  The name of the agent process on each started node
  """
  def name_of(), do: :ex_unit_clustered_case_node_agent
  
  # Invoked via `-s #{__MODULE__} start <manager_node>` when
  # node is started via `Port.open/2` and finishes boot
  @spec start([atom]) :: pid
  def start([manager_node]) when is_atom(manager_node) do
    spawn(__MODULE__, :init, [manager_node])
  end
  
  @doc false
  def init(manager_node) do
    manager_name = Manager.name_of(Node.self)

    Process.flag(:trap_exit, true)
    Process.register(self(), name_of())
    
    case :net_kernel.hidden_connect_node(manager_node) do
      true ->
        :ok
      false ->
        IO.puts "Unable to connect to master (#{inspect manager_node})! Terminating.."
        :erlang.halt()
      :ignored ->
        IO.puts "Distribution not started! This node is missing configuration! Terminating.."
        :erlang.halt()
    end
      
    # Watch the master
    Node.monitor(manager_node, true)
      
    # Load and start critical applications
    Application.ensure_all_started(:elixir, :permanent)
    Application.ensure_all_started(:logger, :permanent)
    Application.ensure_all_started(:mix, :permanent)
    Application.ensure_all_started(:ex_unit, :permanent)
    
    Mix.env(:test)
      
    # Initialize base configuration
    project_config = Mix.Project.config()
    # Load and persist mix config
    {config, _paths} = Mix.Config.eval!(project_config[:config_path])
    Mix.Config.persist(config)
    # Load test modules so that functions defined in tests can be used
    # This is dirty, but works, so it stays for now
    test_paths = project_config[:test_paths] || ["test"]
    test_pattern = project_config[:test_pattern] || "*_test.exs"
    matched_test_files = Mix.Utils.extract_files(test_paths, test_pattern)
    case Kernel.ParallelCompiler.require(matched_test_files, []) do
      {:ok, _, _} ->
        :ok
      {:error, errors, _warnings} ->
        msg =
          errors
          |> Enum.map(fn {file, line, m} -> "#{file}:#{line}: #{m}" end)
          |> Enum.join("\n")
        msg = "Failed to compile test files:\n" <> msg
        send({manager_name, manager_node}, {Node.self, self(), {:init_failed, msg}})
        :erlang.halt()
    end

    # Notify master we're booted
    send({manager_name, manager_node}, {Node.self, self(), :node_booted})

    # Enter main loop
    loop(manager_name, manager_node)
  rescue
    ex ->
      msg = Exception.message(ex) <> "\n" <>
        Exception.format_stacktrace(System.stacktrace())
      manager_name = Manager.name_of(Node.self)
      send({manager_name, manager_node}, {Node.self, self(), {:init_failed, msg}})
  catch
    kind, payload ->
      msg = Exception.format(kind, payload, System.stacktrace())
      manager_name = Manager.name_of(Node.self)
      send({manager_name, manager_node}, {Node.self, self(), {:init_failed, msg}})
  after
      :erlang.halt()
  end
  
  defp loop(manager, manager_node) do
    receive do
      {:nodedown, ^manager_node} ->
        :erlang.halt()
      :terminate ->
        :erlang.halt()
      {:EXIT, _, :normal} ->
        :ok
      {from, :configure, config} ->
        Mix.Config.persist(config)
        send(from, {Node.self, self(), :node_configured})
      {from, :connect, nodes} when is_list(nodes) ->
        connect_nodes(from, nodes)
      {from, :connect, node} when is_atom(node) ->
        connect_nodes(from, [node])
      {from, :disconnect, nodes} when is_list(nodes) ->
        disconnect_nodes(from, nodes)
      {from, :disconnect, node} when is_atom(node) ->
        disconnect_nodes(from, [node])
      msg ->
        IO.puts "unexpected message received by agent: #{inspect msg}"
        :ok
    end
    loop(manager, manager_node)
  end
  
  defp connect_nodes(from, nodes) do
    for n <- nodes do
      case Node.ping(n) do
        :pong ->
          send(from, {Node.self, self(), {:connected, n}})
        other ->
          send(from, {Node.self, self(), {:connect_failed, n, other}})
      end
    end
  end
  
  defp disconnect_nodes(from, nodes) do
    for n <- nodes do
      case :erlang.disconnect_node(n) do
        true ->
          send(from, {Node.self, self(), {:disconnected, n}})
        other ->
          send(from, {Node.self, self(), {:disconnect_failed, n, other}})
      end
    end
  end
end
