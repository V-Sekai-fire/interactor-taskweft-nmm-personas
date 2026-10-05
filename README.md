# interactor-taskweft-nmm-personas

GRAFCET personas, lowered by taskweft, that play a multi-agent survival environment over the contract bus and record MaskScore traces.

## Use

Each persona is an IEC 60848 GRAFCET chart that taskweft lowers to a hierarchical task network. Elixir dispatches the personas, writes the traces and builds one MaskScore row per persona, episode and dimension. A Python server holds the `nmmo` environment and answers over the iceoryx2 bus, and an in-process mock environment stands in for it in tests. The project builds against sibling checkouts of taskweft and the contract bus.

## Build and run

```sh
pixi run serve
mix nmm.run
```

`mix help nmm.run` lists the run's options, and `mix test` runs the suite.

## Licence

MIT, per the SPDX headers in the sources, and the bus NIF source is MIT OR Apache-2.0. There is no `LICENSE` file.
