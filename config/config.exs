import Config

# Logger metadata keys ExACP attaches to its log lines. Declaring them keeps
# the console formatter from dropping them (and Credo from flagging them).
config :logger, :console,
  metadata: [
    :error_class,
    :limit,
    :line_shape,
    :message_shape,
    :method_hash,
    :reason,
    :reason_shape,
    :request_id_hash,
    :return_shape,
    :size
  ]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
