# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.Persona do
  @moduledoc """
  Step-name dispatch: each function takes `(obs_for_one_agent, memory, rng)`
  and returns `{action_fragment_map, updated_memory, updated_rng}`. A
  persona is a linear list of step names (extracted from the lowered
  HTN's `methods.buildout.subtasks`); its policy is the composition of
  its steps' fragments, submitted once per env tick.

  nmm2 Entity column layout mirrors
  `nmmo.entity.entity.EntityState.State.attr_name_to_col`.
  """

  # Entity columns
  @e_id 0
  @e_row 2
  @e_col 3
  @e_gold 11
  @e_health 12
  @e_food 13
  @e_water 14

  # Inventory (ItemState) columns
  @i_level 3
  @i_quantity 5
  @i_price 15

  # Move directions
  @stay 0
  @north 1
  @south 2
  @east 3
  @west 4

  @directions [@north, @south, @east, @west]

  @doc "Apply the persona's step list to one agent's obs; return the action fragment map."
  def apply_policy(steps, obs, memory, rng) do
    Enum.reduce(steps, {%{}, memory, rng}, fn step, {acc, mem, r} ->
      {frag, mem2, r2} = dispatch(step, obs, mem, r)
      {Map.merge(acc, frag), mem2, r2}
    end)
  end

  # -- step handlers ------------------------------------------------------

  # Every persona starts here. Reads the self-row from Entity, stashes vitals.
  def dispatch("sense", obs, mem, rng) do
    self_id = obs["AgentId"]
    entity = obs["Entity"] || []

    updated =
      Enum.find_value(entity, mem, fn row ->
        case Enum.at(row, @e_id) do
          ^self_id ->
            Map.merge(mem, %{
              health: Enum.at(row, @e_health),
              food: Enum.at(row, @e_food),
              water: Enum.at(row, @e_water),
              gold: Enum.at(row, @e_gold),
              row: Enum.at(row, @e_row),
              col: Enum.at(row, @e_col)
            })

          _ ->
            nil
        end
      end)

    {%{}, updated, rng}
  end

  # Forager
  def dispatch("seek_water", _obs, mem, rng) do
    if (mem[:water] || 100) < 40, do: random_move(mem, rng), else: {%{}, mem, rng}
  end

  def dispatch("gather_food", _obs, mem, rng) do
    if (mem[:food] || 100) < 40, do: random_move(mem, rng), else: {%{}, mem, rng}
  end

  def dispatch("wander", _obs, mem, rng) do
    {dir, rng2} = pick(rng, [@stay | @directions])
    {%{"Move" => %{"Direction" => dir}}, mem, rng2}
  end

  # Hunter
  def dispatch("heal_or_flee", _obs, mem, rng) do
    if (mem[:health] || 100) < 40, do: random_move(mem, rng), else: {%{}, mem, rng}
  end

  def dispatch("seek_target", _obs, mem, rng), do: {%{}, mem, rng}

  def dispatch("attack_or_move", obs, mem, rng) do
    self_id = obs["AgentId"]
    entity = obs["Entity"] || []
    my_r = mem[:row] || 0
    my_c = mem[:col] || 0

    {best_idx, best_d} =
      entity
      |> Enum.with_index()
      |> Enum.reduce({nil, 10_000}, fn {row, i}, {bi, bd} ->
        id = Enum.at(row, @e_id)

        cond do
          id == 0 or id == self_id ->
            {bi, bd}

          true ->
            d = abs(Enum.at(row, @e_row) - my_r) + abs(Enum.at(row, @e_col) - my_c)
            if d < bd, do: {i, d}, else: {bi, bd}
        end
      end)

    cond do
      best_idx != nil and best_d <= 3 ->
        {%{"Attack" => %{"Style" => 0, "Target" => best_idx}}, mem, rng}

      true ->
        random_move(mem, rng)
    end
  end

  # Trader
  def dispatch("sell_surplus", obs, mem, rng) do
    inv = obs["Inventory"] || []

    found =
      inv
      |> Enum.with_index()
      |> Enum.find(fn {row, _i} ->
        Enum.at(row, @i_quantity, 0) >= 2 and Enum.at(row, @i_price, 0) == 0
      end)

    case found do
      {row, i} ->
        price = min(5 + Enum.at(row, @i_level, 0), 98)
        {%{"Sell" => %{"InventoryItem" => i, "Price" => price}}, mem, rng}

      nil ->
        {%{}, mem, rng}
    end
  end

  def dispatch("buy_cheap", obs, mem, rng) do
    market = obs["Market"] || []
    gold = mem[:gold] || 0
    ceiling = min(div(gold, 4), 5)

    found =
      market
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        price = Enum.at(row, @i_price, 0)
        price > 0 and price <= ceiling
      end)

    case found do
      {_, i} -> {%{"Buy" => %{"MarketItem" => i}}, mem, rng}
      nil -> {%{}, mem, rng}
    end
  end

  def dispatch("end_turn", _obs, mem, rng), do: {%{}, mem, rng}

  def dispatch(_unknown, _obs, mem, rng), do: {%{}, mem, rng}

  # -- helpers ------------------------------------------------------------

  defp random_move(mem, rng) do
    {dir, rng2} = pick(rng, @directions)
    {%{"Move" => %{"Direction" => dir}}, mem, rng2}
  end

  defp pick(rng, xs) do
    {i, rng2} = :rand.uniform_s(length(xs), rng)
    {Enum.at(xs, i - 1), rng2}
  end
end
