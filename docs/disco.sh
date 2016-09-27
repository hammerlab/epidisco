set -e
set -o pipefail

################################################################################
# Some optional settings for this script are found and documented below.       #
################################################################################

# Size of the boot disk for the GCloud launch box, in GB
if [[ -z "$BOX_BOOT_DISK_SIZE" ]] ; then
    BOX_BOOT_DISK_SIZE=40
fi

# Zone which compute nodes will be deployed on.
if [[ -z "$GCLOUD_ZONE" ]] ; then
    GCLOUD_ZONE="us-east1-c"
fi

# Number of compute nodes in the deployed cluster.
if [[ -z "$CLUSTER_MAX_NODES" ]] ; then
    CLUSTER_MAX_NODES=15
fi


if [[ "$#" == "0" ]]; then
    cat <<EOF
USAGE

$0 is used to easily set up a GCloud box with some default settings.

You must have the gcloud CLI tool installed and configured.
EOF
    exit 1
fi

create () {
    local boxname="$1"; shift
    local path="`dirname \"$0\"`"
    local path="`( cd \"$path\" && pwd )`"
    local script="$path/${0##*/}"
    # We make a small default box on which we will run our Docker image
    # containing the Ketrew and Coclobas servers
    gcloud compute instances create $boxname \
           --image-family ubuntu-1604-lts --image-project ubuntu-os-cloud \
           --zone $GCLOUD_ZONE --scopes cloud-platform --boot-disk-size ${BOX_BOOT_DISK_SIZE}GB
    # We need to open the box's firewall to let HTTPS traffic through.
    gcloud compute firewall-rules create https-on-$boxname --allow tcp:443 \
           --source-tags=$boxname --source-ranges 0.0.0.0/0
    # Next we copy this script onto the newly-created box, so we can use it there
    gcloud compute copy-files $script $boxname:~
}

