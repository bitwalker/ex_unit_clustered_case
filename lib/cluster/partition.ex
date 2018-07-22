defmodule ExUnit.ClusteredCase.Cluster.Partition do
  @moduledoc false
  
  alias ExUnit.ClusteredCase.Cluster.PartitionChange
  
  @type opts :: pos_integer
              | [pos_integer]
              | [[node]]
  
  @type t :: [[node]]
  
  @doc """
  Given a list of nodes and partitioning options, generates a partition spec,
  which is a list of partitions, each of which is a list of nodes.
  """
  @spec new([node], opts) :: t
  def new(nodes, nil), 
    do: new(nodes, 1)
  def new(_nodes, 0), 
    do: {:error, {:invalid_partition_spec, :invalid_partition_count}}
  def new(nodes, n) when is_integer(n) do
    partition_count = div(length(nodes), n)
    if partition_count > 0 do
      # Break up into sized chunks
      parts = Enum.chunk_every(nodes, partition_count)
      # Split into the desired number of partitions, and overflow chunks
      {sized, overflow} = Enum.split(parts, n)
      # Split the correctly sized partitions to give us a partition to which
      # we can join all the overflow chunks, giving us one extra large partition
      {sized, overflow_part} = Enum.split(sized, n - 1)
      # Join the overflow and add back to the sized partitions list
      case List.flatten([overflow_part | overflow]) do
        [] ->
          # No overflow
          sized
        flattened ->
          sized ++ [flattened]
      end
    else
      # Oversized, so make one big partition
      new(nodes, 1)
    end
  end
  def new(nodes, [n | _] = spec) when is_integer(n) do
    partition_by_count(nodes, spec)
  end
  def new(nodes, [n | _] = spec) when is_list(n) do
    ln = length(nodes)
    lsn = length(List.flatten(spec))
    cond do
      ln > lsn ->
        {:error, {:invalid_partition_spec, :underspecified}}
      ln < lsn ->
        {:error, {:invalid_partition_spec, :duplicate_memberships}}
      :else ->
        partition_by_name(nodes, spec)
    end
  end
  
  defp partition_by_count(nodes, spec), 
    do: partition_by_count(nodes, spec, [])
  defp partition_by_count([], [], acc), 
    do: Enum.reverse(acc)
  defp partition_by_count([], spec, _acc), 
    do: {:error, {:invalid_partition_spec, {:too_many_partitions, spec}}}
  defp partition_by_count(_nodes, [], _acc), 
    do: {:error, {:invalid_partition_spec, :underspecified}}
  defp partition_by_count(nodes, [count | spec], acc) do
    {gathered, nodes} = Enum.split(nodes, count)
    partition_by_count(nodes, spec, [gathered | acc])
  end
  
  defp partition_by_name(nodes, spec), 
    do: partition_by_name(nodes, spec, [])
  defp partition_by_name([], [], acc), 
    do: Enum.reverse(acc)
  defp partition_by_name(nodes, [part | spec], acc) do
    {gathered, nodes} = Enum.split_with(nodes, fn n -> n in part end)
    partition_by_name(nodes, spec, [gathered | acc])
  end
  
  @doc """
  Given a list of nodes, current partition spec, and a new partition spec,
  this function calculates the difference between the old spec and the new spec, 
  and returns a `PartitionChange` struct which defines how to modify the current
  set of partitions to match the new partition spec.
  """
  @spec partition([node], t, t) :: PartitionChange.t
  def partition(nodes, old_spec, new_spec)
  
  def partition(nodes, nil, nil) do
    # No partitions, no change in spec, connect all nodes
    connects = 
      nodes
      |> Enum.map(fn n -> {n, nodes -- [n]} end)
      |> Map.new
    PartitionChange.new([nodes], connects, %{})
  end
  def partition(nodes, nil, new_spec) do
    # No partitions, initial partitioning, form all partitions
    connects =
      nodes
      |> Enum.map(fn n -> 
        {n, Enum.find(new_spec, fn ns -> n in ns end) -- [n]}
      end)
      |> Enum.reject(fn {_n, []} -> true; _ -> false end)
      |> Map.new
    PartitionChange.new(new_spec, connects, %{})
  end
  def partition(_nodes, old_spec, old_spec) do
    # Already partitioned, no change in spec
    PartitionChange.new(old_spec, %{}, %{})
  end
  def partition(nodes, old_spec, new_spec) do
    # Already patitioned, change in spec
    dg1 = :digraph.new()
    # For each partition
    for p <- old_spec do
      # Add the nodes of this partition as vertices in a graph
      for n <- p do
        :digraph.add_vertex(dg1, n)
      end
      # Then add edges between all nodes in the partition representing their connections
      for n1 <- p do
        for n2 <- p, n2 != n1 do
          :digraph.add_edge(dg1, n1, n2)
        end
      end
    end
    # Same for new partition spec
    dg2 = :digraph.new()
    for p <- new_spec do
      for n <- p do
        :digraph.add_vertex(dg2, n)
      end
      for n1 <- p do
        for n2 <- p, n2 != n1 do
          :digraph.add_edge(dg2, n1, n2)
        end
      end
    end
    # For each node, apply changes
    ops =
      for n <- nodes do
        old_outgoing = dg1 |> :digraph.out_neighbours(n) |> MapSet.new
        new_outgoing = dg2 |> :digraph.out_neighbours(n) |> MapSet.new
        connects = MapSet.difference(new_outgoing, old_outgoing)
        disconnects = MapSet.difference(old_outgoing, new_outgoing)
        {n, MapSet.to_list(connects), MapSet.to_list(disconnects)}
      end
    connects = 
      ops
      |> Enum.map(fn {n, connects, _} -> {n, connects} end)
      |> Enum.reject(fn {_n, []} -> true; _ -> false end)
      |> Map.new
    disconnects = 
      ops
      |> Enum.map(fn {n, _, disconnects} -> {n, disconnects} end)
      |> Enum.reject(fn {_n, []} -> true; _ -> false end)
      |> Map.new
    PartitionChange.new(new_spec, connects, disconnects)
  end
end
