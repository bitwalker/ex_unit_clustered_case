defmodule ExUnit.ClusteredCase.Test.ClusterTest do
  use ExUnit.Case

  alias ExUnit.ClusteredCase.Cluster
  alias ExUnit.ClusteredCase.Node, as: N
  import ExUnit.ClusteredCase.Support

  test "can successfully start a cluster" do
    test_pid = self()
    pingback = fn -> send(test_pid, {test_pid, :pong}) end
    opts = [
      boot_timeout: boot_timeout(),
      cluster_size: 2, 
      post_start_functions: [pingback]
    ]
    assert {:ok, cluster} = Cluster.start(opts)
    assert_receive {^test_pid, :pong}, 5_000
    assert_receive {^test_pid, :pong}, 5_000

    [name1, name2] = Cluster.members(cluster)

    assert [^name2] = N.call(name1, Node, :list, [])
  end

  test "can map a function across a cluster" do
    opts = [
      boot_timeout: boot_timeout(),
      cluster_size: 2
    ]
    assert {:ok, c} = Cluster.start(opts)
    members = Cluster.members(c)
    assert ^members = Cluster.map(c, fn -> Node.self() end)
  end
end
