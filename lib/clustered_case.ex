defmodule ExUnit.ClusteredCase do
  @moduledoc """
  Helpers for defining clustered test cases.

  Use this in place of `ExUnit.Case` when defining test modules where
  you will be defining clustered tests. `#{__MODULE__}` extends
  `ExUnit.Case` to provide additional helpers for those tests.

  Since `#{__MODULE__}` is an extension of `ExUnit.Case`, it takes the
  same options, and imports the same test helpers and callbacks. It adds
  new helpers, `scenario/3`, `node_setup/1`, and `node_setup/2`, and aliases
  the `#{__MODULE__.Cluster}` module for convenience.

  ## Examples

      defmodule KVStoreTests do
        # Use the module
        use ExUnit.ClusteredCase
        
        # Define a clustered scenario
        scenario "given a healthy cluster", [cluster_size: 3] do

          # Set up each node in the cluster prior to each test
          node_setup do
            {:ok, _} = Application.ensure_all_started(:kv_store)
          end
          
          # Define a test to run in this scenario
          test "always pass" do
            assert true
          end
        end
      end
      
  ## Context

  All tests receive a context as an argument, just like with `ExUnit.Case`, the
  primary difference to be aware of is that the context contains a key, `:cluster`,
  which is the pid of the cluster manager, and is used to invoke functions in the
  `#{__MODULE__}.Cluster` module during tests.

      defmodule KVStoreTests do
        use ExUnit.ClusteredCase
        
        scenario "given a healthy cluster", [cluster_size: 3] do
        
          # You can use normal setup functions to setup context for the
          # test, this is run once prior to each test
          setup do
            {:ok, foo: :bar}
          end

          # Like `setup`, but is run on all nodes prior to each test
          node_setup do
            {:ok, _} = Application.ensure_all_started(:kv_store)
          end
          
          test "cluster has three nodes", %{cluster: c} = context do
            assert length(Cluster.members(c)) == 3
          end
        end
      end
      
  See the `ExUnit.Case` documentation for information on tags, filters, and more.
  """

  @doc false
  defmacro __using__(opts \\ []) do
    quote do
      @__clustered_case_scenario nil

      use ExUnit.Case, unquote(opts)

      alias unquote(__MODULE__).Cluster

      import unquote(__MODULE__), only: [scenario: 3, node_setup: 1, node_setup: 2]

      setup_all do
        on_exit(fn ->
          unquote(__MODULE__).Cluster.Supervisor.cleanup_clusters_for_test_module(__MODULE__)
        end)
      end
    end
  end

  @doc """
  Creates a new clustered test scenario.

  Usage of this macro is similar to that of `ExUnit.Case.describe/2`,
  but has some differences. While `describe/2` simply groups tests under a
  common description, `scenario/3` both describes the group of tests, and
  initializes a cluster which will be made available for each test in that scenario.

  NOTE: It is important to be aware that each scenario is a distinct cluster,
  and that all tests within a single scenario are running against the same
  cluster. If tests within a scenario may conflict with one another - perhaps by
  modifying shared state, or triggering crashes which may bring down shared
  processes, etc., then you have a couple options:

  - Disable async testing for the module 
  - Modify your tests to prevent conflict, e.g. writing to different keys 
    in a k/v store, rather than the same key
  - Split the scenario into many, where the tests can run in isolation.

  ## Options

  You can configure a scenario with the following options:

  - `cluster_size: integer`, will create a cluster of the given size, this option is mutually 
    exclusive with `:nodes`, if the latter is used, this option will be ignored.
  - `nodes: [[node_opt]]`, a list of node specifications to use when creating the cluster, 
    see `t:#{__MODULE__}.Node.node_opt/0` for specific options available. If used, 
    `:cluster_size` is ignored.
  - `env: [{String.t, String.t}]`, will set the given key/values in the environment 
    when creating nodes. If you need different values for each node, you will need to use `:nodes`
  - `erl_flags: [String.t]`, additional arguments to pass to `erl` when creating nodes, like `:env`,
    if you need different args for each node, you will need to use `:nodes`
  - `config: Keyword.t`, configuration overrides to apply to all nodes in the cluster
  - `boot_timeout: integer`, the amount of time to allow for nodes to boot, in milliseconds
  - `init_timeout: integer`, the amount of time to allow for nodes to be initialized, in milliseconds
  - `:hidden_connect`, boolean indicating if the node should be connected as hidden node.
    Default value is `true`.

  ## Examples

      defmodule KVStoreTest do
        use ExUnit.ClusteredCase
        
        @scenario_opts [cluster_size: 3]
        
        scenario "given a healthy cluster", @scenario_opts do
          node_setup do
            {:ok, _} = Application.ensure_all_started(:kv_store)
          end
          
          test "writes are replicated to all nodes", %{cluster: cluster} do
            writer = Cluster.random_member(cluster)
            key = self()
            value = key
            assert Cluster.call(writer, KVStore, :put, [key, value]) == :ok
            results = Cluster.map(cluster, KVStore, :get, [key])
            assert Enum.all?(results, fn val -> val == value end)
          end
        end
      end
      
  Since all scenarios are also describes, you can run all the tests for a
  scenario by it's description:

      mix test --only describe:"given a healthy cluster"

  or by passing the exact line the scenario starts on:

      mix test path/to/file:123

  Like `describe/2`, you cannot nest `scenario/3`. Use the same technique
  of named setups recommended in the `describe/2` documentation for composition.
  """
  defmacro scenario(message, options, do: block) do
    quote do
      if @__clustered_case_scenario do
        raise "cannot call scenario/2 inside another scenario. See the documentation " <>
                "for scenario/2 on named setups and how to handle hierarchies"
      end

      message = unquote(message)
      options = unquote(options)

      @__clustered_case_scenario message
      @__clustered_case_scenario_config options

      try do
        describe message do
          setup context do
            alias unquote(__MODULE__).Cluster.Supervisor, as: CS
            # Start cluster if not started
            {:ok, cluster} =
              CS.init_cluster_for_scenario!(
                __MODULE__,
                @__clustered_case_scenario,
                @__clustered_case_scenario_config
              )

            Map.put(context, :cluster, cluster)
          end

          unquote(block)
        end
      after
        @__clustered_case_scenario nil
        @__clustered_case_scenario_config nil
      end
    end
  end

  @doc """
  Like `ExUnit.Callbacks.setup/1`, but is executed on every node in the cluster.

  You can pass a block, a unary function as an atom, or a list of such atoms.

  If you pass a unary function, it receives the test setup context, however unlike
  `setup/1`, the value returned from this function does not modify the context. Use
  `setup/1` or `setup/2` for that.

  NOTE: This callback is invoked _on_ each node in the cluster for the given scenario.

  ## Examples

      def start_apps(_context) do
        {:ok, _} = Application.ensure_all_started(:kv_store)
        :ok
      end
      
      scenario "given a healthy cluster", [cluster_size: 3] do
        node_setup :start_apps

        node_setup do
          # This form is also acceptable
          {:ok, _} = Application.ensure_all_started(:kv_store)
        end
      end

  """
  defmacro node_setup(do: block) do
    quote do
      setup %{cluster: cluster} = context do
        results =
          unquote(__MODULE__).Cluster.map(cluster, fn ->
            unquote(block)
          end)

        case results do
          {:error, _} = err ->
            exit(err)

          _ ->
            :ok
        end

        context
      end
    end
  end

  defmacro node_setup(callback) when is_atom(callback) do
    quote do
      setup %{cluster: cluster} = context do
        results =
          unquote(__MODULE__).Cluster.map(cluster, __MODULE__, unquote(callback), [context])

        case results do
          {:error, _} = err ->
            exit(err)

          _ ->
            :ok
        end

        context
      end
    end
  end

  defmacro node_setup(callbacks) when is_list(callbacks) do
    quote bind_quoted: [callbacks: callbacks] do
      for cb <- callbacks do
        unless is_atom(cb) do
          raise ArgumentError, "expected list of callbacks as atoms, but got: #{callbacks}"
        end

        node_setup(cb)
      end
    end
  end

  @doc """
  Same as `node_setup/1`, but receives the test setup context as a parameter.

  ## Examples

      scenario "given a healthy cluster", [cluster_size: 3] do
        node_setup _context do
          # Do something on each node
        end
      end
  """
  defmacro node_setup(var, do: block) do
    quote do
      setup %{cluster: cluster} = context do
        result =
          unquote(__MODULE__).Cluster.each(cluster, fn ->
            case context do
              unquote(var) ->
                unquote(block)
            end
          end)

        case result do
          {:error, _} = err ->
            exit(err)

          _ ->
            :ok
        end

        context
      end
    end
  end
end
