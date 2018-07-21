defmodule ExUnit.ClusteredCase.App do
  @moduledoc false
  use Application
  
  alias ExUnit.ClusteredCase.Utils
  
  def start(_type, _args) do
    # We depend on the boot server, so start it if not started yet
    unless Process.whereis(:boot_server) do
      {:ok, _} = :erl_boot_server.start_link([{127,0,0,1}])
      host = '#{Utils.hostname()}'
      {:ok, host_ip} = :inet.getaddr(host, :inet)
      :erl_boot_server.add_slave(host_ip)
    end
    
    children = [
      {ExUnit.ClusteredCase.Cluster.Supervisor, []}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
