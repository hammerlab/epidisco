# Running Epidisco With Ketrew/Coclobas

## Setting Things Up

This quickstart guide will get you running Epidisco on test data (or your own)
on the GCloud platform, using our Kubernetes scheduler, Coclobas.

To keep things as simple as possible, we use a script (`disco.sh`) to do most
of the work. If you're interested in what's going on behind the scenes, disco
check out the script, which is documented, or you can always try `./disco.sh
type <command>` to see what a particular command is doing, and just
`./disco.sh` to get a list of all possible commands.

### Set Up a Launch Box

We need a server on GCloud to run our scheduler and Ketrew, our workflow
engine. This box will serve as the interface between your workflow and GCloud's running
of them.

You'll need the GCloud command line utility, installed and initialized
[from here](https://cloud.google.com/sdk/downloads#interactive).

Optionally set your preferred zone before you get started:

```shell
# disco.sh default
export GCLOUD_ZONE="us-east1-c"
```

Download our setup script and use it to create a GCloud box:

```shell
wget https://raw.githubusercontent.com/hammerlab/epidisco/master/docs/disco.sh
chmod 777 disco.sh
./disco.sh create example-box-name
```

Once it's created, you will be able to ssh in with `gcloud compute ssh
example-box-name --zone=$GCLOUD_ZONE`. The rest of the instructions will be
carried out inside this VM.


### Configuring the Cluster

We will now create an NFS filer that the cluster will use, and generate a
configuration file for both a Coclobas cluster and, to be used later, a Biokepi
machine. Note that `disco.sh` should have been copied to your home directory on
this box for you already.

```shell
# Optional: change this if you need a bigger/smaller cluster
export CLUSTER_MAX_NODES=15

# Change the following only if you changed the zone during the initial setup
export GCLOUD_ZONE="us-east1-c"

# This will create a file called 'configuration.env'
./disco.sh configure
```

**NOTE** You will need to edit the `configuration.env` file by hand, to point the
`GATK_JAR_URL` and `MUTECT_JAR_URL` to the jar files of those programs,
respectively, somewhere on a network that GCloud can reach. If you aren't using
these programs in your workflows, you don't need to worry about this, but since
we are in the example workflow below, you do. While Biokepi will automatically
download and install most tools, the authors of these tools have put them behind
passwords and licenses that make it impossible to provide this convenience to
you.

Next we want to set up and run our Docker image, which is where Coclobas and
Ketrew will be running, and eventually is where we will submit our workflows
from.

```shell
sudo bash ./disco.sh setup-docker
sudo bash ./disco.sh enter-docker
```

### Inside the Docker

```shell
cd /coclo
./disco.sh create-nfs 10000  # size in GB
```

If the initial NFS size proves insufficient as you run many workflows,
you can add extra storage capacity to your NFS server via:

```shell
# Default size in GB; new disk name will be $NFS_SEVER_NAME-$RANDOM
./disco.sh add-disk-to-nfs 5000  # size in GB

# or explicitly name your new disk via:
./disco.sh add-disk-to-nfs 5000 name-for-my-new-disk
```

Next, we want to start all the services and mount the storage space:

```shell
./disco.sh start-all
```

You should now be in a screen session with four windows.

- 0: `Ketrew-server`
- 1: `Coclobas-server`
- 2: `Sudo-tlstunnel`
- 3: `bash`

You will be in the `bash` window. 
*Note: you can move between `screen` windows with `C-a window-number` 
(control+a and the number of the window you want to switch to).*

The first time the Coclobas server is started, it needs to create a the
Kubernetes cluster. This may take about 5-10 minutes; you can check its status
with `./disco.sh cluster-status`.

If it says `Initializing` wait a bit and try again, if it says `Ready`, we can
go on to the next step.

You can visit the Google Container Engine WebUI watch your cluster being
created in the "Instance Group" tab.

#### Note About Letting the Servers Live

If you need to log out of the GCloud box, you want to leave the Docker container
running. There are two ways to accomplish this.

1. You can use `Ctrl-p Ctrl-q` to detach from Docker (and then `sudo docker ps`
   / `sudo docker attach <id>` to reattach).
2. You can run erverything inside tmux (just start tmux before running `./disco.sh enter-docker`).

## Running Epidisco

### Installing Epidisco

We'll need to install and configure Epidisco, done with:

```shell
./disco.sh setup-epidisco
```

Now we're ready to run Epidisco on our new elastic cluster.

You can now submit a job running on example data with the below invocation (also
done with `./disco.sh submit-test`).

```shell
source configuration.env
KETREW_CONFIGURATION=_kclient_config/configuration.ml \
    DREAM=https://storage.googleapis.com/dream-challenge \
    ocaml run_pipeline.ml pipeline \
       --normal $DREAM/synthetic.challenge.set2.normal.bam \
       --tumor $DREAM/synthetic.challenge.set2.tumor.bam \
       --reference-build b37 \
       --results-path $BIOKEPI_WORK_DIR/results/ \
       -E My-first-epidisco-party
```

If you'd like to submit with your own data, you can inspect the options of
 Epidisco with `ocaml run_pipeline.ml pipeline --help`.

You can watch the run execute through the Ketrew Web UI found at `./disco.sh
ketrew-ui`; the result of the run can be found in `$BIOKEPI_WORK_DIR/results`.

### Adding more NFS servers to make simultaneous Epidisco runs efficient

If you are planning to run more than 2-3 epidisco workflows on the same cluster,
the default single-node NFS server can easily become a bottleneck for all jobs,
where each epidisco workflow will end up competing for the NFS resources and
this will dramatically slow all workflows down.

To overcome this issue, you can add more NFS servers to the Epidisco setup
and let each workflow use a separate NFS as a working directory. The following
command, for example, will create a new NFS server with 1TB storage and mount
it to `/nfs-pool2/`:

```
# Run this inside the server docker image (post: `start-all`)
# Size: 1000 GB = 1 TB
./disco.sh add-new-nfs name-for-my-new-nfs 1000 /nfs-pool2
```

and you can then set this folder as your working directory:

```
# Use tools, reference, and cache data from the main NFS server
# but make use of the new NFS server for the current job
# and save results back to the main NFS server.
ORIGINAL_WORK_DIR=$BIOKEPI_WORK_DIR \
BIOKEPI_WORK_DIR=/nfs-pool2/biokepi/ \
INSTALL_TOOLS_PATH=$ORIGINAL_WORK_DIR/toolkit \
PYENSEMBL_CACHE_DIR=$ORIGINAL_WORK_DIR/pyensembl-cache \
REFERENCE_GENOMES_PATH=$ORIGINAL_WORK_DIR/reference-genome \
    ocaml run_pipeline.ml pipeline \
      --results-path $ORIGINAL_WORK_DIR/results/ \
      --normal ...
```

the information on this new NFS will be saved into your `configuration.env`
and when you re-`start-all` the epidisco, the additional NFS storage will
automatically mounted if it has not been at the time of the operation.
