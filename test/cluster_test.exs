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

  test "can capture log across a cluster" do
    opts = [
      boot_timeout: boot_timeout(),
      cluster_size: 1,
      capture_log: true,
    ]
    assert {:ok, c} = Cluster.start(opts)
    [pid] = Cluster.members(c)
    N.call(pid, IO, :puts, ["hello from cluster"])
    assert {:ok, log} = N.log(pid)
    assert log =~ "hello from cluster"
  end

  test "can redirect log to device across a cluster" do
    import ExUnit.CaptureIO
    opts = [
      boot_timeout: boot_timeout(),
      cluster_size: 1,
      stdout: :standard_error
    ]
    assert {:ok, c} = Cluster.start(opts)
    [pid] = Cluster.members(c)
    assert capture_io(:standard_error, fn ->
      N.call(pid, IO, :puts, ["stdout hello from cluster"])
    end) =~ "stdout hello from cluster"
  end

  test "capture_log and stdout when init a cluster using nodes options" do
    import ExUnit.CaptureIO
    opts = [
      nodes: [
        [{:name, "node1"}, {:boot_timeout, boot_timeout()}, {:capture_log, true}],
        [{:name, "node2"}, {:boot_timeout, boot_timeout()}, {:stdout, :standard_error}]
      ]
    ]
    assert {:ok, c} = Cluster.start(opts)
    [pid1, pid2] = Cluster.members(c)
    N.call(pid1, IO, :puts, ["hello from cluster"])
    assert {:ok, log} = N.log(pid1)
    assert log =~ "hello from cluster"

    N.call(pid2, IO, :puts, ["hello from cluster"])
    assert {:ok, ""} = N.log(pid2)

    assert capture_io(:standard_error, fn ->
      N.call(pid1, IO, :puts, ["stdout hello from cluster"])
    end) == ""

    assert capture_io(:standard_error, fn ->
      N.call(pid2, IO, :puts, ["stdout hello from cluster"])
    end) =~ "stdout hello from cluster"
  end

end
