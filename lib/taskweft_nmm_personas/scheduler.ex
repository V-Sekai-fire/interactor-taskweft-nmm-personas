# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.Scheduler do
  @moduledoc """
  Continuous-time scheduler for the persona and env loops. Both fire on
  wall-clock intervals via `:timer.send_interval`, not on a shared
  step counter. The persona loop refreshes its intended per-agent
  action into an ETS table at `persona_hz` Hz; the env loop reads the
  latest fragment per agent and submits at `env_hz` Hz. Only the last
  intended action per agent between env steps is submitted.

  Constraint from the persona contract: `persona_hz >= 10`. The
  scheduler enforces the requested rate and records the *measured*
  rate per episode for the rate-assertion test.
  """

  use GenServer

  alias TaskweftNmmPersonas.{Env, Persona}

  @min_persona_hz 10

  defstruct [
    :assignments,     # aid -> {persona_name, steps}
    :env_kind,        # :nmmo | :mock
    :persona_period_ms,
    :env_period_ms,
    :actions_tid,     # ETS table of latest actions
    :memory_tid,      # ETS table of persona memory
    :obs,             # last observed obs
    :trace_rows,      # reverse list of per-env-step trace rows
    :alive_ticks,     # aid -> last tick alive
    :persona_count,   # number of persona passes fired
    :env_count,       # number of env steps fired
    :t0_us,           # episode start
    :env_ticks_target
  ]

  # -- public API --------------------------------------------------------

  @doc """
  Run one episode using the continuous-time scheduler. `personas` is a
  list of `{name, steps}` tuples. Options:

  * `:persona_hz` — persona loop rate, default 30 (min 10).
  * `:env_hz` — env step rate, default 10.
  * `:env_ticks` — total env steps this episode.
  * `:env_kind` — `:nmmo` or `:mock`.
  """
  def episode(personas, opts) do
    persona_hz = Keyword.get(opts, :persona_hz, 30)
    env_hz = Keyword.get(opts, :env_hz, 10)
    env_ticks = Keyword.fetch!(opts, :env_ticks)
    env_kind = Keyword.get(opts, :env_kind, :nmmo)

    if persona_hz < @min_persona_hz do
      raise ArgumentError,
            "persona_hz #{persona_hz} < #{@min_persona_hz} (persona rate contract)"
    end

    {:ok, pid} =
      GenServer.start_link(__MODULE__, %{
        personas: personas,
        persona_hz: persona_hz,
        env_hz: env_hz,
        env_ticks: env_ticks,
        env_kind: env_kind
      })

    GenServer.call(pid, :run, 10 * 60_000)
  end

  # -- GenServer ---------------------------------------------------------

  @impl true
  def init(args) do
    actions_tid = :ets.new(:actions, [:set, :public])
    memory_tid = :ets.new(:memory, [:set, :public])

    {:ok,
     %__MODULE__{
       env_kind: args.env_kind,
       persona_period_ms: div(1000, args.persona_hz),
       env_period_ms: div(1000, args.env_hz),
       actions_tid: actions_tid,
       memory_tid: memory_tid,
       trace_rows: [],
       alive_ticks: %{},
       persona_count: 0,
       env_count: 0,
       env_ticks_target: args.env_ticks,
       assignments: build_assignments(args.personas)
     }}
  end

  @impl true
  def handle_call(:run, from, state) do
    {obs, _} = reset(state.env_kind, 0)

    agent_ids = obs |> Map.keys() |> Enum.sort()

    assignments =
      for {aid, i} <- Enum.with_index(agent_ids), into: %{} do
        {persona_name, steps} = Enum.at(state.assignments, rem(i, length(state.assignments)))
        {aid, {persona_name, steps}}
      end

    for aid <- agent_ids do
      {pn, _} = assignments[aid]
      :ets.insert(state.memory_tid, {aid, %{persona: pn}})
    end

    state = %{state | obs: obs, assignments: assignments, t0_us: System.monotonic_time(:microsecond)}

    {:ok, _pt} = :timer.send_interval(state.persona_period_ms, :persona_tick)
    {:ok, _et} = :timer.send_interval(state.env_period_ms, :env_tick)
    Process.put(:from, from)
    {:noreply, state}
  end

  @impl true
  def handle_info(:persona_tick, state) do
    rng = :rand.seed_s(:exsss, {System.unique_integer([:positive]), 1, 1})

    for {aid, ob} <- state.obs, {_, steps} = state.assignments[aid] do
      [{^aid, mem}] = :ets.lookup(state.memory_tid, aid)
      {frag, mem2, _} = Persona.apply_policy(steps, ob, mem, rng)
      :ets.insert(state.memory_tid, {aid, mem2})
      :ets.insert(state.actions_tid, {aid, frag})
    end

    {:noreply, %{state | persona_count: state.persona_count + 1}}
  end

  def handle_info(:env_tick, %{env_count: n, env_ticks_target: n} = state) do
    finish(state)
  end

  def handle_info(:env_tick, state) do
    actions =
      :ets.tab2list(state.actions_tid)
      |> Enum.filter(fn {_, frag} -> map_size(frag) > 0 end)
      |> Enum.into(%{})

    {obs2, rew, _term, _trunc, _info} = step(state.env_kind, actions)

    tick = state.env_count
    alive2 = Enum.reduce(Map.keys(obs2), state.alive_ticks, fn a, m -> Map.put(m, a, tick + 1) end)

    row = %{
      "env_tick" => tick,
      "wall_us" => System.monotonic_time(:microsecond) - state.t0_us,
      "n_alive" => map_size(obs2),
      "reward_sum" =>
        rew |> Map.values() |> Enum.map(&(&1 || 0)) |> Enum.sum() |> Float.round(4)
    }

    {:noreply,
     %{state | obs: obs2, alive_ticks: alive2,
       env_count: tick + 1, trace_rows: [row | state.trace_rows]}}
  end

  # -- finish + reply -----------------------------------------------------

  defp finish(state) do
    :timer.sleep(1)
    from = Process.get(:from)
    duration_s = (System.monotonic_time(:microsecond) - state.t0_us) / 1_000_000

    memory =
      state.memory_tid
      |> :ets.tab2list()
      |> Map.new()

    result = %{
      trace_rows: Enum.reverse(state.trace_rows),
      alive_ticks: state.alive_ticks,
      memory: memory,
      persona_passes: state.persona_count,
      env_steps: state.env_count,
      duration_s: duration_s,
      persona_hz_effective: state.persona_count / duration_s,
      env_hz_effective: state.env_count / duration_s
    }

    GenServer.reply(from, result)
    {:stop, :normal, state}
  end

  defp build_assignments(personas), do: personas

  defp reset(:nmmo, seed), do: Env.reset(seed)
  defp reset(:mock, seed), do: TaskweftNmmPersonas.MockEnv.reset(seed)

  defp step(:nmmo, actions), do: Env.step(actions)
  defp step(:mock, actions), do: TaskweftNmmPersonas.MockEnv.step(actions)
end
