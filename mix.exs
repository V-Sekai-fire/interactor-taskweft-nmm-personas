# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.MixProject do
  use Mix.Project

  def project do
    [
      app: :taskweft_nmm_personas,
      version: "0.1.0",
      elixir: "~> 1.18",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["priv/weft_bus_nif.so"],
      make_clean: ["clean"],
      deps: deps(),
      description:
        "Persona agents (compact IEC 60848 GRAFCET, lowered by taskweft) playing Neural MMO 2 over 2-contract/bus (iceoryx2), traces in MaskScore format."
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:jason, "~> 1.4"},
      {:cbor, "~> 1.0"},
      {:ezstd, "~> 1.1"},
      {:taskweft, path: "../taskweft"}
    ]
  end
end
