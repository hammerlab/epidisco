#!/bin/bash

biokepi_machine=$1
if ! [ -f "$biokepi_machine" ] ; then
    echo "usage: $0 <biokepi-machine.ml> [args]"
    exit 2
fi

shift

source=/tmp/runepi.ml
executable=/tmp/runepi.native

sed 's/^#.*//' $biokepi_machine > $source
echo "
let () =
  Epidisco.Command_line.main ~biokepi_machine ()
" >> $source
ocamlfind opt -package epidisco,coclobas.ketrew_backend -linkpkg $source -thread -o $executable

$executable $*
