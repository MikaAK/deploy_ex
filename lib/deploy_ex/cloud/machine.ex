defmodule DeployEx.Cloud.Machine do
  @moduledoc """
  Compute instance discovery and lifecycle.

  Tag filters are a LIST of `{key, matcher}` pairs, never a map. A map would collapse
  repeated keys and turn today's AND semantics on `--tag Env=a --tag Env=b` into
  "last one wins".

  A matcher is a scalar, a list of scalars, or a `Regex`. Only exact scalar and list
  matchers may be pushed down into a provider-native query; a regex is evaluated
  client-side against the decoded canonical tag map. Callers rely on the regex arm today
  because autoscaling-group instances carry composite tag values.
  """

  alias DeployEx.Cloud.Instance

  @typedoc "A single tag value to match against"
  @type scalar :: String.t() | boolean() | number()

  @typedoc "Exact scalar, any-of list, or a client-side evaluated pattern"
  @type matcher :: scalar() | [scalar()] | Regex.t()

  @typedoc "Canonical tag filters, AND-ed together"
  @type tag_filters :: [{String.t(), matcher()}]

  @doc """
  Raw tag-filter lookup returning normalized instances.

  Named `list_instances` rather than `find_instances_by_tags` on purpose: `AwsMachine` already
  exports a function by the latter name that returns provider-shaped maps to seven Mix-task
  call sites, and those keep their shape until the caller sweep rewires them. Two different
  return types must not share one name.
  """
  @callback list_instances(tag_filters(), keyword()) ::
              {:ok, [Instance.t()]} | {:error, ErrorMessage.t()}

  @doc """
  Instances belonging to one app within one project.

  This is the caller-facing lookup behind `deploy_ex.ssh`, `restart_app` and the EBS tasks.
  Three clauses are part of the CONTRACT, not incidental to the AWS implementation — an
  implementation that drops any of them is non-conforming:

    1. **Project scope is unconditional.** Results are restricted to the active project's
       resource group. It is never caller-supplied and never optional; omitting it makes a
       shared cloud account return another project's instances.
    2. **Only running instances** are returned.
    3. **Instances with no instance-group tag are excluded**, so half-provisioned machines
       never surface as deploy targets.

  `find_instances_by_tags/2` applies none of these — it is the raw filter primitive. Do not
  implement this callback by delegating to it without adding all three.
  """
  @callback find_app_instances(String.t(), String.t(), keyword()) ::
              {:ok, [Instance.t()]} | {:error, ErrorMessage.t()}

  @callback describe_instance(String.t(), keyword()) ::
              {:ok, Instance.t()} | {:error, ErrorMessage.t()}

  @callback start_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback stop_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback terminate_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback run_instance(map(), keyword()) ::
              {:ok, Instance.t()} | {:error, ErrorMessage.t()}

  @doc "Preferred reachable address for an instance. IPv6 wins when present."
  @callback instance_address(Instance.t()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @doc """
  Blocks until every given instance id reports as running, or returns an error.

  Optional for the same reason as `run_instance/2`: only a provider whose lifecycle needs an
  ad-hoc launch-and-wait (today, the load-test runner) implements it. The AWS implementation
  wraps the pre-existing `DeployEx.AwsMachine.wait_for_started/3` rather than reimplementing
  the poll loop.
  """
  @callback await_running([String.t()], keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback fetch_tags(String.t(), keyword()) ::
              {:ok, %{optional(String.t()) => String.t()}} | {:error, ErrorMessage.t()}

  @callback put_tags(String.t(), %{optional(String.t()) => String.t()}, keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback delete_tags(String.t(), [String.t()], keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  # Instance creation, termination and tag writes currently live inside the QA-node and
  # load-test subsystems, which Phase 5 extracts. Optional keeps the contract honest: a
  # provider conforms today without them, and the Phase-5 train makes them required when it
  # moves those call sites behind this behaviour. Implementing them now would be unused code
  # with no test that could fail.
  @optional_callbacks run_instance: 2,
                      terminate_instance: 2,
                      put_tags: 3,
                      delete_tags: 3,
                      await_running: 2
end
