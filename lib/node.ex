defmodule ExUnit.ClusteredCase.Node do
  @moduledoc """
  This module handles starting new nodes
  
  You can specify various options when starting a node:

  - `:name`, takes either a string or an atom, in either long or short form,
    this sets the node name and id.
  - `:boot_timeout`, specifies the amount of time to wait for a node to perform it's
    initial boot sequence before timing out
  - `:init_timeout`, specifies the amount of time to wait for the node agent to complete
    initializing the node (loading and starting required applications, applying configuration,
    loading test modules, and executing post-start functions)
  - `:erl_flags`, a list of arguments to pass to `erl` when starting the node, e.g. `["-init_debug"]`
  - `:env`, a list of tuples containing environment variables to export in the node's environment,
    e.g. `[{"PORT", "8080"}]`
  - `:config`, a `Keyword` list containing configuration overrides to apply to the node,
    should be in the form of `[app: [key: value]]`
  - `:post_start_functions`, a list of functions, either captured or in `{module, function, args}` format,
    which will be invoked on the node after it is booted and initialized. Functions must be zero-arity.
  """
  
  alias ExUnit.ClusteredCaseError
  
  @type fun :: (() -> term) | {module, atom, [term]}
  @type node_opts :: [node_opt]
  @type node_opt :: {:name, String.t | atom}
                  | {:boot_timeout, pos_integer}
                  | {:init_timeout, pos_integer}
                  | {:erl_flags, [String.t]}
                  | {:env, [{String.t, String.t}]}
                  | {:config, Keyword.t}
                  | {:post_start_functions, [fun]}
  @type node_error :: :already_started
                    | :started_not_connected
                    | :boot_timeout
                    | :init_timeout
                    | :not_alive
                    
  @doc false
  @spec start(node_opts) :: {:ok, pid} | {:error, term}
  def start(opts) when is_list(opts) do
    do_start(opts, [])
  end
  
  @doc false
  @spec start_nolink(node_opts) :: {:ok, pid} | {:error, term}
  def start_nolink(opts) when is_list(opts) do
    do_start(opts, [:nolink])
  end

  defp do_start(opts, start_opts) do
    # We expect that the current node is already distributed
    unless Node.alive? do
      raise ClusteredCaseError, 
        "cannot run clustered test cases if distribution is not active! " <>
        "You can start distribution via Node.start/1, or with the --name flag."
    end
    
    if :nolink in start_opts do
      __MODULE__.Manager.start_nolink(opts)
    else
      __MODULE__.Manager.start_link(opts)
    end
  end
  
  @doc false
  defdelegate name(pid), to: __MODULE__.Manager
  
  @doc false
  @spec connect(pid | String.t | atom, [pid | String.t | atom]) :: :ok
  defdelegate connect(name, nodes), to: __MODULE__.Manager
  
  @doc false
  @spec stop(String.t | atom) :: :ok
  defdelegate stop(name), to: __MODULE__.Manager
  
  @doc false
  @spec run(pid | String.t | atom, fun) :: {:ok, term} | {:error, term}
  defdelegate run(name, fun), to: __MODULE__.Manager

  @doc false
  @spec run(pid | String.t | atom, fun, Keyword.t) :: {:ok, term} | {:error, term}
  defdelegate run(name, fun, opts), to: __MODULE__.Manager

  @doc false
  @spec run(pid | String.t | atom, module, atom, [term]) :: {:ok, term} | {:error, term}
  defdelegate run(name, m, f, a), to: __MODULE__.Manager

  @doc false
  @spec run(pid | String.t | atom, module, atom, [term], Keyword.t) :: {:ok, term} | {:error, term}
  defdelegate run(name, m, f, a, opts), to: __MODULE__.Manager
end
