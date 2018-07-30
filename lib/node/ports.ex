defmodule ExUnit.ClusteredCase.Node.Ports do
  @moduledoc false
  use DynamicSupervisor

  ## API

  @doc """
  Open a new port and link to it
  """
  def open_link(opts) do
    do_open(self(), opts, link: true)
  end

  @doc """
  Open a new port, but do not link to it
  """
  def open(opts) do
    do_open(self(), opts, [])
  end

  @doc """
  Retrieve the captured log from the given port
  """
  defdelegate get_captured_log(port), to: __MODULE__.Port

  ## Server

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, [args], name: __MODULE__)
  end

  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp do_open(owner_pid, opts, owner_opts) do
    child_opts = [restart: :temporary]
    args = [owner_pid, opts, owner_opts]
    spec = Supervisor.child_spec({__MODULE__.Port, args}, child_opts)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
