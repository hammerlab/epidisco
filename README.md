Epidisco
========

Epitope discovery and vaccine prediction family of pipelines.


Usage
-----

You need a cluster; abstracted as a `Biokepi.Machine.t`.

You can get one on Google Cloud following the instructions there:
<https://github.com/smondet/stratotemplate>

The template provides a `biokepi_machine.ml` file.

In the same Docker environment (the one we enter with
`sudo  docker run -it  -v $PWD:/hostuff/ smondet/stratocumulus bash`):

    opam pin add --yes epidisco "https://github.com/hammerlab/epidisco.git"

A script with command-line parsing and all can be created from the
`Epidisco` library:

```ocaml
#use "topfind";;
#thread
#require "epidisco";;

#use "./biokepi_machine.ml";;

let () =
  Epidisco.Command_line.main ~biokepi_machine ()
```
