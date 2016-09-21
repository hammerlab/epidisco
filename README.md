# Epidisco

Epidisco is a highly-configurable genomic pipeline. It supports alignment, the
GATK, variant calling, epitope discovery, and vaccine generation.

It uses [Biokepi](https://github.com/hammerlab/biokepi) to construct
[Ketrew](https://github.com/hammerlab/ketrew) workflows, which can use Torque,
YARN, and even Kubernetes on Google Cloud (via
[Coclobas](https://github.com/hammerlab/coclobas)) to schedule on many kinds of
clusters.

## Usage

Getting started with Epidisco is most easily done by setting up a GCloud cluster
following [these instructions](./docs/), which also cover how to submit an
Epidisco job.

### Advanced Usage

For more advanced uses, you can build `Epidisco` with `omake`, and then run it
using an ocaml script like the following (calling it, say, `epi.ml`).

```ocaml
#use "topfind";;
#thread
#require "epidisco";;

#use "./biokepi_machine.ml";;

let () =
  Epidisco.Command_line.main ~biokepi_machine ()
```

Call it with `ocaml epi.ml` to see the possible options.

