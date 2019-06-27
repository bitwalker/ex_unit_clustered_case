defmodule ExUnit.ClusteredCase.Test.NodeTest do
  use ExUnit.Case, async: true

  alias ExUnit.ClusteredCase.Node, as: N
  import ExUnit.ClusteredCase.Support

  test "can successfully start a node" do
    test_pid = self()
    pingback = fn -> send(test_pid, {test_pid, :pong}) end

    opts = [post_start_functions: [pingback]]

    assert {:ok, _} = start_node(opts)
    assert_receive {^test_pid, :pong}, 5_000
  end

  test "provided configuration is applied" do
    config = [ex_unit_clustered_case: [overriden_by: self()]]
    assert {:ok, pid} = start_node(config: config)
    me = self()
    assert ^me = N.call(pid, Application, :get_env, [:ex_unit_clustered_case, :overriden_by])
  end

  test "env vars are applied as expected" do
    expected = "#{inspect(self())}"
    env = [{"SOME_VAR", expected}]
    config = [ex_unit_clustered_case: [env_var: env]]
    assert {:ok, pid} = start_node(config: config)
    assert [{"SOME_VAR", ^expected}] = N.call(pid, Application, :get_env, [:ex_unit_clustered_case, :env_var])
  end

  test "can connect nodes to form a cluster" do
    {:ok, pid1} = start_node()
    {:ok, pid2} = start_node()

    name1 = N.name(pid1)
    name2 = N.name(pid2)

    assert :ok = N.connect(name1, [name2])
    assert [^name2] = N.call(name1, Node, :list, [])
    assert [^name1] = N.call(name2, Node, :list, [])
  end

  test "can restart a node with heart mode" do
    assert {:ok, pid} = start_node(heart: true)
    name = N.name(pid)
    assert N.alive?(pid)
    assert :ok = N.kill(pid)
    refute N.alive?(pid)
    refute name in Node.list([:connected])
    :timer.sleep(boot_timeout())
    assert N.alive?(pid)
    assert name in Node.list([:connected])
  end

  test "can capture log" do
    assert {:ok, pid} = start_node(capture_log: true)
    N.call(pid, IO, :puts, ["hello from node"])
    Process.sleep(5_000)
    assert {:ok, log} = N.log(pid)
    assert log =~ "hello from node"
  end

  test "can redirect log to device" do
    import ExUnit.CaptureIO
    # Note, for this test we have to redirect to something other than
    # :standard_io, since ExUnit.CaptureIO handles that device by changing
    # the group leader for the current process, but our funs are running
    # on another node, and output is being written in another process.
    assert {:ok, pid} = start_node(stdout: :standard_error)
    assert capture_io(:standard_error, fn ->
      N.call(pid, IO, :puts, ["hello from node"])
      Process.sleep(5_000)
    end) =~ "hello from node"
  end
end
