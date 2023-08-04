defmodule ExUnit.ClusteredCase.Utils do
  @moduledoc false

  @doc """
  Returns true if distribution is configured for longnames,
  or false if using shortnames.
  """
  def longnames?, do: :net_kernel.longnames()

  @doc """
  Converts a node name into either short or long form
  depending on the current distribution type
  """
  @spec nodename(String.t() | atom) :: atom
  def nodename(name) when is_binary(name) do
    use_longnames = longnames?()

    case String.split(name, "@", parts: 2, trim: true) do
      [sname] when use_longnames ->
        :"#{sname}@127.0.0.1"

      [sname] ->
        :"#{sname}"

      [sname, host] when use_longnames ->
        :"#{sname}@#{host}"

      [sname, _host] ->
        :"#{sname}"
    end
  end

  def nodename(name) when is_atom(name) do
    nodename(Atom.to_string(name))
  end

  @doc """
  Returns the hostname of the current node
  """
  @spec hostname() :: String.t()
  def hostname() do
    result =
      if longnames?() do
        :net_adm.localhost()
      else
        {:ok, name} = :inet.gethostname()
        name
      end

    List.to_string(result)
  end

  @doc """
  Returns the name of the flag representing the distributed name type to use
  """
  @spec name_type() :: :name | :sname
  def name_type() do
    if longnames?() do
      :name
    else
      :sname
    end
  end

  @doc """
  Returns a new, unique node name, based on a namespace and a random suffix
  """
  @spec generate_name() :: node
  def generate_name() do
    bytes = :crypto.strong_rand_bytes(8)
    suffix = Base.encode32(bytes, padding: false)
    basename = <<"ex_unit_clustered_node_", suffix::binary>>
    nodename(basename)
  end

  def hidden_connect_key() do
    "HIDDEN_CONNECT"
  end
end
