# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.Env do
  @moduledoc """
  Neural MMO 2 env fronted by `priv/env_bus_server.py` (uses
  `2-contract/bus/python/weft_harness.Bus` in server role) and reached
  from Elixir over the DYNAMIC command bus via
  `TaskweftNmmPersonas.BusNif`.

  Stdio JSON is blocklisted for this class of wire; `2-contract/bus` is
  the canonical transport, and the Python side reuses `weft_harness.Bus`
  verbatim. Bodies on the wire are JSON here; a future FIXED_SIZE struct
  pair can replace them without touching Elixir's dispatch.

  Boot the server externally (once, before running episodes):

      export WEFT_ICEORYX2_PATH=.../libiceoryx2_ffi_c.dylib
      python 3-interactor/taskweft-nmm-personas/priv/env_bus_server.py &

  `reset/1` and `step/1` open the client lazily and cache it in
  `:persistent_term` for the lifetime of the VM.
  """

  alias TaskweftNmmPersonas.BusNif

  @timeout_ms 30_000

  def reset(seed \\ 0) do
    r = ask!(%{op: "reset", seed: seed})
    {int_keyed(r["obs"]), r["info"]}
  end

  def step(actions) when is_map(actions) do
    r = ask!(%{op: "step", actions: string_keys(actions)})

    {int_keyed(r["obs"]), int_keyed(r["rew"]), int_keyed(r["term"]),
     int_keyed(r["trunc"]), r["info"]}
  end

  def close do
    _ = ask!(%{op: "close"})
    :persistent_term.erase(__MODULE__)
    :ok
  end

  # -- helpers ------------------------------------------------------------

  defp ask!(req) do
    client = client()
    body = encode(req)

    case BusNif.ask(client, body, @timeout_ms) do
      {:ok, reply} ->
        case decode(reply) do
          %{"error" => err} -> raise "env server error: #{err}"
          ok -> ok
        end

      {:error, reason} ->
        raise "bus ask failed: #{reason}"
    end
  end

  # Wire encoding: 1-byte envelope tag + CBOR body, zstd-compressed
  # when tagged "Z", plain CBOR when tagged "C". zstd's ~250× on numpy
  # obs is what makes the full 128-agent config fit under 2-contract/bus's
  # 128 KiB message ceiling.
  defp encode(term) do
    "Z" <> :ezstd.compress(CBOR.encode(term))
  end

  defp decode(<<"Z", body::binary>>), do: decode_cbor!(:ezstd.decompress(body))
  defp decode(<<"C", body::binary>>), do: decode_cbor!(body)
  defp decode(other), do: raise("unknown envelope tag: #{inspect(binary_part(other, 0, 1))}")

  defp decode_cbor!(bin) do
    {:ok, val, _rest} = CBOR.decode(bin)
    normalize(val)
  end

  # CBOR maps come back with binary keys, tags as %CBOR.Tag{}, etc.
  # Personas expect string keys — normalise once, cheap on our sizes.
  defp normalize(%CBOR.Tag{value: v}), do: normalize(v)
  defp normalize(m) when is_map(m) do
    for {k, v} <- m, into: %{}, do: {normalize_key(k), normalize(v)}
  end
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(other), do: other

  defp normalize_key(k) when is_binary(k), do: k
  defp normalize_key(k), do: k

  defp client do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        {:ok, c} = BusNif.open()
        :persistent_term.put(__MODULE__, c)
        c

      c ->
        c
    end
  end

  defp string_keys(m) when is_map(m) do
    for {k, v} <- m, into: %{}, do: {to_string(k), v}
  end

  defp int_keyed(m) when is_map(m) do
    for {k, v} <- m, into: %{} do
      case Integer.parse(to_string(k)) do
        {i, ""} -> {i, v}
        _ -> {k, v}
      end
    end
  end

  defp int_keyed(other), do: other
end
