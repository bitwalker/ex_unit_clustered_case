defmodule ExUnit.ClusteredCase.Cluster.Supervisor do
  @moduledoc false
  use DynamicSupervisor

  alias ExUnit.ClusteredCase.Cluster

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, [args], name: __MODULE__)
  end

  def init(_args) do
    :ets.new(__MODULE__, [:public, :bag, :named_table])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Initializes a cluster based on a `scenario` definition.

  NOTE: This is for internal use only.
  """
  def init_cluster_for_scenario!(test_module, scenario, config) do
    spec = {Cluster, [config, [name: :"#{scenario}"]]}
    spec = Supervisor.child_spec(spec, restart: :temporary)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} = res ->
        :ets.insert(__MODULE__, {test_module, scenario, pid})
        res

      {:error, {:already_started, pid}} ->
        :ok = Cluster.reset(pid)
        {:ok, pid}

      {:error, _} = err ->
        throw(err)
    end
  end

  @doc """
  Terminates all clusters started during execution of a test module

  NOTE: This is for internal use only.
  """
  def cleanup_clusters_for_test_module(test_module) do
    scenarios = :ets.lookup(__MODULE__, test_module)

    for {_test_mod, _scenario, pid} = obj <- scenarios do
      Cluster.stop(pid)
      :ets.delete_object(__MODULE__, obj)
    end

    :ok
  end
end
