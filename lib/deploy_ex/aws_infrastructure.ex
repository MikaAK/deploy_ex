defmodule DeployEx.AwsInfrastructure do
  @moduledoc """
  Discover required infrastructure IDs directly from AWS APIs for QA node creation.

  This module follows the pattern established by `DeployEx.AwsSecurityGroup` which uses
  AWS APIs to find resources by naming conventions, avoiding terraform state dependency.

  Implements `DeployEx.Cloud.Infrastructure`. Those callbacks are neutral names over the
  AWS-specific functions below — here a network is a VPC, an identity is an IAM instance
  profile, and an image is an AMI.
  """

  @behaviour DeployEx.Cloud.Infrastructure

  @impl DeployEx.Cloud.Infrastructure
  def find_network(opts \\ []), do: find_vpc_id(opts)

  @impl DeployEx.Cloud.Infrastructure
  def find_subnet(opts \\ []) do
    with {:ok, subnet_ids} <- find_subnet_ids(opts) do
      case subnet_ids do
        [subnet_id | _rest] -> {:ok, subnet_id}
        [] -> {:error, ErrorMessage.not_found("no subnet found", %{opts: opts})}
      end
    end
  end

  @impl DeployEx.Cloud.Infrastructure
  def find_key_pair(project_name, opts \\ []) do
    find_key_pair_name(Keyword.put(opts, :project_name, project_name))
  end

  @impl DeployEx.Cloud.Infrastructure
  def find_image(opts \\ []), do: find_latest_ami(opts)

  @impl DeployEx.Cloud.Infrastructure
  def find_instance_identity(opts \\ []), do: find_iam_instance_profile(opts)

  def find_subnet_ids(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    vpc_id = opts[:vpc_id]
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    if is_nil(vpc_id) do
      {:error, ErrorMessage.bad_request("vpc_id is required to find subnets")}
    else
      with {:ok, items} <- fetch_subnets(vpc_id, region, request_fn) do
        case items do
          [] -> {:error, ErrorMessage.not_found("no subnets found in VPC '#{vpc_id}'")}
          items -> {:ok, items |> Enum.sort_by(& &1["availabilityZone"]) |> Enum.map(& &1["subnetId"])}
        end
      end
    end
  end

  # DescribeSubnets caps a response and signals more via nextToken. A single request silently
  # truncates on a VPC with many subnets — same failure mode AwsMachine.fetch_instances/2 guards
  # against for DescribeInstances.
  defp fetch_subnets(vpc_id, region, request_fn, next_token \\ nil, acc \\ []) do
    request_opts = maybe_put_next_token([filters: ["vpc-id": [vpc_id]]], next_token)

    response =
      request_opts
      |> ExAws.EC2.describe_subnets()
      |> request_fn.(region: region)

    case response do
      {:ok, %{body: body}} ->
        case XmlToMap.naive_map(body) do
          %{"DescribeSubnetsResponse" => envelope} ->
            accumulated = acc ++ extract_items(envelope["subnetSet"])

            case extract_next_token(envelope) do
              nil -> {:ok, accumulated}
              token -> fetch_subnets(vpc_id, region, request_fn, token, accumulated)
            end

          structure ->
            {:error, ErrorMessage.bad_request(
              "couldn't parse subnets response from aws",
              %{structure: structure}
            )}
        end

      {:error, {:http_error, status_code, %{body: body}}} ->
        {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
          "error fetching subnets from aws",
          %{error_body: body}
        ])}
    end
  end

  defp maybe_put_next_token(request_opts, nil), do: request_opts
  defp maybe_put_next_token(request_opts, next_token), do: Keyword.put(request_opts, :next_token, next_token)

  # AWS applies MaxResults to the underlying scan before any filters, so a small forced page
  # (or a naturally small final page) can filter down to zero items while still carrying a
  # nextToken — binding the whole envelope (not matching on the item set directly) means that
  # token is never missed just because a page happened to filter to empty.
  defp extract_items(nil), do: []
  defp extract_items(%{"item" => items}), do: List.wrap(items)

  defp extract_next_token(envelope) do
    case Map.get(envelope, "nextToken") do
      token when is_binary(token) and token !== "" -> token
      _absent -> nil
    end
  end

  def find_key_pair_name(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    project_name = opts[:project_name] || DeployEx.Config.aws_project_name()
    environment = DeployEx.Config.env()
    base_name = project_name |> String.replace("-#{environment}", "") |> String.replace("_#{environment}", "")
    key_pattern = ~r/^#{Regex.escape(base_name)}-.*key-pair/

    request_fn = opts[:request_fn] || (&ExAws.request/2)

    with {:ok, key_pairs} <- describe_key_pairs(region, request_fn) do
      matching = key_pairs
        |> Enum.filter(fn kp ->
          name = kp["keyName"] || ""
          Regex.match?(key_pattern, name)
        end)
        |> Enum.sort_by(& &1["keyName"], :desc)
        |> List.first()

      case matching do
        nil ->
          available = Enum.map(key_pairs, & &1["keyName"])
          {:error, ErrorMessage.not_found("no key pair found matching pattern #{inspect(key_pattern)}", %{available: available})}
        kp ->
          {:ok, kp["keyName"]}
      end
    end
  end

  # `:request_fn` is the same injection seam find_subnet_ids/1 and find_iam_instance_profile/1
  # already use. Without it this path can only be exercised against a live AWS account, which is
  # how its tests ended up calling the real API and failing based on what happened to exist
  # there.
  defp describe_key_pairs(region, request_fn) do
    ExAws.EC2.describe_key_pairs()
    |> request_fn.(region: region)
    |> handle_key_pairs_list_response()
  end

  def find_iam_instance_profile(opts \\ []) do
    case opts[:iam_instance_profile] || DeployEx.Config.aws_iam_instance_profile() do
      nil ->
        environment = DeployEx.Config.env()
        default_name = "deploy-ex-ec2-instance-profile-#{environment}"
        request_fn = opts[:request_fn] || (&ExAws.request/2)

        with {:ok, profiles} <- list_instance_profiles(request_fn) do
          if default_name in profiles do
            {:ok, default_name}
          else
            {:error, ErrorMessage.not_found(
              "IAM instance profile '#{default_name}' not found. " <>
              "Configure :aws_iam_instance_profile in deploy_ex config.",
              %{available: profiles}
            )}
          end
        end
      profile_name ->
        {:ok, profile_name}
    end
  end

  # ListInstanceProfiles caps a response and signals more via IsTruncated + Marker. ExAws
  # returns IsTruncated as the STRING "false", which is truthy in Elixir — branching on it
  # directly would loop forever, so this compares against known values instead.
  defp list_instance_profiles(request_fn, marker \\ nil, acc \\ []) do
    base_params = %{"Action" => "ListInstanceProfiles", "Version" => "2010-05-08"}
    params = if marker, do: Map.put(base_params, "Marker", marker), else: base_params

    response =
      %ExAws.Operation.Query{
        path: "/",
        params: params,
        service: :iam,
        action: :list_instance_profiles
      }
      |> request_fn.([])

    case response do
      {:ok, %{body: body}} ->
        case XmlToMap.naive_map(body) do
          %{"ListInstanceProfilesResponse" => %{"ListInstanceProfilesResult" => result}} ->
            accumulated = acc ++ extract_instance_profile_names(result["InstanceProfiles"])

            if truncated?(result["IsTruncated"]) and present_marker?(result["Marker"]) do
              list_instance_profiles(request_fn, result["Marker"], accumulated)
            else
              {:ok, accumulated}
            end

          structure ->
            {:error, ErrorMessage.bad_request("couldn't parse instance profiles response", %{structure: structure})}
        end

      {:error, {:http_error, status_code, %{body: body}}} ->
        {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
          "error fetching IAM instance profiles",
          %{error_body: body}
        ])}
    end
  end

  defp extract_instance_profile_names(%{"member" => profiles}) when is_list(profiles) do
    Enum.map(profiles, & &1["InstanceProfileName"])
  end

  defp extract_instance_profile_names(%{"member" => profile}), do: [profile["InstanceProfileName"]]
  defp extract_instance_profile_names(nil), do: []

  defp truncated?(value), do: value in [true, "true"]

  defp present_marker?(marker), do: is_binary(marker) and marker !== ""

  def find_vpc_id(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    resource_group = opts[:resource_group] || DeployEx.Config.aws_resource_group()

    ExAws.EC2.describe_vpcs(filters: ["tag:Group": [resource_group]])
    |> ExAws.request(region: region)
    |> handle_vpcs_response()
  end

  def find_latest_ami(opts \\ []) do
    app_name = opts[:app_name]
    region = opts[:region] || DeployEx.Config.aws_region()
    environment = opts[:environment] || DeployEx.Config.env()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    case app_name && find_app_ami(app_name, environment, region, request_fn) do
      {:ok, ami_id} -> {:ok, ami_id}
      _ -> find_base_ami(region, request_fn)
    end
  end

  defp find_app_ami(app_name, environment, region, request_fn) do
    fetch_latest_ami(
      [
        owners: ["self"],
        filters: [
          "tag:App": [app_name],
          "tag:Environment": [to_string(environment)],
          "tag:ManagedBy": ["DeployEx"],
          state: ["available"]
        ]
      ],
      region,
      request_fn
    )
  end

  defp find_base_ami(region, request_fn) do
    base_ami_name = DeployEx.Config.aws_base_ami_name()
    architecture = DeployEx.Config.aws_base_ami_architecture()
    owner = DeployEx.Config.aws_base_ami_owner()

    fetch_latest_ami(
      [
        owners: [owner],
        filters: [
          name: ["#{base_ami_name}-*"],
          architecture: [architecture],
          "virtualization-type": ["hvm"]
        ]
      ],
      region,
      request_fn
    )
  end

  # DescribeImages caps its scan before tag/name filters are applied, so a small page can filter
  # to zero matches while still returning a token, and sorting "latest" over just that page can
  # pick a stale AMI believing it's current. Every page has to be in hand before creationDate
  # sorting means anything.
  defp fetch_latest_ami(request_opts, region, request_fn, next_token \\ nil, acc \\ []) do
    opts = maybe_put_next_token(request_opts, next_token)

    response =
      opts
      |> ExAws.EC2.describe_images()
      |> request_fn.(region: region)

    case response do
      {:ok, %{body: body}} ->
        case XmlToMap.naive_map(body) do
          %{"DescribeImagesResponse" => envelope} ->
            accumulated = acc ++ extract_items(envelope["imagesSet"])

            case extract_next_token(envelope) do
              nil -> latest_ami_result(accumulated)
              token -> fetch_latest_ami(request_opts, region, request_fn, token, accumulated)
            end

          structure ->
            {:error, ErrorMessage.bad_request(
              "couldn't parse images response from aws",
              %{structure: structure}
            )}
        end

      {:error, {:http_error, status_code, %{body: body}}} ->
        {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
          "error fetching AMIs from aws",
          %{error_body: body}
        ])}
    end
  end

  defp latest_ami_result([]), do: {:error, ErrorMessage.not_found("no debian-13 AMI found")}

  defp latest_ami_result(items) do
    latest = items |> Enum.sort_by(& &1["creationDate"], :desc) |> List.first()
    {:ok, latest["imageId"]}
  end

  @impl DeployEx.Cloud.Infrastructure
  def gather_infrastructure(opts \\ []) do
    with {:ok, security_group} <- DeployEx.AwsSecurityGroup.find_security_group(opts),
         {:ok, subnet_ids} <- find_subnet_ids(Keyword.put(opts, :vpc_id, security_group.vpc_id)),
         {:ok, key_pair_name} <- find_key_pair_name(opts),
         {:ok, iam_instance_profile} <- find_iam_instance_profile(opts),
         {:ok, ami_id} <- find_latest_ami(opts) do
      {:ok, %{
        security_group_id: security_group.id,
        vpc_id: security_group.vpc_id,
        subnet_id: primary_subnet_id(security_group.id, subnet_ids, opts),
        subnet_ids: subnet_ids,
        key_name: key_pair_name,
        iam_instance_profile: iam_instance_profile,
        ami_id: ami_id
      }}
    end
  end

  # A VPC can hold same-AZ public and private subnets, and describe_subnets alone
  # can't tell them apart without route-table lookups. Running instances on the
  # same security group are ground truth for a reachable subnet, so QA nodes
  # colocate with them; the AZ-sorted list is only a fallback for empty projects.
  defp primary_subnet_id(security_group_id, subnet_ids, opts) do
    case find_primary_subnet_id(security_group_id, opts) do
      {:ok, subnet_id} -> subnet_id
      {:error, _} -> List.first(subnet_ids)
    end
  end

  def find_primary_subnet_id(security_group_id, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    with {:ok, subnet_ids} <- fetch_primary_subnet_candidates(security_group_id, region, request_fn) do
      most_common_subnet_id(subnet_ids)
    end
  end

  # DescribeInstances caps a response and signals more via nextToken. A truncated ballot can
  # flip the winner in most_common_subnet_id/1 on a multi-AZ fleet — every page has to be
  # counted before "most common" means anything.
  defp fetch_primary_subnet_candidates(security_group_id, region, request_fn, next_token \\ nil, acc \\ []) do
    request_opts =
      maybe_put_next_token(
        [filters: ["instance.group-id": [security_group_id], "instance-state-name": ["running"]]],
        next_token
      )

    response =
      request_opts
      |> ExAws.EC2.describe_instances()
      |> request_fn.(region: region)

    case response do
      {:ok, %{body: body}} ->
        case XmlToMap.naive_map(body) do
          %{"DescribeInstancesResponse" => envelope} ->
            subnet_ids =
              envelope["reservationSet"]
              |> extract_items()
              |> Enum.flat_map(&extract_instance_subnet_ids/1)

            accumulated = acc ++ subnet_ids

            case extract_next_token(envelope) do
              nil -> {:ok, accumulated}
              token -> fetch_primary_subnet_candidates(security_group_id, region, request_fn, token, accumulated)
            end

          structure ->
            {:error, ErrorMessage.bad_request(
              "couldn't parse instances response from aws",
              %{structure: structure}
            )}
        end

      {:error, {:http_error, status_code, %{body: body}}} ->
        {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
          "error fetching instances from aws",
          %{error_body: body}
        ])}
    end
  end

  @doc false
  def parse_subnets_response(body, resource_group) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeSubnetsResponse" => %{"subnetSet" => %{"item" => items}}} when is_list(items) ->
        # AWS returns subnets in arbitrary order; sort by AZ so the fallback
        # List.first is deterministic. Placement normally comes from
        # find_primary_subnet_id/2 (colocate with running instances) since
        # same-AZ private subnets are indistinguishable here.
        {:ok, items |> Enum.sort_by(& &1["availabilityZone"]) |> Enum.map(& &1["subnetId"])}

      %{"DescribeSubnetsResponse" => %{"subnetSet" => %{"item" => item}}} ->
        {:ok, [item["subnetId"]]}

      %{"DescribeSubnetsResponse" => %{"subnetSet" => nil}} ->
        {:error, ErrorMessage.not_found("no subnets found in VPC '#{resource_group}'")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse subnets response from aws",
          %{structure: structure}
        )}
    end
  end

  @doc false
  def parse_primary_subnet_response(body) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:error, ErrorMessage.not_found("no running instances found to derive a subnet from")}

      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => reservations}}} ->
        reservations
        |> List.wrap()
        |> Enum.flat_map(&extract_instance_subnet_ids/1)
        |> most_common_subnet_id()

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse instances response from aws",
          %{structure: structure}
        )}
    end
  end

  defp extract_instance_subnet_ids(%{"instancesSet" => %{"item" => instances}}) do
    instances
    |> List.wrap()
    |> Enum.map(& &1["subnetId"])
    |> Enum.reject(&is_nil/1)
  end

  defp extract_instance_subnet_ids(_reservation), do: []

  defp most_common_subnet_id([]) do
    {:error, ErrorMessage.not_found("no subnet ids found on running instances")}
  end

  defp most_common_subnet_id(subnet_ids) do
    subnet_ids
    |> Enum.frequencies()
    |> Enum.max_by(fn {_subnet_id, count} -> count end)
    |> then(fn {subnet_id, _count} -> {:ok, subnet_id} end)
  end

  defp handle_key_pairs_list_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeKeyPairsResponse" => %{"keySet" => %{"item" => items}}} when is_list(items) ->
        {:ok, items}

      %{"DescribeKeyPairsResponse" => %{"keySet" => %{"item" => item}}} ->
        {:ok, [item]}

      %{"DescribeKeyPairsResponse" => %{"keySet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse key pairs response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_key_pairs_list_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching key pairs from aws",
      %{error_body: body}
    ])}
  end


  @doc false
  def parse_vpcs_response(body) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeVpcsResponse" => %{"vpcSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, List.first(items)["vpcId"]}

      %{"DescribeVpcsResponse" => %{"vpcSet" => %{"item" => item}}} ->
        {:ok, item["vpcId"]}

      %{"DescribeVpcsResponse" => %{"vpcSet" => nil}} ->
        {:error, ErrorMessage.not_found("no VPCs found with the resource group tag")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse VPCs response from aws",
          %{structure: structure}
        )}
    end
  end

  defp handle_vpcs_response({:ok, %{body: body}}), do: parse_vpcs_response(body)

  defp handle_vpcs_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching VPCs from aws",
      %{error_body: body}
    ])}
  end

  @doc false
  def parse_images_response(body) when is_binary(body) do
    case XmlToMap.naive_map(body) do
      %{"DescribeImagesResponse" => %{"imagesSet" => %{"item" => items}}} when is_list(items) ->
        latest = items
        |> Enum.sort_by(& &1["creationDate"], :desc)
        |> List.first()

        {:ok, latest["imageId"]}

      %{"DescribeImagesResponse" => %{"imagesSet" => %{"item" => item}}} ->
        {:ok, item["imageId"]}

      %{"DescribeImagesResponse" => %{"imagesSet" => nil}} ->
        {:error, ErrorMessage.not_found("no debian-13 AMI found")}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse images response from aws",
          %{structure: structure}
        )}
    end
  end

end
