defmodule DeployEx.Cloud.OciMachine do
  @moduledoc """
  OCI compute instance discovery and lifecycle, and the OCI implementation of
  `DeployEx.Cloud.Machine`. Everything goes through `DeployEx.Cloud.OciCli` — no OCI SDK
  exists for Elixir/Erlang, see `OciCli`'s moduledoc.

  Tag filtering is entirely client-side (`oci compute instance list` has no reliable
  server-side freeform-tag query across CLI versions), matching `AwsMachine`'s Regex-matcher
  handling: filter after listing, never push a Regex into the CLI call.

  `run_instance/2` and `terminate_instance/2` are optional callbacks (only a provider whose
  lifecycle needs an ad-hoc launch implements them); `find_app_instances/3`, `start_instance/2`
  and `stop_instance/2` are REQUIRED by `DeployEx.Cloud.Machine` but not used by the loadtest
  path this sprint — honest `:not_implemented` stubs rather than either raising or inventing
  untested behavior no caller has asked for.
  """

  @behaviour DeployEx.Cloud.Machine

  alias DeployEx.Cloud.Instance
  alias DeployEx.Cloud.OciCli

  @default_shape "VM.Standard.E5.Flex"
  @default_shape_ocpus 1
  @default_shape_memory_gbs 8
  @await_running_retries 30
  @await_running_sleep_ms 10_000

  @impl DeployEx.Cloud.Machine
  def list_instances(tag_filters, opts \\ []) when is_list(tag_filters) do
    with {:ok, compartment_id} <- require_compartment_id(opts),
         {:ok, payload} <- OciCli.run_json("compute instance list --compartment-id #{quote_arg(compartment_id)} --all", opts) do
      instances =
        payload
        |> Map.get("data", [])
        |> Enum.filter(&matches_tag_filters?(&1, tag_filters))
        |> Enum.map(&instance_from_summary/1)

      {:ok, instances}
    end
  end

  @impl DeployEx.Cloud.Machine
  def find_app_instances(_project_name, _app_name, _opts \\ []) do
    not_implemented_error("find_app_instances/3")
  end

  @impl DeployEx.Cloud.Machine
  def describe_instance(instance_id, opts \\ []) do
    with {:ok, payload} <- OciCli.run_json("compute instance get --instance-id #{quote_arg(instance_id)}", opts),
         {:ok, addresses} <- primary_vnic_addresses(instance_id, opts) do
      {:ok, instance_from_summary(Map.get(payload, "data", %{}), addresses)}
    end
  end

  @impl DeployEx.Cloud.Machine
  def start_instance(_instance_id, _opts \\ []), do: not_implemented_error("start_instance/2")

  @impl DeployEx.Cloud.Machine
  def stop_instance(_instance_id, _opts \\ []), do: not_implemented_error("stop_instance/2")

  @impl DeployEx.Cloud.Machine
  def fetch_tags(instance_id, opts \\ []) do
    with {:ok, instance} <- describe_instance(instance_id, opts) do
      {:ok, instance.tags}
    end
  end

  @doc "Preferred reachable address for an instance. IPv6 wins when present."
  @impl DeployEx.Cloud.Machine
  def instance_address(%Instance{} = instance) do
    case instance.ipv6 || instance.public_ip do
      nil -> {:error, ErrorMessage.not_found("instance has no reachable address", %{id: instance.id})}
      address -> {:ok, address}
    end
  end

  @doc """
  Translates a provider-neutral run-instance spec into `oci compute instance launch`.

  Compartment, availability domain, subnet and image come from the `:oci` config namespace
  (`OciCli.setting/2`), not from `spec.network` — that sub-map is EC2-shaped
  (`ami_id`/`security_group_id`/`iam_instance_profile`), populated for AWS by
  `AwsInfrastructure.gather_infrastructure/1`; OCI's `gather_infrastructure/1` populates its
  own `subnet_id`/`image_id` keys instead, so `run_instance/2` resolves them directly from
  config rather than depending on a key name the AWS-shaped struct never carries. `spec.name`,
  `spec.instance_type`, `spec.user_data` and `spec.tags` ARE read from the spec — those are
  genuinely provider-neutral.
  """
  @impl DeployEx.Cloud.Machine
  def run_instance(spec, opts \\ []) do
    with {:ok, compartment_id} <- require_compartment_id(opts),
         {:ok, availability_domain} <- require_setting(opts, :availability_domain),
         {:ok, subnet_id} <- require_setting(opts, :subnet_id),
         {:ok, image_id} <- require_setting(opts, :base_image),
         {:ok, ssh_public_key} <- require_setting(opts, :ssh_public_key) do
      command =
        "compute instance launch " <>
          "--compartment-id #{quote_arg(compartment_id)} " <>
          "--availability-domain #{quote_arg(availability_domain)} " <>
          "--subnet-id #{quote_arg(subnet_id)} " <>
          "--image-id #{quote_arg(image_id)} " <>
          "--display-name #{quote_arg(spec.name)} " <>
          shape_flags(spec, opts) <>
          "--freeform-tags #{quote_arg(freeform_tags_json(spec.tags))} " <>
          "--metadata #{quote_arg(metadata_json(spec.user_data, ssh_public_key))} " <>
          "--assign-public-ip #{quote_arg("true")}"

      with {:ok, payload} <- OciCli.run_json(command, opts) do
        {:ok, %Instance{id: get_in(payload, ["data", "id"])}}
      end
    end
  end

  @doc "Implements the optional `DeployEx.Cloud.Machine.terminate_instance/2` callback."
  @impl DeployEx.Cloud.Machine
  def terminate_instance(instance_id, opts \\ []) do
    with {:ok, _output} <- OciCli.run("compute instance terminate --instance-id #{quote_arg(instance_id)} --force", opts) do
      :ok
    end
  end

  @doc """
  Blocks until every instance id reports RUNNING. Implements the optional
  `DeployEx.Cloud.Machine.await_running/2` callback.
  """
  @impl DeployEx.Cloud.Machine
  def await_running(instance_ids, opts \\ []) do
    retries = opts[:retries] || @await_running_retries
    sleep_fn = opts[:sleep_fn] || (&Process.sleep/1)

    do_await_running(instance_ids, opts, retries, sleep_fn)
  end

  defp do_await_running([], _opts, _retries, _sleep_fn) do
    {:error, ErrorMessage.bad_request("await_running requires at least one instance id")}
  end

  defp do_await_running(_instance_ids, _opts, 0, _sleep_fn) do
    {:error, ErrorMessage.failed_dependency("instance(s) did not report RUNNING before timeout")}
  end

  defp do_await_running(instance_ids, opts, retries, sleep_fn) do
    with {:ok, states} <- fetch_lifecycle_states(instance_ids, opts) do
      if Enum.all?(states, &(&1 === "RUNNING")) do
        :ok
      else
        sleep_fn.(@await_running_sleep_ms)
        do_await_running(instance_ids, opts, retries - 1, sleep_fn)
      end
    end
  end

  defp fetch_lifecycle_states(instance_ids, opts) do
    Enum.reduce_while(instance_ids, {:ok, []}, fn instance_id, {:ok, acc} ->
      case OciCli.run_json("compute instance get --instance-id #{quote_arg(instance_id)}", opts) do
        {:ok, payload} -> {:cont, {:ok, acc ++ [get_in(payload, ["data", "lifecycle-state"])]}}
        error -> {:halt, error}
      end
    end)
  end

  defp shape_flags(spec, opts) do
    shape = spec.instance_type || OciCli.setting(opts, :shape) || @default_shape
    base = "--shape #{quote_arg(shape)} "

    if String.ends_with?(shape, ".Flex") do
      ocpus = OciCli.setting(opts, :shape_ocpus) || @default_shape_ocpus
      memory_gbs = OciCli.setting(opts, :shape_memory_gbs) || @default_shape_memory_gbs
      shape_config = Jason.encode!(%{"ocpus" => ocpus, "memoryInGBs" => memory_gbs})

      base <> "--shape-config #{quote_arg(shape_config)} "
    else
      base
    end
  end

  defp freeform_tags_json(tags) do
    tags |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end) |> Jason.encode!()
  end

  # ssh_authorized_keys is what OCI's cloud-init uses to seed the default user's
  # ~/.ssh/authorized_keys — without it the instance boots keyless and every SSH step
  # (readiness gate, upload, exec) times out against an unreachable box.
  defp metadata_json(user_data, ssh_public_key) do
    Jason.encode!(%{
      "user_data" => Base.encode64(user_data),
      "ssh_authorized_keys" => ssh_public_key
    })
  end

  defp primary_vnic_addresses(instance_id, opts) do
    with {:ok, payload} <- OciCli.run_json("compute instance list-vnics --instance-id #{quote_arg(instance_id)}", opts) do
      vnic = payload |> Map.get("data", []) |> Enum.find(&(&1["is-primary"] === true)) || %{}

      {:ok, %{public_ip: vnic["public-ip"], private_ip: vnic["private-ip"], ipv6: nil}}
    end
  end

  defp instance_from_summary(summary, addresses \\ %{public_ip: nil, private_ip: nil, ipv6: nil}) do
    tags = Map.get(summary, "freeform-tags", %{})

    %Instance{
      id: summary["id"],
      type: nil,
      # Cloud.Instance :state contract is lowercase ("running"/"stopped"/"terminated" — what
      # AwsMachine emits and exec/list compare against); OCI reports "RUNNING" etc., so
      # normalize here in the adapter, never at call sites.
      state: normalize_state(summary["lifecycle-state"]),
      private_ip: addresses.private_ip,
      public_ip: addresses.public_ip,
      ipv6: addresses.ipv6,
      launched_at: summary["time-created"],
      name: summary["display-name"] || tags["Name"],
      qa_node?: tags["QaNode"] === "true",
      tags: tags
    }
  end

  defp matches_tag_filters?(_summary, []), do: true

  defp matches_tag_filters?(summary, tag_filters) do
    tags = Map.get(summary, "freeform-tags", %{})

    Enum.all?(tag_filters, fn {tag_name, matcher} -> matches_tag?(tags, tag_name, matcher) end)
  end

  defp matches_tag?(tags, tag_name, %Regex{} = regex) do
    value = tags[tag_name]
    not is_nil(value) and Regex.match?(regex, value)
  end

  defp matches_tag?(tags, tag_name, values) when is_list(values), do: tags[tag_name] in values
  defp matches_tag?(tags, tag_name, value), do: tags[tag_name] === value

  defp require_compartment_id(opts), do: require_setting(opts, :compartment_id)

  defp require_setting(opts, key) do
    case OciCli.setting(opts, key) do
      nil -> {:error, ErrorMessage.bad_request("oci #{key} is required (config :deploy_ex, :oci, #{key}: \"...\")", %{key: key})}
      value -> {:ok, value}
    end
  end

  defp not_implemented_error(callback) do
    {:error, ErrorMessage.not_implemented("DeployEx.Cloud.OciMachine.#{callback} is not implemented — not used by the loadtest path this sprint")}
  end

  defp normalize_state(nil), do: nil
  defp normalize_state(state), do: String.downcase(state)

  defp quote_arg(value), do: OciCli.quote_arg(value)
end
