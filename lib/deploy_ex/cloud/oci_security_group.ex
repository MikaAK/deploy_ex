defmodule DeployEx.Cloud.OciSecurityGroup do
  @moduledoc """
  OCI implementation of `DeployEx.Cloud.Security`, backed by a Network Security Group (NSG).

  ## NSG, not security list

  OCI has two candidates for "the thing `mix deploy_ex.ssh.authorize` opens a hole in": Network
  Security Groups, which attach to a VNIC, and security lists, which attach to a SUBNET.
  `priv/terraform/providers/oci/network.tf` already creates a security list for the subnet's
  baseline rules (open egress, an optional static SSH CIDR) — this module does not touch it.

  NSG was chosen for one decisive reason: the `oci network nsg rules` API is additive.
  `add`/`remove` operate on individual rules by content or by ID; nothing in this module ever
  reads the full rule set and writes it back. A security list has no such API —
  `oci network security-list update --security-rules` REPLACES the entire list, so an ingress
  toggle implemented against a security list has to read-merge-write the whole set on every
  call, and a bug there silently deletes every rule terraform created. NSGs make that bug class
  unreachable by construction.

  Blast radius, measured, is a wash in THIS codebase specifically — it is not the deciding
  factor. `priv/terraform/providers/oci/modules/oci-instance` attaches the same `nsg_ids` list
  to every instance's VNIC, the same way the security list already applies to every instance via
  the one shared subnet. A real per-instance NSG assignment would narrow the grant below what
  the security list allows; that is not how it is wired up today. If per-instance isolation is
  wanted later, only the terraform wiring in `instance.tf.eex` needs to change — this module
  already operates on whatever NSG id `find_group/1` resolves, one call site, not fanned out per
  instance.

  ## Idempotency, measured

  MEASURED against a live tenancy: `oci network nsg rules add` is idempotent for identical
  `(direction, protocol, source, port)` content — adding the same rule twice returns the SAME
  rule id both times and the NSG ends up with one rule, not two, regardless of a differing
  `description`. AWS's `authorize_ingress` instead gets a hard "already exists" error back from
  EC2 that `AwsSecurityGroup.classify_ingress_error/3` turns into a conflict.
  `authorize_ingress/3` here does NOT reimplement that check — doing so would fight OCI's native
  idempotency for no benefit, and an idempotent authorize is what a retried
  `mix deploy_ex.ssh.authorize` (or a re-run CI job) actually wants.

  `remove` has no content-addressed form — it deletes by rule ID, and removing an ID that no
  longer exists is a 400. `revoke_ingress/3` reads the rule list first so it never calls
  `remove` with a stale ID; a CIDR with no matching rule is a no-op `:ok`, not an error.
  """

  @behaviour DeployEx.Cloud.Security

  alias DeployEx.Cloud.OciCli

  @ssh_port 22
  @tcp_protocol "6"

  @impl DeployEx.Cloud.Security
  def find_group(opts \\ []), do: find_nsg_id(opts)

  @impl DeployEx.Cloud.Security
  def authorize_ingress(nsg_id, cidr, opts \\ []) do
    command = add_rule_command(nsg_id, cidr)

    with {:ok, _output} <- OciCli.run(command, opts), do: :ok
  end

  @impl DeployEx.Cloud.Security
  def revoke_ingress(nsg_id, cidr, opts \\ []) do
    with {:ok, rules} <- list_ingress_rules(nsg_id, opts) do
      case Enum.find(rules, &matches_cidr?(&1, cidr)) do
        nil -> :ok
        rule -> remove_rule(nsg_id, rule["id"], opts)
      end
    end
  end

  defp add_rule_command(nsg_id, cidr) do
    rule_json = Jason.encode!([ingress_rule(cidr)])

    "network nsg rules add --nsg-id #{quote_arg(nsg_id)} --security-rules #{quote_arg(rule_json)}"
  end

  defp ingress_rule(cidr) do
    %{
      direction: "INGRESS",
      protocol: @tcp_protocol,
      source: cidr,
      sourceType: "CIDR_BLOCK",
      isStateless: false,
      tcpOptions: %{destinationPortRange: %{min: @ssh_port, max: @ssh_port}}
    }
  end

  defp remove_rule(nsg_id, rule_id, opts) do
    ids_json = Jason.encode!([rule_id])

    command = "network nsg rules remove --nsg-id #{quote_arg(nsg_id)} --security-rule-ids #{quote_arg(ids_json)}"

    with {:ok, _output} <- OciCli.run(command, opts), do: :ok
  end

  defp list_ingress_rules(nsg_id, opts) do
    command = "network nsg rules list --nsg-id #{quote_arg(nsg_id)} --direction INGRESS --all"

    with {:ok, payload} <- OciCli.run_json(command, opts) do
      {:ok, Map.get(payload, "data", [])}
    end
  end

  defp matches_cidr?(rule, cidr) do
    rule["protocol"] === @tcp_protocol and rule["source"] === cidr and
      rule["source-type"] === "CIDR_BLOCK" and ssh_port?(rule["tcp-options"])
  end

  defp ssh_port?(%{"destination-port-range" => %{"min" => @ssh_port, "max" => @ssh_port}}), do: true
  defp ssh_port?(_no_tcp_options), do: false

  defp find_nsg_id(opts) do
    case opts[:security_group_id] do
      nil -> find_nsg_by_prefix(opts)
      nsg_id -> verify_nsg_exists(nsg_id, opts)
    end
  end

  # An explicit override is checked against a live `get` rather than trusted as-is, so a stale
  # or mistyped id fails here with a clear not_found instead of confusing every ingress call
  # that follows.
  defp verify_nsg_exists(nsg_id, opts) do
    with {:ok, _payload} <- OciCli.run_json("network nsg get --nsg-id #{quote_arg(nsg_id)}", opts) do
      {:ok, nsg_id}
    end
  end

  defp find_nsg_by_prefix(opts) do
    with {:ok, compartment_id} <- require_compartment_id(opts),
         {:ok, nsgs} <- list_nsgs(compartment_id, opts) do
      prefix = nsg_prefix(opts)

      case matching_nsg(nsgs, prefix) do
        nil -> {:error, no_nsg_match_error(nsgs, prefix)}
        nsg -> {:ok, nsg["id"]}
      end
    end
  end

  defp no_nsg_match_error(nsgs, prefix) do
    available = nsgs |> Enum.map(& &1["display-name"]) |> Enum.filter(& &1)

    ErrorMessage.not_found("no network security group found matching prefix #{prefix}", %{
      available: available
    })
  end

  defp matching_nsg(nsgs, prefix) do
    nsgs
    |> Enum.filter(fn nsg -> matches_prefix?(nsg["display-name"] || "", prefix) end)
    |> Enum.sort_by(& &1["display-name"], :desc)
    |> List.first()
  end

  defp matches_prefix?(name, prefix), do: name === prefix or String.starts_with?(name, prefix)

  defp list_nsgs(compartment_id, opts) do
    command = "network nsg list --compartment-id #{quote_arg(compartment_id)} --all"

    with {:ok, payload} <- OciCli.run_json(command, opts) do
      {:ok, Map.get(payload, "data", [])}
    end
  end

  defp nsg_prefix(opts) do
    project_name = opts[:project_name] || DeployExHelpers.kebab_project_name()
    environment = opts[:environment] || DeployEx.Config.env()

    "#{project_name}-#{environment}-nsg"
  end

  defp require_compartment_id(opts) do
    case OciCli.setting(opts, :compartment_id) do
      nil -> {:error, missing_compartment_id_error()}
      compartment_id -> {:ok, compartment_id}
    end
  end

  defp missing_compartment_id_error do
    ErrorMessage.bad_request(
      "oci compartment_id is required for security group operations " <>
        "(config :deploy_ex, :oci, compartment_id: \"...\")"
    )
  end

  defp quote_arg(value), do: OciCli.quote_arg(value)
end
