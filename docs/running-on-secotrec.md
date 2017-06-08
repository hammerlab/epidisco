# Running Epidisco With Ketrew/Secotrec

## Setting Things Up

This quickstart guide will get you running Epidisco on test data (or your own)
on the GCloud platform, using Secotrec.

This is an overview of the GCloud setup system in the Epidisco universe:

![Overview Diagram](https://cloud.githubusercontent.com/assets/617111/25453955/d099d7ee-2a98-11e7-8118-5222cb845c3e.png)

### Set Up a Launch Box

We're going to set up Secotrec on a GCloud server. You'll need the GCloud command line utility, installed and initialized [from here](https://cloud.google.com/sdk/downloads#interactive).

Optionally set your preferred zone before you get started:

```shell
export GCLOUD_ZONE="us-east1-c"
```

Make a new small default GCloud box, here called `fuzzy-pgv`:
```shell
boxname="fuzzy-pgv"
gcloud compute instances create $boxname \
--image-family ubuntu-1604-lts \
--image-project ubuntu-os-cloud \
--zone $GCLOUD_ZONE \
--scopes cloud-platform \
--boot-disk-size 40GB

# We need to open the box's firewall to let HTTPS traffic through.
gcloud compute firewall-rules create https-on-$boxname \
--allow tcp:443 \
--source-tags=$boxname \
--source-ranges 0.0.0.0/0

# Do the rest of the setup on this launch box
gcloud compute ssh fuzzy-pgv --zone=$GCLOUD_ZONE

# Log into your account
gcloud auth login
```

### Set Up NFS Server


While Secotrec will automatically make an NFS server for ephemeral storage and writing the results, it can be more convenient to use a pre-existing NFS server which contains the input data and which will contain intermediate process data and final Epidisco results. Here we will assume that that's the desired setup.

First, you'll need to install `gcloudnfs`:
```shell
sudo wget https://raw.githubusercontent.com/cioc/gcloudnfs/master/gcloudnfs -O/usr/bin/gcloudnfs
sudo chmod a+rx /usr/bin/gcloudnfs
```
(Edit the Python path in the file as needed, if working with virtual envs. See https://github.com/cioc/gcloudnfs for more notes.)

Make a new NFS server for use with secotrec/epidisco, let's call it `fuzzy-nfs`:
```shell
gcloudnfs create \
--zone us-east1-d \
--network default \
--machine-type n1-standard-1 \
--server-name fuzzy-nfs \
--data-disk-name fuzzy-nfs-disk \
--data-disk-type pd-standard \
--data-disk-size 2000 \
--project pici-1286
```

On that machine, make a witness file:
```shell
gcloud compute ssh fuzzy-nfs --zone us-east1-d
touch /nfs-pool/witness.txt
```

If you discover that you need more NFS space, you can resize the server. In this example, we're going to add a 7TB disk called `fuzzy-nfs-disk3` (a name you can make up) to the storage pool (see https://github.com/hammerlab/projects/blob/master/tutorials/gcloud-setup.md#increasing-the-size-of-the-nfs-storage for reference):

```shell
export MAIN_NFS_SERVER=fuzzy-nfs
export ADD_NFS_SIZE=7000 # in GBs
export NEW_DISK_NAME=fuzzy-nfs-disk3
export GCLOUD_ZONE=us-east1-d
export ZPOOL_NAME=nfs-pool

# Create the disk
gcloud compute disks create $NEW_DISK_NAME --size $ADD_NFS_SIZE --type "pd-standard" --zone $GCLOUD_ZONE

# Attach it pseudo-physically to the main NFS VM
gcloud compute instances attach-disk $MAIN_NFS_SERVER --disk $NEW_DISK_NAME --device-name $NEW_DISK_NAME --zone $GCLOUD_ZONE

# Add this new disk to the ZFS POOL to expand the pool
gcloud compute ssh --zone $GCLOUD_ZONE $MAIN_NFS_SERVER -- sudo zpool add -f $ZPOOL_NAME /dev/disk/by-id/google-$NEW_DISK_NAME
```

### Secotrec Pre-requisites

You will need to install opam on this box:

```shell
sudo apt-get install opam
opam init
eval `opam config env`
```

Secotrec will need a newer ocaml version than what comes pre-installed, so you will need to do:
```
opam switch 4.03.0
eval `opam config env`
```

### Install Secotrec

For a detailed description of Secotrec, see [the README](https://github.com/hammerlab/secotrec).

We need to pin a few packages:

```shell
opam pin -n add ketrew https://github.com/hammerlab/ketrew.git
opam pin -n add biokepi https://github.com/hammerlab/biokepi.git
opam pin -n add secotrec https://github.com/hammerlab/secotrec.git
opam pin -n add epidisco https://github.com/hammerlab/epidisco.git
```

You may get a message like "Package secotrec does not exist, create as a NEW package ? [Y/n]" Hit Y to continue.

```shell
opam upgrade
opam install tls secotrec biokepi epidisco
```

You may get some dependency-related error messages. Run whatever `opam depext` commands it asks for, and retry the `opam install` command.

### Create the Configuration

Generate a template configuration file:

```shell
secotrec-gke generate-configuration my-config.env
```

Make the following changes in the resulting `my-config.env`:

- Set `prefix` to something unique, e.g. "fuzzypgv"
- Set `gcloud_zone` to us-east1-d or us-east1-c.
- Set `gcloud_dns_zone` to hammerlab-gcloud.
- Set `dns_suffix` to gcloud.hammerlab.org.
- Set `certificate_email` to your @hammerlab email.
- Set `auth_token` to some value other than the default in the config. Easiest to add a unique suffix.
- Set `cluster_max_nodes` to 40 for some more power, e.g. to be able to run multiple analyses.
- Set `ALLOW_DAEMONIZE` to false.
- Add external tool links for these tools to the bottom of the config (you will need to have access to these for the pipeline to work):
```shell
GATK_JAR_URL
MUTECT_JAR_URL
NETMHC_TARBALL_URL
NETMHCPAN_TARBALL_URL
PICKPOCKET_TARBALL_URL
NETMHCCONS_TARBALL_URL
```
- By default, Secotrec will make a new NFS server and keep the results there. If you have an existing NFS server you want to use (see above for instructions on making a new NFS server):
  - Do something like this with `nfs_mounts`: `export nfs_mounts='fuzzy-nfs,/nfs-pool,.tmp/witness,/mnt/fuzzy-nfs`. In this case, best to set the mount point to something you're already using as the mount point for that NFS server on some other machine, if you want to be able to easily copy/paste paths from the Ketrew UI for looking at the data.
  - Set `BIOKEPI_WORK_DIR` to something relative to your mount point, like `/mnt/fuzzy-nfs/biokepi-work-dir`.

### Deploy

```shell
# This takes about 15 minutes.
. my-config.env
secotrec-gke up
```

Check that everything is okay and that the NFS mounts are what you expect:
```shell
secotrec-gke status
```

Run the test job and watch on the Ketrew UI to make sure everything is sane
```shell
secotrec-gke test-biokepi-machine
```

### Epidisco preparation

This next bit will only work for Hammerlab members, but you can do something similar.

Clone the PGV001 repo:
```shell
git clone https://github.com/hammerlab/pgv001.git
cd pgv001
```

Generate a biokepi machine; look at it for a sanity check, then copy to current directory
```shell
secotrec-gke ketrew-configuration ~/.ketrew/
secotrec-gke biokepi-machine /tmp/bm.ml
cp /tmp/bm.ml biokepi_machine.ml   # the script relies on a file by this name
```

There is a template OCaml script for starting an Epidisco job, `pt006.ml`. Let's assume you have another GCloud instance somewhere that you use for analysis, called "fuzzy", where you've mounted an NFS containing your Epidisco input data. This same NFS can optionally be used for containing Epidisco output (see above section on how to modify `my-config.env` to use your own NFS server).
- host_name: `ssh://fuzzy`
- results_path: `/mnt/fuzzy-nfs/pgv/results`. Make sure this directory is world-writeable.
- set `to_email` if desired
- edit the tumor/normal/RNA paths and sample names, which are relative to the NFS mount. These paths should work on the `fuzzy` dev box.

### Set up passwordless SSH

You will need to set up passwordless SSH from the Epidisco launch box to the SSH host you specified in `pt-006.ml`. A couple steps involved in this:

On `fuzzy-pgv`, generate a public/private key pair:
```shell
ssh-keygen -b 1024 -t rsa -f id_rsa -P ""
```

Copy `id_rsa` to `~/.ssh` and make an `~/.ssh/config` file:
```shell
Host fuzzy
  HostName fuzzy
  IdentityFile "~/.ssh/id_rsa"
  User <your username>
```

SSH into the `fuzzy` dev box and copy the contents of the resulting `id_rsa.pub` to `~/.ssh/authorized_keys`.

Test that this setup works by trying to SSH directly into `fuzzy` from the `fuzzy-pgv` launchbox: `ssh fuzzy` should now work.

### Run All the Things

To run the script (make sure to reload the config before restarting as needed, just in case):
```shell
. my-config.env
ocaml pgv001/pt006.ml
```

### Debugging from the Secotrec box

```shell
gcloud compute ssh fuzzypgv-secobox
sudo docker ps

# Find the container ID for coclotest_kserver_1, e.g. 123:
sudo docker exec -i -t 123 /bin/bash
```

This will drop you into a bash shell from which you can look at the files, look at the NFS mount, etc.
