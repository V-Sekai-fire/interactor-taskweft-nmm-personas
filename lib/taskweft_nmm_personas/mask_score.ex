# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.MaskScore do
  @moduledoc """
  Builds one MaskScore row per (persona, episode, dimension) and
  serialises to JSONL + Parquet. Field names track the EditScore
  schema documented in RFD 1173's MASKSCORE.md.

  Score columns are game-native analogues (survival fraction and
  normalised avg health) rather than the RFD's render-and-compare
  metric, because Neural MMO 2's outputs are not a rendered image.
  Schema and dimensions match; the *content* of `scores` is the
  domain-specific reduction.
  """

  @doc "One MaskScore row for a persona in one episode. Returns nil if the persona has no agents."
  def row(persona, seed, ep, ticks, trace_path, alive_ticks, memory, dimension) do
    persona_agents =
      for {aid, m} <- memory, m[:persona] == persona, do: aid

    case persona_agents do
      [] ->
        nil

      _ ->
        survival =
          persona_agents
          |> Enum.map(&Map.get(alive_ticks, &1, 0))
          |> then(&(Enum.sum(&1) / max(length(&1), 1)))

        avg_health =
          persona_agents
          |> Enum.map(&(memory[&1][:health] || 0))
          |> then(&(Enum.sum(&1) / max(length(&1), 1)))

        %{
          "key" => stable_key(persona, seed, ep),
          "instruction" => "play Neural MMO 2 as a #{persona} persona for #{ticks} ticks",
          "input_state" => "seed=#{seed}",
          "conditioning_image" => nil,
          "output_traces" => [trace_path],
          "scores" => [
            Float.round(survival / ticks, 4),
            Float.round(avg_health / 100.0, 4)
          ],
          "task_type" => "survive",
          "dimension" => dimension
        }
    end
  end

  defp stable_key(persona, seed, ep) do
    h =
      :crypto.hash(:sha256, "#{persona}:#{seed}:#{ep}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "nmm2_#{persona}_seed#{seed}_ep#{ep}_#{h}"
  end

  @doc """
  Write rows to a Parquet file via `duckdb` CLI reading the JSONL sibling
  we just wrote. Cheap and doesn't add a Python dep for one file format;
  duckdb is single-binary and reads/writes both. Skipped silently if the
  binary is absent — JSONL is the source of truth.
  """
  def write_parquet([], _path), do: :ok

  def write_parquet(_rows, path) do
    jsonl = String.replace_suffix(path, ".parquet", ".jsonl")

    case System.find_executable("duckdb") do
      nil ->
        :ok

      duckdb ->
        sql = "COPY (SELECT * FROM read_json_auto('#{jsonl}')) TO '#{path}' (FORMAT PARQUET);"
        System.cmd(duckdb, ["-c", sql], stderr_to_stdout: true)
        :ok
    end
  end
end
