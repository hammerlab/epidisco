Running On a Single Machine
===========================

Prerequisites
-------------

You need a beefy Linux `x86_64` machine, with `docker` and `docker-compose`
available (and ready to use by the current UNIX user).
You'll also need to access this host on port 443 (HTTPS).

For example on Ubuntu 16.04 (LTS):

    sudo apt-get install -y docker docker-compose
    sudo adduser $USER docker
    sudo su $USER # so that the group is taken into account
    docker ps # should not complain :)

Get Secotrec-local
------------------

[Secotrec](https://github.com/hammerlab/secotrec)-local is tool that can deploy
the infrastructure needed to run Epidisco. We need to download the application:

    mkdir ~/bin/
    wget -O ~/bin/secotrec-local https://storage.googleapis.com/smondet-experiments/secotrec-local-Linux-x86_64
    chmod +x ~/bin/secotrec-local
    export PATH=~/bin:$PATH

And do a quick test:

    secotrec-local --help

Local Infrastructure Deployment
-------------------------------

Secotrec-local is configured with environment variables, you can put them in a
file and source it, or just paste them in your shell:

    # HTTPS port to access the Ketrew UI:
    export tls_port=443
    # Directory where Epidisco will write files
    export biokepi_work=$HOME/biokepi-work/
    # Long, random, secret string of you choice:
    export ketrew_auth_token=dsleaijdej308098ddecja9c8jra8cjrf98r
    # The maximal number of jobs that are allowed to run at once:
    export coclobas_max_jobs=8
    # We also want a configured Epidisco development environment:
    export epidisco_dev=$HOME/epidisco-shared
    # We want to get recent version of most tools:
    export coclobas_docker_image=hammerlab/keredofi:coclobas-aws-biokepi-dev

You check that the configuration is taken into account:

    secotrec-local print-conf

Then you can launch the setup:

    secotrec-local up

the first time it takes a while because it pulls docker images.

Check the status of the deployment with:

    secotrec-local status

Using the hostname or IP address of your host, you can
access [Ketrew](https://github.com/hammerlab/ketrew)'s (the workflow manager)
WebUI at (using the auth-token you defined above):

`https:// ... /gui?token=dsleaijdej308098ddecja9c8jra8cjrf98r`


Submit a First Epidisco Run
---------------------------

Let's generate the “infrastructure” configuration for Epidisco,
`biokepi_machine.ml` (named after
the [Biokepi](https://github.com/hammerlab/biokepi) project which provides the
basic reusable building blocs that make up Epidisco):

    secotrec-local biokepi-machine $epidisco_dev/biokepi_machine.ml

and then *enter* the docker-container which has all the necessary dependencies
(incl. Epidisco itself):

    secotrec-local docker-compose -- exec epidisco-dev opam config exec bash

Let's configure the client-side for Ketrew (fill your host like above):

    ketrew init --just-client http://kserver:8080/gui?token=dsleaijdej308098ddecja9c8jra8cjrf98r

Let's just run a quick test of the configuration:

    ketrew submit --dae /tmp/,"du -sh /epidisco-shared" --wet-run

The job should be visible on the Ketrew WebUI (you can also use the “TextUI” by
simply typing `ketrew interact` and following the 80's-styled menus).

We just need to get the “epidisco runner:”

    curl -O https://storage.googleapis.com/smondet-experiments/epirunner.sh

And check that it works:

    bash epirunner.sh /epidisco-shared/biokepi_machine.ml --help=plain

We need to tell Biokepi how to download non-openly-accessible software, you need
to fill these with your own URLs:

```
export GATK_JAR_URL="https://..."
export MUTECT_JAR_URL="https://..."
export NETMHC_TARBALL_URL="https://..."
export NETMHCPAN_TARBALL_URL="https://..."
export PICKPOCKET_TARBALL_URL="https://..."
export NETMHCCONS_TARBALL_URL="https://..."
export CIBERSORT_URL="https://..."
```

Let's now run it with some data:

```
export normal=https://storage.googleapis.com/smondet-experiments/datasets/training-dream/normal.chr20.bam
export tumor=https://storage.googleapis.com/smondet-experiments/datasets/training-dream/tumor.chr20.bam
export experiment=training-without-rna
export mhc_alleles="H-2-Kb,H-2-Db"
bash epirunner.sh /epidisco-shared/biokepi_machine.ml \
          --normal $normal \
          --tumor  $tumor \
          --reference-build b37decoy \
          --results-path /nfsaa/results \
          --mhc-alleles $mhc_alleles \
          $experiment
```

You can now go babysit your Epidisco run with the Ketrew UI.


If all goes as planned and succeeds, you should have an HTML report at

    $biokepi_work/results/training-without-rna-1normals-1tumors--b37decoy/index.html

Then you can also try with bigger data, for instance:

```
export normal=https://storage.googleapis.com/dream-challenge/synthetic.challenge.set2.normal.bam
export tumor=https://storage.googleapis.com/dream-challenge/synthetic.challenge.set2.tumor.bam
export experiment=dream2
```

or just your *own* samples.


Take Everything Down
--------------------

Just call:

    secotrec-local down --yes

FAQ/Troubleshooting
-------------------

### Some Bioinformatics Tool Failed

Yes, it happens, see
issue
[`hammerlab/biokepi#193`](https://github.com/hammerlab/biokepi/issues/193).

Ketrew's UI allows you to inspect the failed jobs.

You can also resubmit the pipeline while parts of the previous submission are
still running; Ketrew will merge the new pipeline are piggy-back on the previous
workflow.

### How *Beefy* is “Beefy”?

We tested this
on a Google Cloud `n1-highmem-32` node (32 vCPUs, 208 GB memory)
with a 3 TB hard disk.
Together with a quite conservative setting: `coclobas_max_jobs=8`.

If your host is smaller (memory *or* CPU) allow less jobs to run in parallel
(again, with `coclobas_max_jobs`).

Still, some individual jobs may be very memory-greedy (e.g. variant callers
working on high-coverage areas).

### I Want To Run With My Own Data But Not With HTTP(S) URLs

You can put your input files (FASTQ or Bam) somewhere in the
`$biokepi_work` directory, but from the docker-containers' point of view the
paths have a different prefix: `/biokepi`.

For instance if you put your RNA input file in
`$biokepi_work_dir/input/rna.bam`, you need to call Epidisco with
`--rna /biokepi/input/rna.bam`.

### I Modified Ketrew/Biokepi/Epidisco/Secotrec Can I Try In This Setting?

Yes, it's possible :)

#### Client-Side

If your change is “client-side” (meaning that it impacts the definition of
the workflow submitted to Ketrew), you need to bring the change into the
`epidisco-dev` container:

Once you enter (with `secotrec-local docker-compose exec ...`), you're in a
fully functioning `opam` environment, so let's say you have a branch of Biokepi
you want to test, you can simply:

    opam pin add biokepi https://github.com/some-user/biokepi.git#my_branch

#### Server-Side

Secotrec can also call `opam pin` on any given branch of Ketrew or Coclobas, e.g.:

    export pin_ketrew=my_branch
    ...
    secotrec-local up

Note that since the `opam pin` triggers a bunch of re-builds the Ketrew and
Coclobas servers take longer to be available when there is a `pin`, you can
check progress looking at the docker-compose logs:

    secotrec-local docker-compose logs {kserver,coclo}

#### Secotrec

If secotrec was built without the `postgresql` dependency, the `secotrec-local`
binary is quite portable, if you built it with the postres library, the binary
needs the shared `libpq` library (`sudo apt install -y libpq-dev` on
Debian/Ubuntu).
