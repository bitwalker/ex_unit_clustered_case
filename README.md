# ExUnit Clustered Cases

[![Master](https://travis-ci.com/bitwalker/ex_unit_clustered_case.svg?branch=master)](https://travis-ci.com/bitwalker/ex_unit_clustered_case)
[![Hex.pm Version](http://img.shields.io/hexpm/v/ex_unit_clustered_case.svg?style=flat)](https://hex.pm/packages/ex_unit_clustered_case)

This project provides an extension for ExUnit for running tests against a
clustered application. It provides an easy way to spin up multiple nodes,
multiple clusters, and test a variety of scenarios in parallel without needing
to manage the clustering aspect yourself.

**NOTE:** This library requires Elixir 1.7+, due to a bug in earlier versions of
ExUnit which would generate different module md5s on every compile. This results
in being unable to define functions in test modules for execution on other nodes,
which is an impractical constraint for testing. This library has to compile test
modules on each node separately, as they are compiled in-memory by the test compiler,
and so are unable to be remotely code loaded like modules which are compiled to `.beam`
files on disk.

## Installation

You can add this library to your project like so:

```elixir
def deps do
  [
    {:ex_unit_clustered_case, "~> 0.4"}
  ]
end
```

Then, add the following lines right above `ExUnit.start/1` in your `test_helper.exs` file to switch ExUnit's node to allow distribution:

```elixir
{_, 0} = System.cmd("epmd", ["-daemon"])
Node.start(:"ex_unit@127.0.0.1", :longnames)
ExUnit.start()
```

## Usage

The documentation for `ExUnit.ClusteredCase` provide more details, but below is brief idea
of the capabilities currently offered in this library:

```elixir
defmodule KVStore.ClusteredTests do
  use ExUnit.ClusteredCase

  # A scenario defines a group of tests which will be run against a single cluster,
  # which is dynamically created. There are several options you can provide to configure
  # the cluster, including size, partitions, configuration, system environment and more.
  scenario "given a healthy cluster", [cluster_size: 2] do

    # Node setups work similar to `setup` in ExUnit, but are run on each node of the cluster
    node_setup [:start_apps, :seed_kvstore]

    # Just plain old tests - note the :cluster key of the context, which is needed to talk
    # to the nodes of the cluster via the Cluster API (an alias added for you)
    test "writes are replicated to all nodes", %{cluster: c} do
      writer = Cluster.random_member(c)
      assert {:ok, 0} = Cluster.call(writer, KVStore, :get, [:counter])
      assert :ok = Cluster.call(writer, KVStore, :increment, [:counter]
      assert [1, 1] = Cluster.map(c, KVStore, :get, [:counter])
    end
  end

  scenario "given a partitioned cluster", [cluster_size: 2] do
    node_setup [:start_apps, :seed_kvstore]

    test "writes are not replicated during a partition, but are when healed", %{cluster: c} do
      [a, b] = Cluster.members(c)
      assert [0, 0] = Cluster.map(c, KVStore, :get, [:counter])
      # Partitions can be specified as a number of partitions, list of node
      # counts, or list of node memberships
      assert :ok = Cluster.partition(c, [[a], [b]])
      assert :ok = Cluster.call(a, KVStore, :increment, [:counter])
      assert {:ok, 1} = Cluster.call(a, KVStore, :get, [:counter])
      assert [1, 0] = Cluster.map(c, KVStore, :get, [:counter])
      assert :ok = Cluster.heal(c)
      # You can use anonymous functions as well
      assert [1, 1] = Cluster.map(c, fn -> KVStore.get(:counter) end)
    end
  end

  def start_apps(_context) do
    Application.ensure_all_started(:kv_store)
  end

  def seed_kvstore(_context) do
    KVStore.put(:counter, 0)
  end
end
```

The goal of this project is to provide a way to easily express tests in a clustered environment, and
to provide infrastructure for running such tests as efficiently as possible. Many different scenarios
are desirable to test, but they boil down to the following:

- The behavior when a cluster is healthy
- The behavior when a cluster is partitioned or unhealthy (perhaps a master node is unavailable)
- The behavior when a partition occurs and is subsequently healed
- The behavior when one or more members of a cluster are "flapping", i.e. joining and leaving the cluster rapidly

If you are finding one of these scenarios difficult to test using this library, please let me know so
that it can be improved.

You can find more information in the docs on [hexdocs.pm](https://hexdocs.pm/ex_unit_clustered_case) or generate the docs
with `mix docs` from a local git checkout.

## Capturing Output

By default, output written to stdio/stderr on nodes will be hidden. You can change this behavior for testing
with the following node options:

- Capture the entire log from a node with `capture_log: true`
- Redirect output to a device or process with `stdout: :standard_error | :standard_io | pid`
- Both capture _and_ redirect by setting both options.

Default values are `capture_log: false` and `stdout: false`

When you capture, you can get the captured logs for a specific node with `Cluster.log(node)`. If capturing
is not enabled, this will simply return `{:ok, ""}`, otherwise it returns `{:ok, binary}`. When you call this
function, the logs are returned, and the accumulated logs are flushed, resetting the capture state.

**NOTE**: Setting these options occurs when a node is started, and cannot be changed later. Since output is
gathered in a central location, async tests which are testing against a node's output may stomp on each other,
either by writing content that conflicts with the other test, or by flushing the captured log when a test is not
expecting that to happen. If you need to test against log output, be sure to start separate nodes for each test,
or run your tests with `async: false`.

## Roadmap

- [ ] Add support for disabling auto-clustering in favor of letting tools like
      `libcluster` do the work.
- [ ] Add fault injection support (random partitioning, flapping)

## License

Apache 2, see the `LICENSE` file for more information.
