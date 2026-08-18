defmodule Mix.Tasks.Ansible.Build do
  use Mix.Task

  alias DeployEx.Config

  @ansible_default_path Config.ansible_folder_path()
  @terraform_default_path Config.terraform_folder_path()
  @aws_credentials_regex ~r/aws_access_key_id = (?<access_key>[A-Z0-9]+)\naws_secret_access_key = (?<secret_key>[a-z-A-Z0-9\/\+]+)\n/
  @render_dir_pem_file_path "../terraform/RENDER_DIR_PLACEHOLDER.pem"

  @shortdoc "Builds ansible files into your repository"
  @moduledoc """
  Builds ansible files into the respository, this can be used if you
  change terraform settings and want to regenerate any ansible files

  ## Options
  - `directory` - Ansible directory path (default: #{@ansible_default_path})
  - `terraform_directory` - Terraform directory path (default: #{@terraform_default_path})
  - `provider` - Cloud provider file set to render (default: `DeployEx.Config.cloud_provider/0`)
  - `render_dir` - Render every ansible file into this directory instead of the live
    tree, using a placeholder pem path rather than globbing for a real one. Used by
    the render diff harness to compare output across revisions.
  - `force` - Force overwrite existing files
  - `quiet` - Suppress output messages
  - `host_only` - Only generate host configuration files
  - `new_only` - Only generate files for new applications
  - `auto_pull_aws` - Automatically pull AWS credentials from ~/.aws/credentials (aws only)
  - `aws_release_bucket` - AWS S3 bucket for releases
  - `oci_compartment_id` - OCI compartment to list instances from when building the
    static inventory (default: `config :deploy_ex, :oci, compartment_id: ...`)
  - `oci_profile` - OCI CLI profile (default: `config :deploy_ex, :oci, profile: ...`)
  - `oci_region` - OCI region (default: `config :deploy_ex, :oci, region: ...`)
  - `oci_namespace` - OCI Object Storage namespace, required for the oci provider
    (default: `config :deploy_ex, :oci, namespace: ...`)
  - `oci_release_bucket` - OCI Object Storage bucket for releases
    (default: `config :deploy_ex, :oci, release_bucket: ...`)
  - `no_logging` - Disable logging configuration (Alloy + Loki)
  - `no_loki` - Deprecated alias for `no_logging`
  - `no_sentry` - Disable Sentry error tracking configuration
  - `no_grafana` - Disable Grafana monitoring configuration
  - `no_prometheus` - Disable Prometheus metrics configuration
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    parsed_opts = parse_args(args)

    # --provider overrides the configured cloud_provider. Resolved once so the seed, the
    # inventory render and ansible.cfg can never disagree about which file set they use —
    # mirrors terraform.build.ex's resolve_provider/1.
    provider = resolve_provider(parsed_opts)

    opts = parsed_opts
      |> put_render_dir_paths(provider)
      |> Keyword.put_new(:directory, @ansible_default_path)
      |> Keyword.put_new(:terraform_directory, @terraform_default_path)
      |> Keyword.put_new(:hosts_file, "./deploys/ansible/#{inventory_filename(provider)}")
      |> Keyword.put_new(:config_file, "./deploys/ansible/ansible.cfg")
      |> Keyword.put_new(:group_vars_file, "./deploys/ansible/group_vars/all.yaml")
      |> Keyword.put_new(:aws_logging_bucket, Config.aws_log_bucket())
      |> Keyword.put_new(:aws_logging_region, Config.aws_log_region())
      |> Keyword.put_new(:aws_release_bucket, Config.aws_release_bucket())
      |> Keyword.put_new(:aws_region, Config.aws_region())

    no_logging = opts[:no_logging] || opts[:no_loki] || false
    opts = Keyword.put(opts, :no_logging, no_logging)

    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- validate_provider_opts(provider, opts),
         :ok <- ensure_ansible_directory_exists(opts[:directory], provider, opts),
         :ok <- sync_ansible_roles(opts[:directory], provider, opts),
         :ok <- seed_new_setup_playbooks(opts[:directory], opts),
         :ok <- create_ansible_hosts_file(provider, opts),
         :ok <- create_ansible_config_file(provider, opts),
         :ok <- create_ansible_group_vars_file(provider, opts),
         {:ok, app_names} <- DeployExHelpers.fetch_mix_release_names(),
         :ok <- create_ansible_playbooks(app_names, provider, opts) do
      :ok
    else
      {:error, [h | tail]} ->
        Enum.each(tail, &Mix.shell().error(to_string(&1)))
        Mix.raise(to_string(h))

      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  # Runs BEFORE ensure_ansible_directory_exists/3 on purpose: fetch_oci_instances/1 raised the
  # same "compartment_id is required" error, but only once create_ansible_hosts_file/2 got
  # around to calling it — after the tree was already seeded, leaving a half-built directory
  # full of unrendered .eex behind a raise. Validating first means a bad invocation never
  # touches the filesystem at all.
  defp validate_provider_opts(provider, opts) do
    with :ok <- validate_auto_pull_aws(provider, opts) do
      validate_provider_config(provider, opts)
    end
  end

  # A flag the provider does not support is a usage error, so it is reported before any
  # environment requirement — otherwise `--provider oci --auto-pull-aws` complains about
  # missing OCI config and never mentions that the flag itself is the problem. This check also
  # lived inside the directory-seeding branch, so it only fired when the tree did not already
  # exist: re-running against an existing ./deploys ignored the flag silently.
  defp validate_auto_pull_aws(:aws, _opts), do: :ok

  defp validate_auto_pull_aws(provider, opts) do
    if opts[:auto_pull_aws] do
      {:error,
       ErrorMessage.bad_request("--auto-pull-aws only supports the aws provider, got #{inspect(provider)}")}
    else
      :ok
    end
  end

  defp validate_provider_config(:oci, opts) do
    with {:ok, _compartment_id} <- require_oci_compartment_id(opts),
         {:ok, _namespace} <- require_oci_namespace(opts) do
      :ok
    end
  end

  defp validate_provider_config(_provider, _opts), do: :ok

  # Matches the flag against the registered providers rather than calling to_existing_atom/1 —
  # see terraform.build.ex's identical resolve_provider/1 for the rationale.
  defp resolve_provider(opts) do
    case opts[:provider] do
      nil ->
        DeployEx.Config.cloud_provider()

      name ->
        known = DeployEx.Cloud.providers()

        case Enum.find(known, &(to_string(&1) === name)) do
          nil -> Mix.raise("unknown provider #{inspect(name)}, expected one of #{inspect(known)}")
          provider -> provider
        end
    end
  end

  # Single source of truth for "what is this provider's inventory called" — the descriptor's
  # inventory/0 slot, also read by Mix.Tasks.Ansible.{Setup,Deploy,Ping}. Keeping ansible.build
  # on its own hardcoded filename here (instead of the same lookup) would let this task and
  # the ones that consume its output silently drift apart on a provider swap.
  defp inventory_filename(provider) do
    case DeployEx.Cloud.inventory(provider) do
      {:ok, %{filename: filename}} -> filename
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp inventory_template_filename(provider), do: "#{inventory_filename(provider)}.eex"

  defp put_render_dir_paths(opts, provider) do
    case opts[:render_dir] do
      nil ->
        opts

      render_dir ->
        opts
          |> Keyword.put(:directory, render_dir)
          |> Keyword.put(:hosts_file, Path.join(render_dir, inventory_filename(provider)))
          |> Keyword.put(:config_file, Path.join(render_dir, "ansible.cfg"))
          |> Keyword.put(:group_vars_file, Path.join(render_dir, "group_vars/all.yaml"))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, a: :auto_pull_aws, h: :host_only, n: :new_only],
      switches: [
        new_only: :boolean,
        force: :boolean,
        host_only: :boolean,
        quiet: :boolean,
        directory: :string,
        render_dir: :string,
        provider: :string,
        terraform_directory: :string,
        auto_pull_aws: :boolean,
        aws_release_bucket: :string,
        oci_compartment_id: :string,
        oci_profile: :string,
        oci_region: :string,
        oci_namespace: :string,
        oci_release_bucket: :string,
        no_logging: :boolean,
        no_loki: :boolean,
        no_sentry: :boolean,
        no_grafana: :boolean,
        no_prometheus: :boolean
      ]
    )

    opts
  end

  # Setup playbooks and the playbook/group_vars templates are shared across providers, so
  # they're seeded verbatim for everyone via the same whole-tree copy as before. The
  # `providers/` subtree is provider-EXCLUSIVE content (ansible.cfg.eex, the hosts template,
  # and now the oci-only role variants under providers/oci/roles) that's about to be rendered
  # fresh by create_ansible_config_file/2, create_ansible_hosts_file/2, and
  # sync_ansible_roles/3 regardless — copying it raw here would leak an oci user's
  # ansible.cfg.eex (or role files) into an aws tree (and vice versa) and then sit there
  # unused, so it's stripped right back out.
  defp ensure_ansible_directory_exists(directory, provider, opts) do
    if File.exists?(directory) do
      :ok
    else
      File.mkdir_p!(directory)

      Mix.shell().info([:green, "* copying ansible into ", :reset, directory])

      "ansible"
        |> DeployExHelpers.priv_folder()
        |> File.cp_r!(directory)

      providers_dir = Path.join(directory, "providers")

      if File.dir?(providers_dir) do
        File.rm_rf!(providers_dir)
      end

      # aws_ec2.yaml.eex is the one root-level template with no same-path counterpart for
      # other providers (ansible.cfg.eex is shared-by-name and always gets overwritten below
      # regardless of which provider rendered it) — so it's the one leftover a non-aws build
      # would otherwise leak, unused, into the tree.
      if provider !== :aws do
        aws_hosts_template = Path.join(directory, inventory_template_filename(:aws))

        if File.exists?(aws_hosts_template) do
          File.rm!(aws_hosts_template)
        end
      end

      File.rm!(Path.join(directory, "group_vars/all.yaml.eex"))

      create_ansible_group_vars_file(provider, opts)

      if opts[:auto_pull_aws] do
        pull_aws_credentials_into_awscli_variables(directory, opts)
      end

      :ok
    end
  end

  defp pull_aws_credentials_into_awscli_variables(ansible_directory, opts) do
    main_yaml_path = Path.join(ansible_directory, "group_vars/all.yaml")

    case search_for_aws_credentials() do
      {:ok, {aws_access_key, aws_secret_access_key}} ->
        new_contents = main_yaml_path
          |> File.read!
          |> String.replace(
            "AWS_ACCESS_KEY_ID: \"<INSERT_SECRET_OR_PRELOAD_ON_MACHINE>\"",
            "AWS_ACCESS_KEY_ID: \"#{aws_access_key}\""
          )
          |> String.replace(
            "AWS_SECRET_ACCESS_KEY: \"<INSERT_SECRET_OR_PRELOAD_ON_MACHINE>\"",
            "AWS_SECRET_ACCESS_KEY: \"#{aws_secret_access_key}\""
          )

        opts = opts
          |> Keyword.put_new(:force, true)
          |> Keyword.put(:message, [:green, "* injecting aws credentials into ", :reset, main_yaml_path])

        DeployExHelpers.write_file(main_yaml_path, new_contents, opts)

      {:error, e} ->
        Mix.shell().error(to_string(e))
    end
  end

  defp search_for_aws_credentials do
    credentials_file = Path.expand("~/.aws/credentials")

    if File.exists?(credentials_file) do
      credentials_content = File.read!(credentials_file)

      captures = Regex.named_captures(@aws_credentials_regex, credentials_content)

      if is_nil(captures) do
        {:error, ErrorMessage.not_found("couldn't parse credentials in file at ~/.aws/credentials")}
      else
        %{
          "access_key" => access_key,
          "secret_key" => secret_access_key
        } = captures

        {:ok, {access_key, secret_access_key}}
      end
    else
      {:error, ErrorMessage.not_found("couldn't find credentials file at ~/.aws/credentials")}
    end
  end

  defp create_ansible_group_vars_file(provider, opts) do
    if opts[:host_only] do
      :ok
    else
      with {:ok, template_path} <- find_provider_template(provider, "group_vars/all.yaml.eex") do
        DeployExHelpers.write_template(
          template_path,
          opts[:group_vars_file],
          group_vars_template_variables(provider, opts),
          opts
        )

        if File.exists?("#{opts[:group_vars_file]}.eex") do
          File.rm!("#{opts[:group_vars_file]}.eex")
        end

        :ok
      end
    end
  end

  defp group_vars_template_variables(:oci, opts) do
    %{
      is_logging_enabled: !opts[:no_logging],
      is_prometheus_enabled: !opts[:no_prometheus],
      oci_namespace: oci_setting(opts, :namespace),
      oci_release_bucket: oci_release_bucket(opts),
      oci_vcn_cidr: oci_setting(opts, :vcn_cidr) || "10.20.0.0/16"
    }
  end

  defp group_vars_template_variables(_provider, opts) do
    %{
      is_logging_enabled: !opts[:no_logging],
      is_prometheus_enabled: !opts[:no_prometheus],
      loki_logger_s3_region: opts[:aws_logging_bucket],
      loki_logger_s3_bucket_name: opts[:aws_logging_region]
    }
  end

  defp create_ansible_config_file(provider, opts) do
    if opts[:host_only] do
      :ok
    else
      app_name = String.replace(DeployExHelpers.underscored_project_name(), "_", "-")

      variables = %{
        pem_file_path: config_pem_file_path(app_name, opts)
      }

      with {:ok, template_path} <- find_provider_template(provider, "ansible.cfg.eex") do
        DeployExHelpers.write_template(template_path, opts[:config_file], variables, opts)

        if File.exists?("#{opts[:config_file]}.eex") do
          File.rm!("#{opts[:config_file]}.eex")
        end

        :ok
      end
    end
  end

  defp create_ansible_hosts_file(provider, opts) do
    with {:ok, template_path} <- find_provider_template(provider, inventory_template_filename(provider)),
         {:ok, variables} <- hosts_template_variables(provider, opts) do
      DeployExHelpers.write_template(template_path, opts[:hosts_file], variables, opts)

      if File.exists?("#{opts[:hosts_file]}.eex") do
        File.rm!("#{opts[:hosts_file]}.eex")
      end

      remove_other_provider_inventories(provider, opts)

      :ok
    end
  end

  @doc false
  # Re-running ansible.build with a DIFFERENT --provider against an already-built directory
  # only overwrites ansible.cfg and adds the new provider's inventory file — it never touched
  # the previous provider's leftover inventory file, which would then sit there stale while
  # ansible.cfg's `inventory =` line (correctly) points elsewhere. ansible.setup/deploy/ping's
  # preflight existence check would find that stale file and pass, checking the WRONG
  # provider's inventory while ansible-playbook itself reads the freshly-rendered one from
  # cfg — the "cfg says X, something else says Y" trap this exists to close. Deleting every
  # OTHER known provider's inventory file on each build keeps exactly one inventory file
  # present at a time, so a provider switch is either fully clean or (missing template/config)
  # loudly broken, never silently mixed. Public (not private) so this is unit-testable without
  # a live oci CLI: the impure fetch and this cleanup are separate steps on purpose.
  def remove_other_provider_inventories(provider, opts) do
    DeployEx.Cloud.providers()
    |> Enum.reject(&(&1 === provider))
    |> Enum.each(&remove_stale_inventory(&1, opts[:directory]))
  end

  defp remove_stale_inventory(other_provider, directory) do
    case DeployEx.Cloud.inventory(other_provider) do
      {:ok, %{filename: filename}} ->
        stale_path = Path.join(directory, filename)

        if File.exists?(stale_path) do
          File.rm!(stale_path)
        end

      {:error, _not_implemented} ->
        :ok
    end
  end

  # Resolves which priv template a provider uses for a given rendered filename via
  # DeployEx.Cloud.PrivFileSet, the same seam terraform.build.ex uses for its whole file
  # set. Here it's used per-file rather than tree-wide because most of priv/ansible (roles,
  # setup, playbook templates) is shared across providers and only ansible.cfg/the hosts
  # template actually vary.
  defp find_provider_template(provider, dest_filename) do
    priv_path = DeployExHelpers.priv_folder("ansible")

    with {:ok, files} <- DeployEx.Cloud.PrivFileSet.files(provider, priv_path) do
      case Enum.find(files, fn {_source, dest} -> dest === dest_filename end) do
        {source, _dest} ->
          {:ok, Path.join(priv_path, source)}

        nil ->
          {:error,
           ErrorMessage.not_found("no #{dest_filename} template for #{provider} under #{priv_path}", %{
             provider: provider,
             filename: dest_filename
           })}
      end
    end
  end

  defp hosts_template_variables(:aws, _opts) do
    {:ok, %{app_name: DeployExHelpers.underscored_project_name()}}
  end

  defp hosts_template_variables(_provider, opts) do
    with {:ok, instances} <- fetch_oci_instances(opts) do
      hosts = oci_inventory_hosts(instances)

      {:ok, %{
        hosts_section: render_oci_hosts_section(hosts),
        children_section: render_oci_children_section(hosts)
      }}
    end
  end

  defp config_pem_file_path(app_name, opts) do
    if opts[:render_dir] do
      @render_dir_pem_file_path
    else
      pem_file_path(app_name, opts[:directory])
    end
  end

  defp pem_file_path(app_name, directory) do
    pem_file_path = directory
      |> String.split("/")
      |> Enum.drop(-1)
      |> Enum.join("/")
      |> Path.join("terraform/#{app_name}*pem")

    directory_path = pem_file_path
      |> Path.wildcard
      |> then(&(List.first(&1) || ""))
      |> String.split("/")
      |> Enum.drop(1)

    if directory_path === [] do
      Mix.raise("No PEM file found matching glob #{pem_file_path}, have you run mix terraform.apply yet?")
    end

    Enum.join([".." | directory_path], "/")
  end

  def host_name(host_name, index) do
    "#{host_name}_#{:io_lib.format("~3..0B", [index])}"
  end

  defp create_ansible_playbooks(app_names, provider, opts) do
    if opts[:host_only] do
      :ok
    else
      project_playbooks_path = Path.join(opts[:directory], "playbooks")
      project_setup_playbooks_path = Path.join(opts[:directory], "setup")

      if not File.exists?(project_playbooks_path) do
        File.mkdir_p!(project_playbooks_path)
      end

      if not File.exists?(project_setup_playbooks_path) do
        File.mkdir_p!(project_setup_playbooks_path)
      end

      if opts[:new_only] do
        deploy_new_playbooks(
          app_names,
          provider,
          project_playbooks_path,
          project_setup_playbooks_path,
          opts
        )
      else
        deploy_all_playbooks(app_names, provider, opts)
      end

      remove_usless_copied_template_folder(opts)

      :ok
    end
  end

  defp deploy_all_playbooks(app_names, provider, opts) do
    Enum.each(app_names, fn app_name ->
      build_host_setup_playbook(app_name, provider, opts)
      build_host_playbook(app_name, opts)
    end)
  end

  defp deploy_new_playbooks(app_names, provider, project_playbooks_path, project_setup_playbooks_path, opts) do
    project_deploy_files = File.ls!(project_playbooks_path)
    project_setup_files = File.ls!(project_setup_playbooks_path)

    Enum.each(app_names, fn app_name ->
      if not Enum.any?(project_setup_files, &(&1 =~ app_name)) do
        build_host_setup_playbook(app_name, provider, opts)
      end

      if not Enum.any?(project_deploy_files, &(&1 =~ app_name)) do
        build_host_playbook(app_name, opts)
      end
    end)
  end

  defp build_host_playbook(app_name, opts) do
    host_playbook_template_path = DeployExHelpers.priv_folder("ansible/app_playbook.yaml.eex")
    host_playbook_path = Path.join(opts[:directory], "playbooks/#{app_name}.yaml")

    variables = %{
      no_logging: opts[:no_logging],
      no_prometheus: opts[:no_prometheus],
      app_name: app_name,
      port: 80
    }

    DeployExHelpers.write_template(
      host_playbook_template_path,
      host_playbook_path,
      variables,
      opts
    )
  end

  defp build_host_setup_playbook(app_name, provider, opts) do
    setup_playbook_path = DeployExHelpers.priv_folder("ansible/app_setup_playbook.yaml.eex")
    setup_host_playbook = Path.join(opts[:directory], "setup/#{app_name}.yaml")

    variables = %{
      no_logging: opts[:no_logging],
      no_prometheus: opts[:no_prometheus],
      app_name: app_name,
      port: 80,
      cloud_provider: provider
    }

    DeployExHelpers.write_template(
      setup_playbook_path,
      setup_host_playbook,
      variables,
      opts
    )
  end

  defp sync_ansible_roles(directory, provider, opts) do
    priv_roles = DeployExHelpers.priv_folder("ansible/roles")
    target_roles = Path.join(directory, "roles")

    if File.dir?(priv_roles) and File.dir?(target_roles) do
      unless opts[:quiet] do
        Mix.shell().info([:green, "* syncing ", :reset, "ansible roles"])
      end

      File.cp_r!(priv_roles, target_roles)
      sync_provider_role_overlay(provider, target_roles)
    end

    :ok
  end

  # Setup playbooks were seeded only when the ansible directory was first created, so a role
  # added to deploy_ex later (rabbitmq_server) synced its ROLE into an existing tree but never
  # its setup/<name>.yaml — `mix ansible.setup --only rabbitmq` then matched no file and
  # exited 0 having done nothing (measured). Only NEW playbooks are seeded: existing ones are
  # user-owned (operators hand-add roles to them) and are never overwritten here.
  defp seed_new_setup_playbooks(directory, opts) do
    priv_setup = DeployExHelpers.priv_folder("ansible/setup")
    target_setup = Path.join(directory, "setup")

    if File.dir?(priv_setup) and File.dir?(target_setup) do
      priv_setup
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> Enum.reject(&File.exists?(Path.join(target_setup, Path.basename(&1))))
      |> Enum.each(fn source ->
        target = Path.join(target_setup, Path.basename(source))
        File.cp!(source, target)

        unless opts[:quiet] do
          Mix.shell().info([:green, "* seeding new setup playbook ", :reset, target])
        end
      end)
    end

    :ok
  end

  # AWS is the shared role tree as-is — there is no providers/aws/roles directory, so this
  # is a no-op for it. A provider with its own role variants (e.g. OCI's deploy_node
  # tasks/main.yaml and files/*.sh, which use the oci CLI instead of aws s3) ships them
  # under providers/<name>/roles/ mirroring the shared roles/ layout; copying that tree on
  # top after the shared copy above overlays/replaces just those files, leaving every other
  # role byte-identical to the shared set.
  defp sync_provider_role_overlay(provider, target_roles) do
    provider_roles = DeployExHelpers.priv_folder("ansible/providers/#{provider}/roles")

    if File.dir?(provider_roles) do
      File.cp_r!(provider_roles, target_roles)
    end

    :ok
  end

  defp remove_usless_copied_template_folder(opts) do
    template_file = Path.join(opts[:directory], "app_playbook.yaml.eex")
    setup_template_file = Path.join(opts[:directory], "app_setup_playbook.yaml.eex")

    if File.exists?(template_file) do
      File.rm!(template_file)
    end

    if File.exists?(setup_template_file) do
      File.rm!(setup_template_file)
    end
  end

  # SECTION OCI STATIC INVENTORY
  #
  # AWS resolves hosts live at ansible-run-time through the aws_ec2 plugin. OCI has no
  # inventory plugin we're willing to add as a collection dependency, so this queries the
  # `oci` CLI directly (no DeployEx.Cloud.Machine capability exists for OCI yet) and renders
  # a point-in-time snapshot — regenerated on every `mix ansible.build` run, same as the rest
  # of the hosts file.
  #
  # The four-part contract this mirrors from aws_ec2.yaml.eex: group names keyed off
  # MonitoringKey/InstanceGroup/DatabaseKey/QaNode tags, the same seven tag-derived hostvars
  # plus ansible_host, hostname = "<instance-id>-<Name tag>", and the project-scope filter
  # on the Group tag. NOTE: deploy_ex has no SharedUtils dependency (it isn't part of the
  # umbrella apps that vendor it), so the tag-filtering below is plain Enum, not
  # SharedUtils.Enum.reject_empty_values/1.

  @oci_keyed_group_tags [
    {"MonitoringKey", "monitoring"},
    {"InstanceGroup", "group"},
    {"DatabaseKey", "database"},
    {"QaNode", "qa"}
  ]

  defp fetch_oci_instances(opts) do
    with {:ok, compartment_id} <- require_oci_compartment_id(opts),
         {:ok, instances} <- oci_list_instances(compartment_id, opts) do
      instances
      |> Enum.filter(&oci_project_scoped?/1)
      |> oci_hydrate_instances(opts, [])
    end
  end

  defp require_oci_compartment_id(opts) do
    case oci_setting(opts, :compartment_id) do
      nil ->
        {:error,
         ErrorMessage.bad_request(
           "oci compartment_id is required to build the static inventory " <>
             "(config :deploy_ex, :oci, compartment_id: \"...\", or --oci-compartment-id)"
         )}

      compartment_id ->
        {:ok, compartment_id}
    end
  end

  # Required like compartment_id: unlike the release bucket (a name deploy_ex can default),
  # the Object Storage namespace is a tenancy-assigned identifier with no sensible guess, so
  # a missing value fails validate_provider_opts/2 up front rather than surfacing later as a
  # broken group_vars render or a confusing oci CLI error on the node.
  defp require_oci_namespace(opts) do
    case oci_setting(opts, :namespace) do
      nil ->
        {:error,
         ErrorMessage.bad_request(
           "oci namespace is required for the oci provider " <>
             "(config :deploy_ex, :oci, namespace: \"...\", or --oci-namespace)"
         )}

      namespace ->
        {:ok, namespace}
    end
  end

  defp oci_setting(opts, key), do: opts[:"oci_#{key}"] || oci_config_setting(key)

  defp oci_config_setting(key), do: :deploy_ex |> Application.get_env(:oci, []) |> Keyword.get(key)

  defp oci_release_bucket(opts) do
    oci_setting(opts, :release_bucket) ||
      "#{DeployExHelpers.kebab_project_name()}-elixir-deploys-#{Config.env()}"
  end

  defp oci_project_scoped?(instance) do
    expected_group = "#{DeployEx.Utils.upper_title_case(DeployExHelpers.underscored_project_name())} Backend"

    get_in(instance, ["freeform-tags", "Group"]) === expected_group
  end

  defp oci_list_instances(compartment_id, opts) do
    command =
      oci_command(opts, "compute instance list --compartment-id #{compartment_id} --lifecycle-state RUNNING --output json")

    with {:ok, output} <- DeployEx.Utils.run_command_with_return(command, File.cwd!()),
         {:ok, decoded} <- oci_decode_json(output) do
      {:ok, decoded["data"] || []}
    end
  end

  defp oci_hydrate_instances([], _opts, acc), do: {:ok, Enum.reverse(acc)}

  defp oci_hydrate_instances([instance | rest], opts, acc) do
    case oci_hydrate_instance(instance, opts) do
      {:ok, hydrated} -> oci_hydrate_instances(rest, opts, [hydrated | acc])
      {:error, _} = error -> error
    end
  end

  defp oci_hydrate_instance(instance, opts) do
    command = oci_command(opts, "compute instance list-vnics --instance-id #{instance["id"]} --output json")

    with {:ok, output} <- DeployEx.Utils.run_command_with_return(command, File.cwd!()),
         {:ok, decoded} <- oci_decode_json(output) do
      case oci_primary_vnic(decoded["data"] || []) do
        nil -> {:error, ErrorMessage.not_found("no vnic found for oci instance #{instance["id"]}")}
        vnic -> {:ok, oci_instance_from_vnic(instance, vnic)}
      end
    end
  end

  defp oci_primary_vnic(vnics), do: Enum.find(vnics, & &1["is-primary"]) || List.first(vnics)

  defp oci_instance_from_vnic(instance, vnic) do
    tags = instance["freeform-tags"] || %{}

    %{
      id: instance["id"],
      name: tags["Name"] || instance["display-name"],
      tags: tags,
      public_ip: vnic["public-ip"],
      private_ip: vnic["private-ip"],
      ipv6: vnic |> Map.get("ipv6-addresses") |> List.wrap() |> List.first()
    }
  end

  # OCI_CLI_AUTH=api_key is the non-interactive auth mode deploy_ex automation needs
  # (session-token auth requires a browser). SUPPRESS_LABEL_WARNING avoids a stderr nag
  # about unlabeled API keys, which would otherwise land in the merged stdout/stderr stream
  # DeployEx.Utils.run_command_with_return/3 returns and break JSON decoding.
  defp oci_command(opts, subcommand) do
    flags =
      [oci_flag("--profile", oci_setting(opts, :profile)), oci_flag("--region", oci_setting(opts, :region))]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    String.trim("OCI_CLI_AUTH=api_key SUPPRESS_LABEL_WARNING=True oci #{subcommand} #{flags}")
  end

  defp oci_flag(_flag, nil), do: nil
  defp oci_flag(flag, value), do: "#{flag} #{value}"

  # The oci CLI prints NOTHING — not `{"data": []}` — when a list matches no resources, so an
  # empty compartment has to decode to an empty result rather than a JSON error. Without this a
  # project with no instances yet cannot build an inventory at all: it fails with "unexpected
  # end of input" instead of producing an empty one, which is the normal first-run state.
  defp oci_decode_json(output) do
    case String.trim(output) do
      "" -> {:ok, %{"data" => []}}
      trimmed -> decode_oci_payload(trimmed, output)
    end
  end

  defp decode_oci_payload(trimmed, original) do
    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, decode_error} ->
        {:error,
         ErrorMessage.internal_server_error(
           "failed to decode oci CLI JSON output: #{Exception.message(decode_error)}",
           %{output: original}
         )}
    end
  end

  @doc false
  # Pure transform from hydrated OCI instances to inventory host entries — kept separate
  # from fetch_oci_instances/1 so the group/hostvar composition contract is unit-testable
  # without a live oci CLI or network access.
  def oci_inventory_hosts(instances) do
    Enum.map(instances, &oci_inventory_host/1)
  end

  defp oci_inventory_host(%{id: id, name: name, tags: tags} = instance) do
    qa_node? = Map.get(tags, "QaNode") === "true"

    %{
      hostname: "#{id}-#{name}",
      groups: oci_keyed_groups(tags),
      vars: %{
        ansible_host: instance[:ipv6] || instance[:public_ip] || instance[:private_ip],
        release_prefix: if(qa_node?, do: "qa", else: ""),
        release_state_prefix: if(qa_node?, do: "release-state/qa", else: "release-state"),
        git_branch: Map.get(tags, "GitBranch", ""),
        qa_node: qa_node?,
        qa_node_suffix: if(qa_node?, do: "_qa", else: ""),
        instance_tag: Map.get(tags, "InstanceTag", ""),
        letsencrypt_use_public_ip: Map.get(tags, "UsePublicIpCert") === "true"
      }
    }
  end

  defp oci_keyed_groups(tags) do
    @oci_keyed_group_tags
    |> Enum.map(fn {tag_key, prefix} -> {prefix, Map.get(tags, tag_key)} end)
    |> Enum.reject(fn {_prefix, value} -> value in [nil, ""] end)
    |> Enum.map(fn {prefix, value} -> "#{prefix}_#{value}" end)
  end

  @doc false
  def render_oci_hosts_section(hosts) do
    if Enum.empty?(hosts) do
      "  hosts: {}"
    else
      "  hosts:\n" <> Enum.map_join(hosts, "\n", &render_oci_host_entry/1)
    end
  end

  defp render_oci_host_entry(%{hostname: hostname, vars: vars}) do
    var_lines = Enum.map_join(vars, "\n", fn {key, value} -> "      #{key}: #{oci_yaml_scalar(value)}" end)

    "    #{hostname}:\n#{var_lines}"
  end

  @doc false
  def render_oci_children_section(hosts) do
    groups =
      hosts
      |> Enum.flat_map(fn %{hostname: hostname, groups: groups} -> Enum.map(groups, &{&1, hostname}) end)
      |> Enum.group_by(fn {group, _hostname} -> group end, fn {_group, hostname} -> hostname end)

    if Enum.empty?(groups) do
      "  children: {}"
    else
      "  children:\n" <> Enum.map_join(groups, "\n", &render_oci_group_entry/1)
    end
  end

  defp render_oci_group_entry({group, hostnames}) do
    host_lines = Enum.map_join(hostnames, "\n", &"        #{&1}: {}")

    "    #{group}:\n      hosts:\n#{host_lines}"
  end

  defp oci_yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp oci_yaml_scalar(value), do: inspect(to_string(value))
end
