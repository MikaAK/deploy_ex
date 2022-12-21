import Config

config :ex_aws,
  access_key_id: [System.get_env("AWS_ACCESS_KEY_ID"), {:system, "AWS_ACCESS_KEY_ID"}, {:awscli, "default", 30}],
  secret_access_key: [System.get_env("AWS_SECRET_ACCESS_KEY"), {:system, "AWS_SECRET_ACCESS_KEY"}, {:awscli, "default", 30}]

config :ex_aws, :hackney_opts,
  follow_redirect: true,
  recv_timeout: 30_000
