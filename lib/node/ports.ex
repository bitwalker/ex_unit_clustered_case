defmodule ExUnit.ClusteredCase.Node.Ports do
  @moduledoc false
  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, [args], name: __MODULE__)
  end

  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def open_link(opts) do
    do_open(self(), opts, link: true)
  end

  def open(opts) do
    do_open(self(), opts, [])
  end

  defp do_open(owner_pid, opts, owner_opts) do
    child_opts = [restart: :temporary]
    args = [owner_pid, opts, owner_opts]
    spec = Supervisor.child_spec({__MODULE__.Port, args}, child_opts)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
