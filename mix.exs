defmodule DeployEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :deploy_ex,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:ssh, :logger, :sweet_xml, :xmerl]
    ]
  end

  # ex_aws_elastic_load_balancing and ex_aws_s3 wrap their XML parsers in
  # `if Code.ensure_loaded?(SweetXml) do` at compile time. If sweet_xml has not
  # been compiled when those deps compile, the parser modules never get built
  # and ExAws returns raw XML binary bodies at runtime. Force sweet_xml first
  # so the parsers always exist.
  defp aliases do
    [
      "deps.compile": ["deps.compile sweet_xml", "deps.compile"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.3"},
      {:error_message, "~> 0.2"},
      {:ex_aws, "~> 2.3"},
      {:ex_aws_s3, "~> 2.3"},
      {:ex_aws_dynamo, "~> 4.2"},
      {:ex_aws_ec2, "~> 2.0"},
      {:ex_aws_rds, "~> 2.0"},
      {:ex_aws_elastic_load_balancing, "~> 3.0"},
      {:configparser_ex, ">= 4.0.0"},
      {:elixir_xml_to_map, "~> 3.0", override: true},
      {:exexec, "~> 0.2"},
      {:erlexec, "~> 2.0", override: true},
      {:req, "~> 0.3"},
      {:hackney, "~> 1.18"},
      {:sweet_xml, "~> 0.7"},
      {:ex_ratatui, "~> 0.4"},
      {:langchain, "~> 0.6"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end
end
