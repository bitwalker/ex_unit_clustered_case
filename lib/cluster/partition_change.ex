defmodule ExUnit.ClusteredCase.Cluster.PartitionChange do
  @moduledoc false

  alias ExUnit.ClusteredCase.Cluster.Partition

  defstruct [:partitions, :connects, :disconnects]

  @type connects :: %{node => [node]}
  @type disconnects :: %{node => [node]}

  @type t :: %__MODULE__{
          partitions: Partition.t(),
          connects: connects,
          disconnects: disconnects
        }

  @doc """
  Create a new PartitionChange given a list of partitions, and the set of
  connection and disconnection operations needed to perform the change.
  """
  @spec new(Partition.t(), connects, disconnects) :: t
  def new(partitions, connects, disconnects) do
    %__MODULE__{
      partitions: partitions,
      connects: connects,
      disconnects: disconnects
    }
  end

  @doc """
  Executes the given PartitionChange by performing required connects/disconnects.

  **NOTE**: This function has side-effects! It calls out to the actual nodes to make changes.
  """
  @spec execute!(t) :: :ok
  def execute!(%__MODULE__{connects: cs, disconnects: dcs}) do
    for {n, ns} <- dcs, do: ExUnit.ClusteredCase.Node.disconnect(n, ns)
    for {n, ns} <- cs, do: ExUnit.ClusteredCase.Node.connect(n, ns)
    :ok
  end
end
