# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule TaskweftNmmPersonas.BusNif do
  @moduledoc """
  Elixir client of `2-contract/bus`'s DYNAMIC command bus (iceoryx2, byte
  slice, 8-byte request-id envelope). Modelled on
  `2-contract/bus/proof/command_publisher.cpp`.

  `open/0` acquires a node, opens both services, and creates the publisher
  and subscriber. `ask/3` publishes a command with a fresh request id and
  polls the reply subscriber until the reply carrying that id arrives, or
  the timeout elapses. Both calls dispatch to the NIF at
  `priv/weft_bus_nif.so`, built by `elixir_make` from `c_src/`.

  Requires the iceoryx2 shared library at runtime; set `WEFT_ICEORYX2_PATH`
  to its path (e.g. `.../7-service/service-cineform/thirdparty/iceoryx2/target/release/libiceoryx2_ffi_c.dylib`).
  """
  @on_load :load

  def load do
    path = :filename.join(:code.priv_dir(:taskweft_nmm_personas), ~c"weft_bus_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def open, do: :erlang.nif_error(:not_loaded)
  def ask(_client, _body, _timeout_ms), do: :erlang.nif_error(:not_loaded)
end
