# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.MockEnv do
  @moduledoc """
  Tiny in-process env matching nmm2's PettingZoo-parallel shape, used
  by tests so they run without booting Pythonx / nmm2. 8 agents, one
  random death per tick with p=0.05.
  """

  @n 8

  def reset(seed \\ 0) do
    :persistent_term.put(__MODULE__, %{
      tick: 0,
      alive: MapSet.new(1..@n),
      rng: :rand.seed_s(:exsss, {seed, 1, 1})
    })

    {obs(), %{}}
  end

  def step(_actions) do
    state = :persistent_term.get(__MODULE__)
    t = state.tick + 1

    {alive, rng2} =
      if MapSet.size(state.alive) > 0 do
        {r, rng} = :rand.uniform_s(state.rng)

        if r < 0.05 do
          {i, rng2} = :rand.uniform_s(MapSet.size(state.alive), rng)
          victim = state.alive |> MapSet.to_list() |> Enum.at(i - 1)
          {MapSet.delete(state.alive, victim), rng2}
        else
          {state.alive, rng}
        end
      else
        {state.alive, state.rng}
      end

    :persistent_term.put(__MODULE__, %{tick: t, alive: alive, rng: rng2})
    obs2 = obs()
    rew = Map.new(alive, fn a -> {a, 0.1} end)
    term = Map.new(1..@n, fn a -> {a, not MapSet.member?(alive, a)} end)
    trunc = Map.new(1..@n, fn a -> {a, false} end)
    {obs2, rew, term, trunc, %{}}
  end

  defp obs do
    %{tick: t, alive: alive} = :persistent_term.get(__MODULE__)

    Map.new(alive, fn a ->
      # Fill Entity with 8 rows shaped like nmm2 (31 columns); self row at index (a-1)
      entity =
        for i <- 1..@n do
          row = List.duplicate(0, 31)
          # id, health, food, water — the four Persona reads
          row
          |> List.replace_at(0, i)
          |> List.replace_at(12, 80)
          |> List.replace_at(13, 60)
          |> List.replace_at(14, 60)
        end

      {a,
       %{
         "AgentId" => a,
         "CurrentTick" => t,
         "Task" => [],
         "Entity" => entity,
         "Tile" => [],
         "Inventory" => [],
         "Market" => [],
         "Communication" => [],
         "ActionTargets" => %{}
       }}
    end)
  end
end
