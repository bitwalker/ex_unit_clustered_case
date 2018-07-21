# ExUnit Clustered Cases

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
files on disk. **The fix for this is currently a PR against Elixir master, #7949, until
it is merged, you will need to use the `jv-prune-metadata` branch if you wish to test things out.**

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

  scenario "given a partitioned cluster", [cluster_size: 2, partitions: 2] do
    node_setup [:start_apps, :seed_kvstore]

    test "writes are not replicated during a partition", %{cluster: c} do
      [a, b] = Cluster.members(c)
      assert [0, 0] = Cluster.map(c, KVStore, :get, [:counter])
      assert :ok = Cluster.call(a, KVStore, :increment, [:counter])
      assert {:ok, 1} = Cluster.call(a, KVStore, :get, [:counter])
      # You can use anonymous functions as well
      assert {:ok, 0} = Cluster.call(a, fn -> KVStore.get(:counter) end)
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

## Installation

This package is not yet on Hex, but will be soon as `:ex_unit_clustered_case`.

In the mean time, you can add it to your project like so:

```elixir
def deps do
  [
    {:ex_unit_clustered_case, github: "bitwalker/ex_unit_clustered_case"}
  ]
end
```

You can generate the docs with `mix docs` from a local git checkout.

## Roadmap

- [ ] Add support for disabling auto-clustering in favor of letting tools like
      `libcluster` do the work.
- [ ] Add fault injection support (random partitioning, flapping)


## License

Apache 2, see the `LICENSE` file for more information.