get-external-ip () {
    local boxname=$(hostname)
    local desc="gcloud compute instances describe $boxname"
    local ip=$($desc | grep natIP | cut -d ':' -f 2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    echo $ip
}

random-string () {
    cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1 | echo
}

configure () {
    local boxname=$(hostname)
    local nfsserver=$boxname-nfs
    local externalip=$(get-external-ip)
    local token=$(random-string)
    cat <<EOF > configuration.env
## Template for Configuring Ketrew with Coclobas scripts

## Set the name of the cluster you want to manage:
export CLUSTER_NAME=$boxname-cluster
export NFS_SERVER_NAME=$nfsserver

export EXTERNAL_IP=$externalip

## Set the gcloud zone
export GCLOUD_ZONE=$GCLOUD_ZONE

## Choose an authentication token for the Ketrew server:
export TOKEN=$token

## Number of compute nodes in the deployed cluster:
export CLUSTER_MAX_NODES=$CLUSTER_MAX_NODES

## Description of the NFS services that we want the containers to mount
##
## A :-separated list of ,-separated 4-tuples
##
## Each tuple is:  <nfs-server-vm>,<nfs-remote-path>,<witnessfile>,<mount-point>
##
## - <nfs-server-vm> is the instance name
## - <nfs-remote-path> is the path on the server that we want to mount
## - <witness-file> is a relative path to a file that should exist on the mount (used for verification)
## - <mount-point> is the path where we mount the NFS service (on all cluster nodes)

export NFS_MOUNTS=$nfsserver,/nfs-pool/,.witness.txt,/nfs-pool

## Variables used in the biokepi_machine.ml script:

##  Biokepi configuration requires a few directories shared accross the cluster:
## $BIOKEPI_WORK_DIR is mandatory;
export BIOKEPI_WORK_DIR=/nfs-pool/biokepi/

# Optional
## INSTALL_TOOLS_PATH is optional (default is $BIOKEPI_WORK_DIR/toolkit):
# export INSTALL_TOOLS_PATH=/nfs-constants/biokepi-software/
## PYENSEMBL_CACHE_DIR is optional (default is $BIOKEPI_WORK_DIR/pyensembl-cache):
# export PYENSEMBL_CACHE_DIR=/nfs-constants/biokepi-pyensemble-cache/
## REFERENCE_GENOMES_PATH is optional (default is $BIOKEPI_WORK_DIR/reference-genome)
# export REFERENCE_GENOMES_PATH=/nfs-constants/biokepi-ref-genomes/
## ALLOW_DAEMONIZE is optional (default: false)
## if true some nodes (such as downloads or moving data around) will run with
## daemonize backend (i.e. on the server/docker container).
# export ALLOW_DAEMONIZE=true

## DOCKER_IMAGE is optional (default: hammerlab/biokepi-run):
## The docker image to use for the Kubernetes jobs
# export DOCKER_IMAGE=something/this:that

## Usual Biokepi variables used to download Broad software:
# export GATK_JAR_URL="http://example.com/GATK.jar"
# export MUTECT_JAR_URL="http://example.com/Mutect.jar"
EOF
    echo "Created ./configuration.env"
}

# meant to be sudo-executed
setup-docker () {
    local path="`dirname \"$0\"`"
    local path="`( cd \"$path\" && pwd )`"
    local script="$path/${0##*/}"
    apt-get install -y docker.io
    docker pull hammerlab/coclobas
    mkdir -p /tmp/coclo
    chmod 777 /tmp/coclo
    cp configuration.env /tmp/coclo
    cp $script /tmp/coclo
    echo "Copied configuration.env and disco.sh to /tmp/coclo"
}

# meant to be sudo-executed
# - `--privileged` is for NFS mounting
# - `-p 443:443` is to pass the port 443 to the container
enter-docker () {
    echo "Mounting local /tmp/coclo to Docker's /coclo"
    echo "cd to /coclo to get access to your config and disco.sh"
    echo "...entering the Docker!"
    docker run -it -p 443:443 -v /tmp/coclo:/coclo \
           --privileged hammerlab/coclobas bash
}

###########################
# Inside the Docker image #
###########################

cluster-status () {
    echo $(curl http://localhost:8082/status)
}

install-epidisco () {
    opam pin add --yes biokepi "https://github.com/hammerlab/biokepi.git"
    opam pin add --yes epidisco "https://github.com/hammerlab/epidisco.git"
}

create-nfs () {
    local size=$1
    local project=$(curl "http://metadata.google.internal/computeMetadata/v1/project/project-id" \
                         -H "Metadata-Flavor: Google" 2>/dev/null)
    source /coclo/configuration.env
    # This utility (https://github.com/cioc/gcloudnfs) is pre-installed on the
    # Docker image.
    gcloudnfs create --zone $GCLOUD_ZONE --project $project \
              --network default --machine-type n1-standard-1 \
              --server-name $NFS_SERVER_NAME \
              --data-disk-name $NFS_SERVER_NAME-disk --data-disk-type pd-standard \
              --data-disk-size $size
    sudo mkdir -p /nfs-pool
    sudo mount -t nfs $NFS_SERVER_NAME:/nfs-pool /nfs-pool
    touch /nfs-pool/.witness.txt
}

create-pipeline-script () {
    cat <<EOF > run_pipeline.ml
#use "topfind";;
#thread
#require "epidisco";;

#use "biokepi_machine.ml";;

let () =
  Epidisco.Command_line.main ~biokepi_machine ()
EOF
    echo "Created ./run_pipeline.ml"

}

setup-epidisco () {
    install-epidisco
    create-pipeline-script
    wget https://raw.githubusercontent.com/hammerlab/coclobas/master/tools/docker/biokepi_machine.ml
    source configuration.env
    # EXTERNAL_IP and TOKEN both come from configuration.env
    ketrew init --conf ./_kclient_config/ --just-client https://$EXTERNAL_IP/gui?token=$TOKEN
}

submit-test () {
    source configuration.env
    if [[  -z "$GATK_JAR_URL" ]]; then
        exit "You need to set GATK_JAR_URL in your configuration.env in order to submit this job."
    fi
    if [[  -z "$MUTECT_JAR_URL" ]]; then
        exit "You need to set MUTECT_JAR_URL in your configuration.env in order to submit this job."
    fi
    DREAM=https://storage.googleapis.com/dream-challenge
    KETREW_CONFIGURATION=_kclient_config/configuration.ml \
        ocaml run_pipeline.ml pipeline \
          --normal $DREAM/synthetic.challenge.set2.normal.bam \
          --tumor  $DREAM/synthetic.challenge.set2.tumor.bam \
          --reference-build b37 \
          --results-path $BIOKEPI_WORK_DIR/results/ \
          -E My-first-epidisco-party
}

start-all () {
    # The please.sh script comes on the Docker image, and is part of Coclobas
    please.sh /coclo/configuration.env start_all
}

ketrew-ui () {
    source configuration.env
    echo https://$EXTERNAL_IP/gui?token=$TOKEN
}

publish-to-bucket () {
    local results_directory=$1
    local bucket=$2
    local path=$(random-string)
    gsutil -m -h "Cache-Control:private" rsync -r $results_directory gs://$bucket/$path
    gsutil -m acl ch -r -g AllUsers:R gs://$bucket/$path
}

$*
