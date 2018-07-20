use Mix.Config

if File.exists?(Path.join(__DIR__, "#{Mix.env}.exs")) do
  import_config "#{Mix.env}.exs"
end
