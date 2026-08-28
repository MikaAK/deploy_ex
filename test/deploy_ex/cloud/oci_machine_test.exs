defmodule DeployEx.Cloud.OciMachineTest do
  @moduledoc """
  Behavioural tests for `DeployEx.Cloud.OciMachine` — LT-OCI S2. Every command goes through
  `DeployEx.Cloud.OciCli.run/run_json`'s `:run_fn` injection seam, so no test makes a live
  OCI call. Multi-key JSON payloads (freeform-tags, metadata) are decoded back out of the
  captured command string rather than asserted as a literal substring, since Elixir map
  iteration order is not a stable string to pin against.
  """

  use ExUnit.Case, async: true

  alias DeployEx.Cloud.Instance
  alias DeployEx.Cloud.OciMachine

  defp capture_command(response) do
    fn command, _cwd ->
      send(self(), {:oci_command, command})
      response
    end
  end

  defp flag_value(command, flag) do
    case Regex.run(~r/#{Regex.escape(flag)} '((?:[^'\\]|\\.)*)'/, command) do
      [_match, value] -> String.replace(value, "'\\''", "'")
      nil -> nil
    end
  end

  # Per-PID response queue for tests that need to return a different body on each successive
  # run_fn call (e.g. await_running's poll loop) — process-dict based, matches the
  # queue_responses/next_response pattern already used by k6_runner_test.exs's pagination
  # tests, no Agent/ETS needed.
  defp queue_responses(responses), do: Process.put(:oci_responses, responses)

  defp next_response do
    [head | rest] = Process.get(:oci_responses)
    Process.put(:oci_responses, rest)
    head
  end

  describe "list_instances/2" do
    defp instance_list_response(instances) do
      {:ok, Jason.encode!(%{"data" => instances})}
    end

    test "lists every instance in the compartment via oci compute instance list --all" do
      run_fn = capture_command(instance_list_response([]))

      assert {:ok, []} = OciMachine.list_instances([], oci_compartment_id: "ocid1.compartment..a", run_fn: run_fn)

      assert_received {:oci_command, command}
      assert command =~ "oci compute instance list"
      assert flag_value(command, "--compartment-id") === "ocid1.compartment..a"
      assert command =~ "--all"
    end

    test "requires compartment_id instead of listing the wrong compartment" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} = OciMachine.list_instances([], [])
      assert message =~ "compartment_id"
    end

    test "filters client-side by exact tag match" do
      matching = %{
        "id" => "ocid1.instance..match",
        "display-name" => "K6-Runner-1",
        "lifecycle-state" => "RUNNING",
        "freeform-tags" => %{"K6Runner" => "true"},
        "time-created" => "2024-01-15T10:30:00.000Z"
      }

      not_matching = %{
        "id" => "ocid1.instance..other",
        "display-name" => "Other",
        "lifecycle-state" => "RUNNING",
        "freeform-tags" => %{"K6Runner" => "false"},
        "time-created" => "2024-01-15T10:30:00.000Z"
      }

      run_fn = capture_command(instance_list_response([matching, not_matching]))

      assert {:ok, [%Instance{id: "ocid1.instance..match"}]} =
               OciMachine.list_instances([{"K6Runner", "true"}], oci_compartment_id: "ocid1.compartment..a", run_fn: run_fn)
    end

    test "filters client-side by a list-of-scalars matcher (any-of)" do
      instances = [
        %{"id" => "i-1", "freeform-tags" => %{"Group" => "a"}, "lifecycle-state" => "RUNNING"},
        %{"id" => "i-2", "freeform-tags" => %{"Group" => "b"}, "lifecycle-state" => "RUNNING"},
        %{"id" => "i-3", "freeform-tags" => %{"Group" => "c"}, "lifecycle-state" => "RUNNING"}
      ]

      run_fn = capture_command(instance_list_response(instances))

      assert {:ok, matched} =
               OciMachine.list_instances([{"Group", ["a", "b"]}], oci_compartment_id: "c", run_fn: run_fn)

      assert Enum.map(matched, & &1.id) |> Enum.sort() === ["i-1", "i-2"]
    end

    test "filters client-side by a Regex matcher" do
      instances = [
        %{"id" => "i-1", "freeform-tags" => %{"Name" => "K6-Runner-prod-1"}, "lifecycle-state" => "RUNNING"},
        %{"id" => "i-2", "freeform-tags" => %{"Name" => "Other-node"}, "lifecycle-state" => "RUNNING"}
      ]

      run_fn = capture_command(instance_list_response(instances))

      assert {:ok, [%Instance{id: "i-1"}]} =
               OciMachine.list_instances([{"Name", ~r/^K6-Runner/}], oci_compartment_id: "c", run_fn: run_fn)
    end

    test "an instance missing the filtered tag entirely does not match" do
      instances = [%{"id" => "i-1", "freeform-tags" => %{}, "lifecycle-state" => "RUNNING"}]
      run_fn = capture_command(instance_list_response(instances))

      assert {:ok, []} = OciMachine.list_instances([{"K6Runner", "true"}], oci_compartment_id: "c", run_fn: run_fn)
    end

    test "an empty response (oci CLI prints nothing for zero matches) decodes to an empty list, not an error" do
      run_fn = capture_command({:ok, ""})

      assert {:ok, []} = OciMachine.list_instances([], oci_compartment_id: "c", run_fn: run_fn)
    end
  end

  describe "describe_instance/2 + fetch_tags/2 + instance_address/1" do
    defp instance_get_response(instance) do
      {:ok, Jason.encode!(%{"data" => instance})}
    end

    defp vnic_list_response(vnics) do
      {:ok, Jason.encode!(%{"data" => vnics})}
    end

    test "combines instance get + list-vnics into a normalized Instance" do
      run_fn = fn command, _cwd ->
        cond do
          command =~ "instance get" ->
            instance_get_response(%{
              "id" => "ocid1.instance..a",
              "display-name" => "K6-Runner-prod-1",
              "lifecycle-state" => "RUNNING",
              "freeform-tags" => %{"Name" => "K6-Runner-prod-1", "K6Runner" => "true"},
              "time-created" => "2024-01-15T10:30:00.000Z"
            })

          command =~ "list-vnics" ->
            vnic_list_response([%{"public-ip" => "1.2.3.4", "private-ip" => "10.0.0.5", "is-primary" => true}])
        end
      end

      assert {:ok,
              %Instance{
                id: "ocid1.instance..a",
                name: "K6-Runner-prod-1",
                state: "RUNNING",
                public_ip: "1.2.3.4",
                private_ip: "10.0.0.5",
                tags: %{"Name" => "K6-Runner-prod-1", "K6Runner" => "true"}
              }} = OciMachine.describe_instance("ocid1.instance..a", run_fn: run_fn)
    end

    test "an instance with no vnic (still provisioning) has nil addresses, not a crash" do
      run_fn = fn command, _cwd ->
        cond do
          command =~ "instance get" ->
            instance_get_response(%{
              "id" => "ocid1.instance..a",
              "display-name" => "n",
              "lifecycle-state" => "PROVISIONING",
              "freeform-tags" => %{},
              "time-created" => "2024-01-15T10:30:00.000Z"
            })

          command =~ "list-vnics" ->
            vnic_list_response([])
        end
      end

      assert {:ok, %Instance{public_ip: nil, private_ip: nil}} =
               OciMachine.describe_instance("ocid1.instance..a", run_fn: run_fn)
    end

    test "fetch_tags/2 returns the instance's freeform-tags via describe_instance" do
      run_fn = fn command, _cwd ->
        cond do
          command =~ "instance get" ->
            instance_get_response(%{
              "id" => "ocid1.instance..a",
              "display-name" => "n",
              "lifecycle-state" => "RUNNING",
              "freeform-tags" => %{"K6Runner" => "true"},
              "time-created" => "2024-01-15T10:30:00.000Z"
            })

          command =~ "list-vnics" ->
            vnic_list_response([])
        end
      end

      assert {:ok, %{"K6Runner" => "true"}} = OciMachine.fetch_tags("ocid1.instance..a", run_fn: run_fn)
    end

    test "instance_address/1 prefers ipv6, falls back to public_ip" do
      assert {:ok, "2600:1f18::1"} =
               OciMachine.instance_address(%Instance{ipv6: "2600:1f18::1", public_ip: "1.2.3.4"})

      assert {:ok, "1.2.3.4"} = OciMachine.instance_address(%Instance{ipv6: nil, public_ip: "1.2.3.4"})
    end

    test "instance_address/1 errors when neither address is reachable" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               OciMachine.instance_address(%Instance{id: "ocid1.instance..a", ipv6: nil, public_ip: nil})
    end
  end

  describe "run_instance/2 — neutral spec to oci compute instance launch" do
    defp neutral_spec do
      %{
        name: "K6-Runner-test-1",
        instance_type: nil,
        user_data: "#!/bin/bash\necho hi\n",
        tags: [{:Name, "K6-Runner-test-1"}, {:Group, "My Backend"}, {:K6Runner, "true"}],
        network: %{
          key_name: "/tmp/key.pem",
          subnet_id: nil,
          security_group_id: nil,
          ami_id: nil,
          iam_instance_profile: nil
        }
      }
    end

    defp launch_response(instance_id) do
      {:ok, Jason.encode!(%{"data" => %{"id" => instance_id, "lifecycle-state" => "PROVISIONING"}})}
    end

    defp launch_opts(extra \\ []) do
      Keyword.merge(
        [
          oci_compartment_id: "ocid1.compartment..a",
          oci_availability_domain: "abcd:AP-SEOUL-1-AD-1",
          oci_subnet_id: "ocid1.subnet..a",
          oci_base_image: "ocid1.image..a"
        ],
        extra
      )
    end

    test "launches with compartment/AD/subnet/image from config, display-name and metadata.user_data from the spec" do
      run_fn = capture_command(launch_response("ocid1.instance..new"))

      assert {:ok, %Instance{id: "ocid1.instance..new"}} =
               OciMachine.run_instance(neutral_spec(), Keyword.put(launch_opts(), :run_fn, run_fn))

      assert_received {:oci_command, command}
      assert command =~ "oci compute instance launch"
      assert flag_value(command, "--compartment-id") === "ocid1.compartment..a"
      assert flag_value(command, "--availability-domain") === "abcd:AP-SEOUL-1-AD-1"
      assert flag_value(command, "--subnet-id") === "ocid1.subnet..a"
      assert flag_value(command, "--image-id") === "ocid1.image..a"
      assert flag_value(command, "--display-name") === "K6-Runner-test-1"
      assert flag_value(command, "--assign-public-ip") === "true"

      metadata = command |> flag_value("--metadata") |> Jason.decode!()
      assert metadata === %{"user_data" => Base.encode64(neutral_spec().user_data)}

      tags = command |> flag_value("--freeform-tags") |> Jason.decode!()
      assert tags === %{"Name" => "K6-Runner-test-1", "Group" => "My Backend", "K6Runner" => "true"}
    end

    test "nil instance_type falls back to the configured shape, not a hardcoded AWS-shaped default" do
      run_fn = capture_command(launch_response("ocid1.instance..new"))

      OciMachine.run_instance(
        neutral_spec(),
        Keyword.merge(launch_opts(oci_shape: "VM.Standard.E5.Flex"), run_fn: run_fn)
      )

      assert_received {:oci_command, command}
      assert flag_value(command, "--shape") === "VM.Standard.E5.Flex"
    end

    test "no configured shape falls back to a sane default, never AWS's t3.small" do
      run_fn = capture_command(launch_response("ocid1.instance..new"))

      OciMachine.run_instance(neutral_spec(), Keyword.put(launch_opts(), :run_fn, run_fn))

      assert_received {:oci_command, command}
      shape = flag_value(command, "--shape")
      refute is_nil(shape)
      refute shape === "t3.small"
    end

    test "an explicit spec instance_type overrides the configured shape" do
      run_fn = capture_command(launch_response("ocid1.instance..new"))
      spec = %{neutral_spec() | instance_type: "VM.Standard.E6.Flex"}

      OciMachine.run_instance(spec, Keyword.merge(launch_opts(oci_shape: "VM.Standard.E5.Flex"), run_fn: run_fn))

      assert_received {:oci_command, command}
      assert flag_value(command, "--shape") === "VM.Standard.E6.Flex"
    end

    test "a Flex shape includes --shape-config with ocpus/memory; a fixed shape omits it" do
      run_fn = capture_command(launch_response("ocid1.instance..new"))

      OciMachine.run_instance(
        neutral_spec(),
        Keyword.merge(launch_opts(oci_shape: "VM.Standard.E5.Flex", oci_shape_ocpus: 2, oci_shape_memory_gbs: 16),
          run_fn: run_fn
        )
      )

      assert_received {:oci_command, flex_command}
      shape_config = flex_command |> flag_value("--shape-config") |> Jason.decode!()
      assert shape_config === %{"ocpus" => 2, "memoryInGBs" => 16}

      run_fn2 = capture_command(launch_response("ocid1.instance..new2"))

      OciMachine.run_instance(
        neutral_spec(),
        Keyword.merge(launch_opts(oci_shape: "VM.Standard2.1"), run_fn: run_fn2)
      )

      assert_received {:oci_command, fixed_command}
      refute fixed_command =~ "--shape-config"
    end

    test "requires compartment_id and availability_domain instead of launching with nils" do
      run_fn = capture_command(launch_response("unreachable"))

      assert {:error, %ErrorMessage{code: :bad_request, message: message}} =
               OciMachine.run_instance(neutral_spec(),
                 oci_availability_domain: "abcd:AP-SEOUL-1-AD-1",
                 oci_subnet_id: "s",
                 oci_base_image: "i",
                 run_fn: run_fn
               )

      assert message =~ "compartment_id"
    end
  end

  describe "terminate_instance/2" do
    test "terminates via oci compute instance terminate --force" do
      run_fn = capture_command({:ok, ""})

      assert :ok = OciMachine.terminate_instance("ocid1.instance..a", run_fn: run_fn)

      assert_received {:oci_command, command}
      assert command =~ "oci compute instance terminate"
      assert flag_value(command, "--instance-id") === "ocid1.instance..a"
      assert command =~ "--force"
    end
  end

  describe "await_running/2" do
    test "returns :ok once every instance reports RUNNING" do
      run_fn = fn _command, _cwd ->
        {:ok, Jason.encode!(%{"data" => %{"lifecycle-state" => "RUNNING"}})}
      end

      assert :ok = OciMachine.await_running(["ocid1.instance..a"], run_fn: run_fn)
    end

    test "polls until RUNNING, sleeping between attempts" do
      queue_responses([
        Jason.encode!(%{"data" => %{"lifecycle-state" => "PROVISIONING"}}),
        Jason.encode!(%{"data" => %{"lifecycle-state" => "RUNNING"}})
      ])

      run_fn = fn _command, _cwd -> {:ok, next_response()} end
      sleep_fn = fn _ms -> send(self(), :slept) end

      assert :ok = OciMachine.await_running(["ocid1.instance..a"], run_fn: run_fn, sleep_fn: sleep_fn, retries: 3)
      assert_received :slept
    end

    test "exhausts retries and returns a failed_dependency error rather than a false :ok" do
      run_fn = fn _command, _cwd ->
        {:ok, Jason.encode!(%{"data" => %{"lifecycle-state" => "PROVISIONING"}})}
      end

      sleep_fn = fn _ms -> :ok end

      assert {:error, %ErrorMessage{code: :failed_dependency}} =
               OciMachine.await_running(["ocid1.instance..a"], run_fn: run_fn, sleep_fn: sleep_fn, retries: 2)
    end
  end

  describe "behaviour conformance — required callbacks not requested by the loadtest path" do
    test "find_app_instances/3, start_instance/2, stop_instance/2 are honest not_implemented stubs" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               OciMachine.find_app_instances("project", "app", [])

      assert {:error, %ErrorMessage{code: :not_implemented}} = OciMachine.start_instance("i", [])
      assert {:error, %ErrorMessage{code: :not_implemented}} = OciMachine.stop_instance("i", [])
    end

    test "exports every REQUIRED callback the Machine behaviour declares" do
      Code.ensure_loaded!(OciMachine)

      required =
        DeployEx.Cloud.Machine.behaviour_info(:callbacks) --
          DeployEx.Cloud.Machine.behaviour_info(:optional_callbacks)

      missing = Enum.reject(required, fn {name, arity} -> function_exported?(OciMachine, name, arity) end)

      assert missing === [], "OciMachine is missing required callbacks: #{inspect(missing)}"
    end

    test "also implements the optional callbacks the loadtest path needs" do
      Code.ensure_loaded!(OciMachine)

      for {name, arity} <- [run_instance: 2, terminate_instance: 2, await_running: 2] do
        assert function_exported?(OciMachine, name, arity), "OciMachine is missing #{name}/#{arity}"
      end
    end
  end
end
