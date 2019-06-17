defmodule ExUnit.ClusteredCase.App do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children =
      case in_cluster_node?() do
        true ->
          []

        false ->
          # We depend on the boot server, so start it if not started yet
          unless Process.whereis(:boot_server) do
            {:ok, _} = :erl_boot_server.start_link([{127, 0, 0, 1}])
          end

          [
            {ExUnit.ClusteredCase.Node.Ports, []},
            {ExUnit.ClusteredCase.Cluster.Supervisor, []}
          ]
      end

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp in_cluster_node? do
    node_name() =~ "ex_unit_clustered_node_"
  end

  defp node_name do
    Node.self()
    |> Atom.to_string()
  end
end
