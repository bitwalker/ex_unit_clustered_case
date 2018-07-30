defmodule ExUnit.ClusteredCase.Test.ClusteredCaseTest do
  use ExUnit.ClusteredCase, async: false

  scenario "healthy cluster", cluster_size: 2 do
    node_setup(:config_node)

    test "nodes greet the world", %{cluster: cluster} do
      members = Cluster.members(cluster)
      assert length(members) == 2
      assert ^members = Cluster.map(cluster, fn -> Node.self() end)

      assert ^members =
               Cluster.map(cluster, fn -> Application.get_env(:ex_unit_clustered_case, :name) end)
    end
  end

  scenario "with an unpartitioned cluster", cluster_size: 2 do
    test "can partition and heal the cluster", %{cluster: cluster} do
      [a, b] = Cluster.members(cluster)
      assert [_] = Cluster.partitions(cluster)
      assert [^b] = Cluster.call(a, Node, :list, [])
      assert :ok = Cluster.partition(cluster, 2)
      assert [_, _] = Cluster.partitions(cluster)
      assert [] = Cluster.call(a, Node, :list, [])
      assert [] = Cluster.call(b, Node, :list, [])
      assert :ok = Cluster.heal(cluster)
      assert [_] = Cluster.partitions(cluster)
      assert [^b] = Cluster.call(a, Node, :list, [])
    end
  end

  def config_node(_) do
    Application.put_env(:ex_unit_clustered_case, :name, Node.self())
  end
end
