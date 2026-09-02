# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule Mix.Tasks.Nmm.Push do
  @moduledoc """
  Upload the traces directory to a Hugging Face dataset repo via
  `huggingface-cli upload` (install with the workspace's usual Python
  env — Pythonx-embedded or a project pixi). Requires HF_TOKEN in env
  or a prior `huggingface-cli login`.

      HF_TOKEN=hf_xxx mix nmm.push --repo <user>/nmm2-personas-maskscore
  """
  use Mix.Task
  @shortdoc "Push MaskScore traces to a HF dataset"

  @impl true
  def run(argv) do
    {opts, _} =
      OptionParser.parse!(argv,
        strict: [repo: :string, traces: :string, private: :boolean]
      )

    repo = Keyword.fetch!(opts, :repo)
    traces = Keyword.get(opts, :traces, "traces")
    private = Keyword.get(opts, :private, false)

    cli = System.find_executable("huggingface-cli") || Mix.raise("huggingface-cli not found on PATH")

    args =
      ["upload", repo, traces, ".", "--repo-type=dataset"] ++
        if(private, do: ["--private"], else: [])

    {out, code} = System.cmd(cli, args, stderr_to_stdout: true)
    Mix.shell().info(out)

    if code != 0 do
      Mix.raise("huggingface-cli exited #{code}")
    end
  end
end
