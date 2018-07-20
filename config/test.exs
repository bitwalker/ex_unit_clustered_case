use Mix.Config

config :ex_unit_clustered_case,
  overriden_by: :undefined,
  env_var: System.get_env("SOME_VAR")
