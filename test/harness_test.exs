# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.HarnessTest do
  use ExUnit.Case, async: false

  alias TaskweftNmmPersonas.{Harness, Scheduler}

  @tmp Path.expand("../tmp_traces", __DIR__)
  @personas Path.expand("../personas", __DIR__)

  setup do
    File.rm_rf!(@tmp)
    lowered = Path.join(@personas, "lowered")
    File.mkdir_p!(lowered)

    for f <- Path.wildcard(Path.join(@personas, "*.grafcet.jsonld")) do
      htn = f |> File.read!() |> Jason.decode!() |> Taskweft.Grafcet.lower()
      out = Path.join(lowered, Path.basename(f, ".grafcet.jsonld") <> ".htn.jsonld")
      File.write!(out, Jason.encode!(htn))
    end

    :ok
  end

  test "MockEnv episode produces 9 MaskScore rows (3 personas x 3 dimensions)" do
    files = Path.wildcard(Path.join(@personas, "lowered/*.htn.jsonld"))
    assert length(files) == 3

    {:ok, res} =
      Harness.run(files,
        env: :mock, episodes: 1, env_ticks: 8,
        persona_hz: 20, env_hz: 5, seed: 1, out: @tmp
      )

    assert res.rows == 9
    lines = res.ms_jsonl |> File.read!() |> String.trim() |> String.split("\n")
    assert length(lines) == 9
    row = lines |> hd() |> Jason.decode!()
    assert row["task_type"] == "survive"
    assert row["dimension"] in ["instruction_following", "consistency", "overall"]
  end

  test "persona rate meets the >=10 Hz contract" do
    files = Path.wildcard(Path.join(@personas, "lowered/*.htn.jsonld"))

    {:ok, res} =
      Harness.run(files,
        env: :mock, episodes: 1, env_ticks: 16,
        persona_hz: 20, env_hz: 5, seed: 7, out: @tmp
      )

    [stats] = res.ep_stats
    assert stats.persona_hz_target == 20
    assert stats.env_hz_target == 5
    # Effective rate can undershoot slightly on a slow scheduler tick;
    # the contract floor is 10 Hz, and 20 Hz target must clear it with
    # comfortable margin on any modern box.
    assert stats.persona_hz_effective >= 10.0,
           "persona rate #{stats.persona_hz_effective} Hz below 10 Hz contract floor"
    # And should not massively overshoot either (a hot loop would).
    assert stats.persona_hz_effective <= stats.persona_hz_target * 2
  end

  test "Scheduler refuses persona_hz below the 10 Hz floor" do
    assert_raise ArgumentError, ~r/persona rate contract/, fn ->
      Scheduler.episode([{"forager", ["sense", "end_turn"]}],
        persona_hz: 5, env_hz: 5, env_ticks: 1, env_kind: :mock)
    end
  end
end
