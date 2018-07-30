defmodule ExUnit.ClusteredCase.Test.PartitionTest do
  use ExUnit.Case, async: true

  alias ExUnit.ClusteredCase.Cluster.Partition

  @nodes [:a, :b, :c, :d, :e, :f, :g]

  describe "given an unpartitioned cluster" do
    test "no spec is equivalent to one large partition" do
      spec = Partition.new(@nodes, nil)
      change = Partition.partition(@nodes, nil, spec)
      assert [@nodes] = change.partitions
      assert map_size(change.connects) == length(@nodes)
      assert map_size(change.disconnects) == 0

      spec2 = Partition.new(@nodes, 1)
      change2 = Partition.partition(@nodes, nil, spec2)
      assert spec2 == spec
      assert change2 == change
    end

    test "an integer spec, when nodes divisible by that number" do
      nodes = [:a, :b, :c, :d]
      spec = Partition.new(nodes, 2)
      change = Partition.partition(nodes, nil, spec)
      assert [[:a, :b], [:c, :d]] = change.partitions
      assert map_size(change.connects) == length(nodes)
      assert map_size(change.disconnects) == 0
    end

    test "an integer spec, when nodes not divisible by that number" do
      spec = Partition.new(@nodes, 2)
      change = Partition.partition(@nodes, nil, spec)
      assert [[:a, :b, :c], [:d, :e, :f, :g]] = change.partitions
      assert map_size(change.connects) == length(@nodes)
      assert map_size(change.disconnects) == 0
    end

    test "an invalid integer spec returns an error" do
      assert {:error, {:invalid_partition_spec, _}} = Partition.new(@nodes, 0)
    end

    test "a list of partition sizes, partitionable" do
      spec = Partition.new(@nodes, [2, 2, 3])
      change = Partition.partition(@nodes, nil, spec)
      assert [[:a, :b], [:c, :d], [:e, :f, :g]] = change.partitions
      assert map_size(change.connects) == length(@nodes)
      assert [:b] = change.connects[:a]
      assert map_size(change.disconnects) == 0
    end

    test "a list of partition sizes, not partitionable, returns an error" do
      assert {:error, {:invalid_partition_spec, :underspecified}} = Partition.new(@nodes, [2, 2])

      assert {:error, {:invalid_partition_spec, {:too_many_partitions, _}}} =
               Partition.new(@nodes, [2, 2, 2, 2, 2])
    end

    test "a list of partitioned names, partitionable" do
      spec = Partition.new(@nodes, [[:a, :b, :c], [:d], [:e, :f, :g]])
      change = Partition.partition(@nodes, nil, spec)
      assert [[:a, :b, :c], [:d], [:e, :f, :g]] = change.partitions
      # d doesn't attempt to connect to anyone
      assert map_size(change.connects) == length(@nodes) - 1
      assert [:b, :c] = change.connects[:a]
      assert map_size(change.disconnects) == 0
    end

    test "a list of partitioned names, does not allow multi-partition membership" do
      assert {:error, {:invalid_partition_spec, :duplicate_memberships}} =
               Partition.new(@nodes, [[:a, :b, :c], [:a, :d], [:e, :f, :g]])
    end

    test "a list of partitioned names, expects all memberships to be specified" do
      assert {:error, {:invalid_partition_spec, :underspecified}} =
               Partition.new(@nodes, [[:a, :b, :c]])
    end
  end

  describe "given a partitioned cluster" do
    setup do
      spec = Partition.new(@nodes, [[:a, :b], [:c, :d], [:e, :f, :g]])
      [old_spec: spec]
    end

    test "healing the cluster", %{old_spec: old_spec} do
      spec = Partition.new(@nodes, 1)
      change = Partition.partition(@nodes, old_spec, spec)
      assert [@nodes] = change.partitions
      assert map_size(change.connects) == length(@nodes)
      assert map_size(change.disconnects) == 0
    end

    test "no change in partitioning", %{old_spec: old_spec} do
      spec = Partition.new(@nodes, [[:a, :b], [:c, :d], [:e, :f, :g]])
      change = Partition.partition(@nodes, old_spec, spec)
      assert map_size(change.connects) == 0
      assert map_size(change.disconnects) == 0
    end

    test "repartitioning into more partitions", %{old_spec: old_spec} do
      spec = Partition.new(@nodes, [[:a, :b], [:c, :d], [:e, :f], [:g]])
      change = Partition.partition(@nodes, old_spec, spec)
      assert map_size(change.connects) == 0
      assert map_size(change.disconnects) == 3
    end

    test "repartitioning into fewer partitions", %{old_spec: old_spec} do
      spec = Partition.new(@nodes, [[:a, :b], [:c, :d, :e, :f, :g]])
      change = Partition.partition(@nodes, old_spec, spec)
      assert map_size(change.connects) == 5
      assert map_size(change.disconnects) == 0
    end
  end
end
