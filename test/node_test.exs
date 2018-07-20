defmodule ExUnit.ClusteredCase.Test.NodeTest do
  use ExUnit.Case, async: true
  
  alias ExUnit.ClusteredCase.Node, as: N
  
  test "can successfully start a node" do
    test_pid = self()
    pingback = fn -> send(test_pid, {test_pid, :pong}) end

    opts = [post_start_functions: [pingback]]

    assert {:ok, _} = N.start(opts)
    assert_receive {^test_pid, :pong}, 5_000
  end
  
  test "provided configuration is applied" do
    config = [ex_unit_clustered_case: [overriden_by: self()]]
    assert {:ok, pid} = N.start(config: config)
    me = self()
    assert ^me = N.run(pid, Application, :get_env, [:ex_unit_clustered_case, :overriden_by])
  end
  
  test "env vars are applied as expected" do
    env = [{"SOME_VAR", "#{inspect self()}"}]
    assert {:ok, pid} = N.start(env: env)
    expected = "#{inspect self()}"
    assert ^expected = N.run(pid, Application, :get_env, [:ex_unit_clustered_case, :env_var])
  end
  
  test "can connect nodes to form a cluster" do
    {:ok, pid1} = N.start([])
    {:ok, pid2} = N.start([])
    
    name1 = N.name(pid1)
    name2 = N.name(pid2)
    
    assert :ok = N.connect(name1, [name2])
    assert [^name2] = N.run(name1, Node, :list, [])
    assert [^name1] = N.run(name2, Node, :list, [])
  end
end
