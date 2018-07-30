defmodule ExUnit.ClusteredCaseError do
  @moduledoc false

  defexception [:message]

  def exception(err) when is_binary(err) do
    %__MODULE__{message: err}
  end
end
