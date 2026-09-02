# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule Mix.Tasks.Nmm.Run do
  @moduledoc """
  Run one or more Neural MMO 2 episodes with lowered persona HTNs.

      mix nmm.run --personas <dir> --env nmmo --env-ticks 32 \\
          --persona-hz 30 --env-hz 10 --seed 42 --out traces/

  Options:
    --personas    directory of *.htn.jsonld (default: personas/lowered)
    --env         `nmmo` (real, via bus) or `mock` (in-process)
    --episodes    number of episodes (default 1)
    --env-ticks   env steps per episode (default 32)
    --persona-hz  persona loop rate; min 10 (default 30)
    --env-hz      env step rate (default 10)
    --seed        base seed
    --out         directory for trace shards + maskscore.jsonl / .parquet
  """
  use Mix.Task
  @shortdoc "Play Neural MMO 2 with persona HTNs; emit MaskScore rows"

  @impl true
  def run(argv) do
    {opts, _} =
      OptionParser.parse!(argv,
        strict: [
          personas: :string, env: :string, episodes: :integer,
          env_ticks: :integer, persona_hz: :integer, env_hz: :integer,
          seed: :integer, out: :string
        ]
      )

    personas_dir = Keyword.get(opts, :personas, "personas/lowered")
    files = Path.wildcard(Path.join(personas_dir, "*.htn.jsonld"))

    if files == [] do
      Mix.raise("no *.htn.jsonld under #{personas_dir}; run mix taskweft.grafcet.lower first")
    end

    {:ok, res} =
      TaskweftNmmPersonas.Harness.run(
        files,
        env: opts |> Keyword.get(:env, "nmmo") |> String.to_atom(),
        episodes: Keyword.get(opts, :episodes, 1),
        env_ticks: Keyword.get(opts, :env_ticks, 32),
        persona_hz: Keyword.get(opts, :persona_hz, 30),
        env_hz: Keyword.get(opts, :env_hz, 10),
        seed: Keyword.get(opts, :seed, 42),
        out: Keyword.get(opts, :out, "traces")
      )

    for s <- res.ep_stats do
      Mix.shell().info(
        "ep#{s.episode} seed#{s.seed}: persona #{s.persona_hz_effective} Hz " <>
        "(target #{s.persona_hz_target}), env #{s.env_hz_effective} Hz " <>
        "(target #{s.env_hz_target}), #{s.duration_s}s"
      )
    end

    Mix.shell().info("#{res.rows} MaskScore rows -> #{res.ms_jsonl}")
  end
end
