import Config

config :ex_aws,
  access_key_id: [System.get_env("AWS_ACCESS_KEY_ID"), {:system, "AWS_ACCESS_KEY_ID"}, {:awscli, System.get_env("AWS_PROFILE", "default"), 30}, :instance_role],
  secret_access_key: [System.get_env("AWS_SECRET_ACCESS_KEY"), {:system, "AWS_SECRET_ACCESS_KEY"}, {:awscli, System.get_env("AWS_PROFILE", "default"), 30}, :instance_role]

config :ex_aws, :hackney_opts,
  follow_redirect: true,
  recv_timeout: 30_000

config :deploy_ex,
  tui_enabled: System.get_env("DEPLOY_EX_TUI_ENABLED", "true") !== "false"

if System.get_env("CI") in ["true", true] do
  config :erlexec,
    root: true,
    user: "root",
    limit_users: ["root"]
end

# Real (non-nil) :oci namespace value so tests can assert on a literal instead of comparing a
# provider-config accessor against its own read of the same key — a nil===nil comparison would
# stay green whether the accessor reads the right namespace or nothing at all. :release_bucket
# is deliberately left UNSET here — DeployEx.CloudTest's "unset config" tests need a real,
# registered provider whose value is genuinely nil to prove the loud-error path.
if config_env() === :test do
  config :deploy_ex, :oci, resource_group: "OCI Test Backend"
end
