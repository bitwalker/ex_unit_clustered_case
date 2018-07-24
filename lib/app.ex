defmodule ExUnit.ClusteredCase.App do
  @moduledoc false
  use Application
  
  def start(_type, _args) do
    # We depend on the boot server, so start it if not started yet
    unless Process.whereis(:boot_server) do
      {:ok, _} = :erl_boot_server.start_link([{127,0,0,1}])
    end
    
    children = [
      {ExUnit.ClusteredCase.Node.Ports, []},
      {ExUnit.ClusteredCase.Cluster.Supervisor, []}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
