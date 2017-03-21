# Running Epidisco With Ketrew/Coclobas Locally

First, follow the instructions [here](running-on-coclobas.md).

Now, suppose you don't always want to SSH into your docker host to run your pipeline. Perhaps you don't want to deal with synchronizing files between that host and your preferred host.

Wouldn't it be nice if you could just `ocaml <pipeline.ml>` from your preferred host? You've come to the right place.

Setup is easy:

* Copy the following files/folders to somewhere on your preferred host:
   * `/coclo/_kclient_config`
   * `/coclo/_fake_tls`
   * `/coclo/biokepi_machine.ml`
   * `/coclo/configuration.env`

* Now, on your preferred host:
   * `opam install` all requirements, including e.g. `epidisco` and `biokepi`
   * `opam install tls`
   * `source configuration.env`
   * Run your pipeline: `ocaml <pipeline.ml>`
