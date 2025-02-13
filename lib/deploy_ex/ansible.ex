defmodule DeployEx.Ansible do
  @ansible_flags [
    inventory: :string,
    limit: :string,
    extra_vars: :keep
  ]

  def parse_args(args) do
    {ansible_opts, _extra_args, _invalid_args} =
      OptionParser.parse(args,
        aliases: [i: :inventory, e: :extra_vars],
        strict: @ansible_flags
      )

    ansible_opts
    |> OptionParser.to_argv(@ansible_flags)
    |> Enum.map(fn part ->
      if part =~ " " do
        "'#{part}'"
      else
        part
      end
    end)
    |> Enum.join(" ")
  end
end
