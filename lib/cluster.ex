defmodule ExUnit.ClusteredCase.Cluster do
  @moduledoc """
  This module is responsible for managing the setup and lifecycle of a single cluster.
  """
  use GenServer
  require Logger

  alias ExUnit.ClusteredCaseError
  alias ExUnit.ClusteredCase.Utils
  alias __MODULE__.{Partition, PartitionChange}

  @type node_spec :: ExUnit.ClusteredCase.Node.node_opts()
  @type callback :: {module, atom, [term]} | (() -> term)
  @type cluster_opts :: [cluster_opt]
  @type cluster_opt ::
          {:nodes, [node_spec]}
          | {:cluster_size, pos_integer}
          | {:partitions, pos_integer | [pos_integer] | [[atom]]}
          | {:env, [{String.t(), String.t()}]}
          | {:erl_flags, [String.t()]}
          | {:config, Keyword.t()}
          | {:boot_timeout, pos_integer}
          | {:init_timeout, pos_integer}
          | {:post_start_functions, [callback]}
          | {:stdout, atom | pid}
          | {:capture_log, boolean}

  defstruct [
    :parent,
    :pids,
    :nodes,
    :partitions,
    :partition_spec,
    :cluster_size,
    :env,
    :erl_flags,
    :config,
    :boot_timeout,
    :init_timeout,
    :post_start_functions
  ]

  @doc """
  Starts a new cluster with the given specification
  """
  @spec start(cluster_opts) :: {:ok, pid} | {:error, term}
  def start(opts), do: start_link(opts, [])

  @doc """
  Stops a running cluster. Expects the pid of the cluster manager process.
  """
  @spec stop(pid) :: :ok
  def stop(pid), do: GenServer.call(pid, :terminate, :infinity)

  @doc """
  Get the captured log for a specific node in the cluster
  """
  @spec log(node) :: {:ok, binary}
  defdelegate log(node), to: ExUnit.ClusteredCase.Node

  @doc """
  Retrieve a list of nodes in the given cluster
  """
  @spec members(pid) :: [node]
  def members(pid), do: GenServer.call(pid, :members, :infinity)

  @doc """
  Retrieve the name of a random node in the given cluster
  """
  @spec random_member(pid) :: node
  def random_member(pid) do
    Enum.random(members(pid))
  end

  @doc """
  Retrieve the partitions this cluster is composed of
  """
  @spec partitions(pid) :: [[node]]
  def partitions(pid), do: GenServer.call(pid, :partitions, :infinity)

  @doc """
  Partition the cluster based on the provided specification.

  You can specify partitions in one of the following ways:

  - As an integer representing the number of partitions
  - As a list of integers representing the number of nodes in each partition
  - As a list of lists, where each sub-list contains the nodes in that partition

  If your partitioning specification cannot be complied with, an error is returned

  ## Examples

      test "partition by number of partitions", %{cluster: c} do
         Cluster.partition(c, 2)
      end

      test "partition by number of nodes per partition", %{cluster: c} do
         Cluster.partition(c, [2, 2])
      end

      test "partition by list of nodes in each partition", %{cluster: c} do
         Cluster.partition(c, [[:a, :b], [:c, :d]])
      end
  """
  @spec partition(pid, Partition.opts()) :: :ok | {:error, term}
  def partition(pid, n) when is_list(n) do
    cond do
      Enum.all?(n, fn i -> is_integer(i) and i > 0 end) ->
        do_partition(pid, n)

      Enum.all?(n, fn p -> is_list(p) and Enum.all?(p, fn x -> is_binary(x) or is_atom(x) end) end) ->
        do_partition(pid, n)

      :else ->
        {:error, :invalid_partition_spec}
    end
  end

  def partition(pid, n) when is_integer(n) and n > 0 do
    do_partition(pid, n)
  end

  defp do_partition(pid, spec) do
    GenServer.call(pid, {:partition, spec}, :infinity)
  end

  @doc """
  Repartitions the cluster based on the provided specification.

  See `partition/2` for specification details.

  Repartitioning performs the minimal set of changes required to
  converge on the partitioning scheme in an attempt to minimize the 
  amount of churn. That said, some churn is expected, so bear that in
  mind when writing tests with partitioning events involved.
  """
  @spec repartition(pid, Partition.opts()) :: :ok | {:error, term}
  def repartition(pid, n), do: partition(pid, n)

  @doc """
  Heals all partitions in the cluster.
  """
  @spec heal(pid) :: :ok
  def heal(pid) do
    GenServer.call(pid, :heal, :infinity)
  end

  @doc """
  Invoke a function on a specific member of the cluster
  """
  @spec call(node, callback) :: term | {:error, term}
  defdelegate call(node, callback), to: ExUnit.ClusteredCase.Node

  @doc """
  Invoke a function on a specific member of the cluster
  """
  @spec call(node, module, atom, [term]) :: term | {:error, term}
  defdelegate call(node, m, f, a), to: ExUnit.ClusteredCase.Node

  @doc """
  Applies a function on all nodes in the cluster.
  """
  @spec each(pid, callback) :: :ok | {:error, term}
  def each(pid, callback) when is_function(callback, 0) do
    do_each(pid, callback)
  end

  @doc """
  Applies a function on all nodes in the cluster.
  """
  @spec each(pid, module, atom, [term]) :: :ok | {:error, term}
  def each(pid, m, f, a) when is_atom(m) and is_atom(f) and is_list(a) do
    do_each(pid, {m, f, a})
  end

  defp do_each(pid, callback) do
    do_call(pid, callback, collect: false)
  end

  @doc """
  Maps a function across all nodes in the cluster.

  Returns a list of results, where each element is the result from one node.
  """
  @spec map(pid, callback) :: [term] | {:error, term}
  def map(pid, fun) when is_function(fun, 0) do
    do_map(pid, fun)
  end

  @doc """
  Maps a function across all nodes in the cluster.

  Returns a list of results, where each element is the result from one node.
  """
  @spec map(pid, module, atom, [term]) :: [term] | {:error, term}
  def map(pid, m, f, a) when is_atom(m) and is_atom(f) and is_list(a) do
    do_map(pid, {m, f, a})
  end

  defp do_map(pid, callback) do
    [results] = do_call(pid, callback)
    results
  end

  # Function for running functions against nodes in the cluster
  # Provides options for tweaking the behavior of such calls
  defp do_call(pid, fun, opts \\ [])

  defp do_call(pid, {m, f, a} = mfa, opts) when is_atom(m) and is_atom(f) and is_list(a) do
    do_call(pid, [mfa], opts)
  end

  defp do_call(pid, fun, opts) when is_function(fun, 0) do
    do_call(pid, [fun], opts)
  end

  defp do_call(pid, funs, opts) when is_list(funs) do
    unless Enum.all?(funs, &valid_callback?/1) do
      raise ArgumentError, "expected list of valid callback functions, got: #{inspect(funs)}"
    end

    nodes = members(pid)
    parallel? = Keyword.get(opts, :parallel, true)
    collect? = Keyword.get(opts, :collect, true)

    if parallel? do
      async_call_all(nodes, funs, collect?)
    else
      sync_call_all(nodes, funs, collect?)
    end
  catch
    :throw, err ->
      err
  end

  defp valid_callback?({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: true
  defp valid_callback?(fun) when is_function(fun, 0), do: true
  defp valid_callback?(_), do: false

  ## Server Implementation

  @doc false
  def child_spec([_config, opts] = args) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      type: :worker,
      start: {__MODULE__, :start_link, args}
    }
  end

  @doc false
  def start_link(config, opts \\ []) do
    case Keyword.get(opts, :name) do
      nil ->
        GenServer.start_link(__MODULE__, [config, self()])

      name ->
        GenServer.start_link(__MODULE__, [config, self()], name: name)
    end
  end

  @doc false
  def init([opts, parent]) do
    Process.flag(:trap_exit, true)
    cluster_size = Keyword.get(opts, :cluster_size)
    custom_nodes = Keyword.get(opts, :nodes)

    nodes =
      cond do
        is_nil(cluster_size) and is_nil(custom_nodes) ->
          raise ClusteredCaseError,
                "you must provide either :cluster_size or :nodes when starting a cluster"

        is_nil(custom_nodes) ->
          generate_nodes(cluster_size, opts)

        :else ->
          decorate_nodes(custom_nodes, opts)
      end

    cluster_start_timeout = get_cluster_start_timeout(nodes)

    results =
      nodes
      |> Enum.map(&start_node_async/1)
      |> Enum.map(&await_node_start(&1, cluster_start_timeout))
      |> Enum.map(&link_node_manager/1)

    if Enum.any?(results, &startup_failed?/1) do
      terminate_started(results)
      {:stop, {:cluster_start, failed_nodes(results)}}
    else
      state = to_cluster_state(parent, nodes, opts, results)

      case state.partition_spec do
        {:error, _} = err ->
          {:stop, err}

        partition_spec ->
          change = Partition.partition(nodenames(state), nil, partition_spec)
          PartitionChange.execute!(change)
          {:ok, %{state | :partitions => change.partitions}}
      end
    end
  end

  defp partition_cluster(%{partition_spec: spec} = state, new_spec) do
    change = Partition.partition(nodenames(state), spec, new_spec)
    PartitionChange.execute!(change)
    %{state | :partitions => change.partitions, :partition_spec => new_spec}
  end

  defp heal_cluster(state) do
    nodes = nodenames(state)
    Enum.each(nodes, &ExUnit.ClusteredCase.Node.connect(&1, nodes -- [&1]))
    %{state | :partitions => nil, :partition_spec => nil}
  end

  def handle_call(:partitions, _from, %{partitions: partitions} = state) do
    {:reply, partitions || [nodenames(state)], state}
  end

  def handle_call({:partition, opts}, _from, state) do
    spec = Partition.new(nodenames(state), opts)
    {:reply, :ok, partition_cluster(state, spec)}
  end

  def handle_call(:heal, _from, state) do
    {:reply, :ok, heal_cluster(state)}
  end

  def handle_call(:members, _from, state) do
    {:reply, nodenames(state), state}
  end

  def handle_call(:terminate, _from, state) do
    {:stop, :shutdown, :ok, state}
  end

  def handle_info({:EXIT, parent, reason}, %{parent: parent} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _task, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, task, reason}, state) do
    Logger.warn("Task #{inspect(task)} failed with reason: #{inspect(reason)}")
    {:noreply, state}
  end

  def terminate(_reason, state) do
    nodepids(state)
    |> Task.async_stream(&ExUnit.ClusteredCase.Node.stop/1)
    |> Enum.to_list()
  end

  ## Private

  defp generate_nodes(cluster_size, opts) when is_integer(cluster_size) do
    nodes = for _ <- 1..cluster_size, do: [name: Utils.generate_name()]
    decorate_nodes(nodes, opts)
  end

  defp decorate_nodes(nodes, opts) do
    for n <- nodes do
      name = Keyword.get(n, :name)
      global_env = Keyword.get(opts, :env, [])
      global_flags = Keyword.get(opts, :erl_flags, [])
      global_config = Keyword.get(opts, :config, [])
      global_psf = Keyword.get(opts, :post_start_functions, [])

      decorated_node = [
        name: Utils.nodename(name),
        env: Keyword.merge(global_env, Keyword.get(n, :env, [])),
        erl_flags: Keyword.merge(global_flags, Keyword.get(n, :erl_flags, [])),
        config: Mix.Config.merge(global_config, Keyword.get(n, :config, [])),
        boot_timeout: Keyword.get(n, :boot_timeout, Keyword.get(opts, :boot_timeout)),
        init_timeout: Keyword.get(n, :init_timeout, Keyword.get(opts, :init_timeout)),
        post_start_functions: global_psf ++ Keyword.get(n, :post_start_functions, []),
        stdout: Keyword.get(n, :stdout, Keyword.get(opts, :stdout, false)),
        capture_log: Keyword.get(n, :capture_log, Keyword.get(opts, :capture_log, false))
      ]

      # Strip out any nil or empty options
      Enum.reduce(decorated_node, decorated_node, fn
        {key, nil}, acc ->
          Keyword.delete(acc, key)

        {key, []}, acc ->
          Keyword.delete(acc, key)

        {_key, _val}, acc ->
          acc
      end)
    end
  end

  defp nodenames(%{pids: pidmap}) do
    for {name, _pid} <- pidmap, do: name
  end

  defp nodepids(%{pids: pids}) do
    for {_name, pid} <- pids, do: pid
  end

  defp sync_call_all(nodes, funs, collect?),
    do: sync_call_all(nodes, funs, collect?, [])

  defp sync_call_all(_nodes, [], _collect?, acc), do: Enum.reverse(acc)

  defp sync_call_all(nodes, [fun | funs], collect?, acc) do
    # Run function on each node sequentially
    if collect? do
      results =
        nodes
        |> Enum.map(&ExUnit.ClusteredCase.Node.call(&1, fun, collect: collect?))

      sync_call_all(nodes, funs, [results | acc])
    else
      for n <- nodes do
        case ExUnit.ClusteredCase.Node.call(n, fun, collect: collect?) do
          {:error, reason} ->
            throw(reason)

          _ ->
            :ok
        end
      end

      sync_call_all(nodes, funs, :ok)
    end
  end

  defp async_call_all(nodes, funs, collect?),
    do: async_call_all(nodes, funs, collect?, [])

  defp async_call_all(_nodes, [], _collect?, acc), do: Enum.reverse(acc)

  defp async_call_all(nodes, [fun | funs], collect?, acc) do
    # Invoke function on all nodes
    results =
      nodes
      |> Enum.map(
        &Task.async(fn -> ExUnit.ClusteredCase.Node.call(&1, fun, collect: collect?) end)
      )
      |> await_all(collect: collect?)

    # Move on to next function
    async_call_all(nodes, funs, collect?, [results | acc])
  end

  defp await_all(tasks, opts),
    do: await_all(tasks, Keyword.get(opts, :collect, true), [])

  defp await_all([], true, acc), do: Enum.reverse(acc)
  defp await_all([], false, acc), do: acc

  defp await_all([t | tasks] = retry_tasks, collect?, acc) do
    case Task.yield(t) do
      {:ok, result} when collect? ->
        await_all(tasks, collect?, [result | acc])

      {:ok, {:error, reason}} ->
        throw(reason)

      {:ok, _} ->
        await_all(tasks, collect?, :ok)

      nil ->
        await_all(retry_tasks, collect?, acc)
    end
  end

  defp to_cluster_state(parent, nodes, opts, results) do
    pidmap =
      for {name, {:ok, pid}} <- results, into: %{} do
        {name, pid}
      end

    nodelist = for {name, _} <- results, do: name

    %__MODULE__{
      parent: parent,
      pids: pidmap,
      nodes: nodes,
      partition_spec: Partition.new(nodelist, Keyword.get(opts, :partitions)),
      cluster_size: Keyword.get(opts, :cluster_size),
      env: Keyword.get(opts, :env),
      erl_flags: Keyword.get(opts, :erl_flags),
      config: Keyword.get(opts, :config),
      boot_timeout: Keyword.get(opts, :boot_timeout),
      init_timeout: Keyword.get(opts, :init_timeout),
      post_start_functions: Keyword.get(opts, :post_start_functions)
    }
  end

  defp start_node_async(node_opts) do
    name = Keyword.fetch!(node_opts, :name)
    {name, Task.async(fn -> ExUnit.ClusteredCase.Node.start_nolink(node_opts) end)}
  end

  defp await_node_start({nodename, task}, cluster_start_timeout) do
    {nodename, Task.await(task, cluster_start_timeout)}
  end

  defp link_node_manager({_nodename, {:ok, pid}} = result) do
    Process.link(pid)
    result
  end

  defp link_node_manager({_nodename, _err} = result), do: result

  defp startup_failed?({_nodename, {:ok, _}}), do: false
  defp startup_failed?({_nodename, _err}), do: true

  defp terminate_started([]), do: :ok

  defp terminate_started([{_nodename, {:ok, pid}} | rest]) do
    ExUnit.ClusteredCase.Node.stop(pid)
    terminate_started(rest)
  end

  defp terminate_started([{_nodename, _err} | rest]) do
    terminate_started(rest)
  end

  defp failed_nodes(results) do
    Enum.reject(results, fn
      {_nodename, {:ok, _}} -> true
      _ -> false
    end)
  end

  defp get_cluster_start_timeout(nodes) when is_list(nodes) do
    get_cluster_start_timeout(nodes, 10_000)
  end

  defp get_cluster_start_timeout([], timeout), do: timeout

  defp get_cluster_start_timeout([node_opts | rest], timeout) do
    boot = Keyword.get(node_opts, :boot_timeout, 2_000)
    init = Keyword.get(node_opts, :init_timeout, 10_000)
    total = boot + init
    get_cluster_start_timeout(rest, max(total, timeout))
  end
end
