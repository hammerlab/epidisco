# Epidisco

Epidisco is a highly-configurable genomic pipeline. It supports alignment, the
GATK, variant calling, epitope discovery, and vaccine generation.

It uses [Biokepi](https://github.com/hammerlab/biokepi) to construct
[Ketrew](https://github.com/hammerlab/ketrew) workflows, which can use Torque,
YARN, and even Kubernetes on Google Cloud (via
[Coclobas](https://github.com/hammerlab/coclobas)) to schedule on many kinds of
clusters.

![Pipeline Overview](docs/pipeline.png)

## Note on Multiple Samples

You can pass multiple samples into Epidisco, but they will be merged into one
sample (tumor, normal, or tumor RNA) after the alignment & mark duplicates
step. This option to process multiple samples should only be used to e.g. pass
data from biological replicates (or samples you wish to treat as such) into the
pipeline, which fundamentally operates on a tumor, normal, and tumor RNA sample
set.

## Usage

Getting started with Epidisco is most easily done by setting up a GCloud cluster
following [these instructions](./docs/), which also cover how to submit an
Epidisco job.

Once compiled, `epidisco --help` provides extensive instructions on how to
invoke the pipeline.

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

