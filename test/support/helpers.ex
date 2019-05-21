defmodule ExUnit.ClusteredCase.Support do
  @moduledoc false

  def boot_timeout(default \\ 10_000) do
    case System.get_env("BOOT_TIMEOUT") do
      nil when is_nil(default) ->
        10_000
      nil ->
        default
      val ->
        String.to_integer(val)
    end
  end

  def set_boot_timeout(opts) do
    to = boot_timeout(Keyword.get(opts, :boot_timeout))
    Keyword.put(opts, :boot_timeout, to)
  end

  def start_node(opts \\ []) do
    opts
    |> set_boot_timeout()
    |> ExUnit.ClusteredCase.Node.start()
  end

  def stop_node(node) do
    ExUnit.ClusteredCase.Node.stop(node)
  end
end
