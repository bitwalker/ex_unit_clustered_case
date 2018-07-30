defmodule ExUnit.ClusteredCase.Support do
  @moduledoc false

  def boot_timeout(default \\ 10_000) do
    case System.get_env("BOOT_TIMEOUT") do
      nil ->
        default
      val ->
        String.to_integer(val)
    end
  end

  def start_node(opts \\ []) do
    opts =
      case Keyword.get(opts, :boot_timeout) do
        nil ->
          Keyword.put(opts, :boot_timeout, boot_timeout())
        _to ->
          opts
      end
    ExUnit.ClusteredCase.Node.start(opts)
  end
end
