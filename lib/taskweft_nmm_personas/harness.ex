# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.Harness do
  @moduledoc """
  Run one or more Neural MMO 2 episodes with lowered persona HTNs
  driving the agents. Uses `TaskweftNmmPersonas.Scheduler` for
  continuous-time persona/env cadence, writes traces + MaskScore
  rows.
  """

  alias TaskweftNmmPersonas.{Scheduler, MaskScore}

  @doc """
  Options:
    * `:episodes` (default 1)
    * `:env_ticks` (default 32) — env steps per episode
    * `:persona_hz` (default 30) — persona loop rate; min 10
    * `:env_hz` (default 10) — env step rate
    * `:seed` (default 42)
    * `:out` (default "traces")
    * `:env` (default `:nmmo`) — `:nmmo` or `:mock`
  """
  def run(persona_files, opts \\ []) do
    episodes = Keyword.get(opts, :episodes, 1)
    env_ticks = Keyword.get(opts, :env_ticks, 32)
    persona_hz = Keyword.get(opts, :persona_hz, 30)
    env_hz = Keyword.get(opts, :env_hz, 10)
    seed = Keyword.get(opts, :seed, 42)
    out_dir = Keyword.get(opts, :out, "traces")
    env_kind = Keyword.get(opts, :env, :nmmo)
    File.mkdir_p!(out_dir)

    personas =
      Enum.map(persona_files, fn f ->
        htn = f |> File.read!() |> Jason.decode!()
        {htn["name"], persona_steps(htn)}
      end)

    ms_path = Path.join(out_dir, "maskscore.jsonl")

    {rows, ep_stats} =
      for ep <- 0..(episodes - 1), reduce: {[], []} do
        {rs, stats} ->
          ep_seed = seed + ep
          {ep_rows, s} = run_episode(personas, ep, ep_seed, env_ticks,
                                     persona_hz, env_hz, out_dir, env_kind)
          {rs ++ ep_rows, [s | stats]}
      end

    File.write!(ms_path,
      Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n",
      [:append])
    MaskScore.write_parquet(rows, Path.join(out_dir, "maskscore.parquet"))

    {:ok, %{ms_jsonl: ms_path, rows: length(rows), ep_stats: Enum.reverse(ep_stats)}}
  end

  defp persona_steps(htn) do
    htn
    |> get_in(["methods", "buildout", "alternatives"])
    |> hd()
    |> Map.get("subtasks")
    |> Enum.map(fn [m] -> String.replace_prefix(m, "m_", "") end)
  end

  defp run_episode(personas, ep, seed, env_ticks, persona_hz, env_hz, out_dir, env_kind) do
    result =
      Scheduler.episode(personas,
        persona_hz: persona_hz,
        env_hz: env_hz,
        env_ticks: env_ticks,
        env_kind: env_kind
      )

    trace_path = Path.join(out_dir, "ep#{ep}_seed#{seed}.trace.jsonl")

    File.write!(trace_path,
      Enum.map_join(result.trace_rows, "\n", &Jason.encode!/1) <> "\n")

    persona_names = personas |> Enum.map(&elem(&1, 0))

    rows =
      for name <- persona_names,
          dim <- ["instruction_following", "consistency", "overall"] do
        MaskScore.row(name, seed, ep, env_ticks, trace_path,
                      result.alive_ticks, result.memory, dim)
      end
      |> Enum.reject(&is_nil/1)

    {rows,
     %{
       episode: ep,
       seed: seed,
       persona_hz_target: persona_hz,
       env_hz_target: env_hz,
       persona_hz_effective: Float.round(result.persona_hz_effective, 2),
       env_hz_effective: Float.round(result.env_hz_effective, 2),
       persona_passes: result.persona_passes,
       env_steps: result.env_steps,
       duration_s: Float.round(result.duration_s, 3)
     }}
  end
end
