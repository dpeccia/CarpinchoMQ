defmodule CarpinchoMq.MixProject do
  use Mix.Project

  def project do
    [
      app: :carpincho_mq,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [
        test: "test --no-start --trace"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      { :libcluster, "~> 3.0" },
      { :horde, git: "https://github.com/TP-IASC/horde.git" },
      { :ok, "~> 2.3" },
      { :plug_cowboy, "~> 2.5.2" },
      { :poison, "~> 5.0" },
      { :corsica, "~> 1.0"},
      { :jason, "~> 1.2" },
      { :local_cluster, "~> 1.2.1", only: [:test] },
      { :mock, "~> 0.3.7", only: :test },
      { :schism, "~> 1.0", only: [:test]},
      { :ex_matchers, "~> 0.1.2", only: :test}
    ]
  end
end
