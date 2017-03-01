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
    gcloud compute copy-files $script $boxname:~ --zone $GCLOUD_ZONE
}

get-external-ip () {
    local boxname=$1
    if [[ -z "$boxname" ]]; then
        boxname=$(hostname)
    fi
    local desc="gcloud compute instances describe $boxname --zone $GCLOUD_ZONE"
    local ip=$($desc | grep natIP | cut -d ':' -f 2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    echo $ip
}

random-string () {
    local length=$1
    if [[ -z "$length" ]]; then
        length=32
    fi
    cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1
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

## Default ketrew configuration location
export KETREW_CONFIGURATION=/coclo/_kclient_config/configuration.ml

EOF
    echo "Created ./configuration.env"
}

# meant to be sudo-executed
setup-docker () {
    local path="`dirname \"$0\"`"
    local path="`( cd \"$path\" && pwd )`"
    local script="$path/${0##*/}"
    apt-get install -y docker.io
    docker pull hammerlab/coclobas:with-ketrew-300
    mkdir -p /coclo
    chmod 777 /coclo
    cp configuration.env /coclo
    cp $script /coclo
    chmod -R 777 /coclo
    echo "Copied configuration.env and disco.sh to /coclo"
}

# meant to be sudo-executed
# - `--privileged` is for NFS mounting
# - `-p 443:443` is to pass the port 443 to the container
enter-docker () {
    # Make sure IP hasn't changed since last time we enter this docker,
    # which can happen when gbox is cloned or restarted.
    local cip=$(cat /coclo/configuration.env |grep "^export EXTERNAL_IP" |cut -d"=" -f2)
    local boxname=$(hostname)
    local eip=$(get-external-ip $boxname)

    if [[ "$cip" != "$eip" ]]; then
        echo "ERROR: Looks like your host has a different IP address" \
            "than your configured one in '/coclo/configuration.env'" \
            "(Current IP: $eip | Configured IP: $cip)." \
            "Please update your configuration and repeat this step."
        exit 1
    fi

    echo "Mounting local /coclo to Docker's /coclo"
    echo "cd to /coclo to get access to your config and disco.sh"
    echo "...entering the Docker!"
    docker run -it -p 443:443 -v /coclo:/coclo \
           --privileged hammerlab/coclobas:with-ketrew-300 bash
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

get-project-name () {
    local project=$(curl "http://metadata.google.internal/computeMetadata/v1/project/project-id" \
            -H "Metadata-Flavor: Google" 2>/dev/null)
    echo $project
}

new-nfs () {
    local server_name=$1
    local size=$2
    local mount_point=$3

    local project=$(get-project-name)
    source /coclo/configuration.env

    # This utility (https://github.com/cioc/gcloudnfs) is pre-installed on the
    # Docker image.
    gcloudnfs create --zone $GCLOUD_ZONE --project $project \
              --network default --machine-type n1-standard-1 \
              --server-name $server_name \
              --data-disk-name $server_name-disk --data-disk-type pd-standard \
              --data-disk-size $size
    sudo mkdir -p $mount_point
    sudo mount -t nfs $server_name:/nfs-pool $mount_point
    touch $mount_point/.witness.txt
}

create-nfs () {
    local size=$1
    source /coclo/configuration.env
    new-nfs $NFS_SERVER_NAME $size /nfs-pool
}

add-new-nfs () {
    local server_name=$1
    local size=$2
    local mount_point=$3

    new-nfs $server_name $size $mount_point
    echo "export NFS_MOUNTS=\$NFS_MOUNTS:$server_name,/nfs-pool/,.witness.txt,$mount_point" >> /coclo/configuration.env
}

add-disk-to-nfs () {
    source /coclo/configuration.env

    local size=$1
    local project=$(get-project-name)
    local new_disk_id=$2
    if [ "$new_disk_id" = "" ]
    then
        new_disk_id=$NFS_SERVER_NAME-$RANDOM
    fi

    # Create an additional disk
    gcloud compute disks create $new_disk_id \
            --zone $GCLOUD_ZONE --project $project \
            --size $size --type "pd-standard"

    # Attach it pseudo-physically to the main NFS VM
    gcloud compute instances attach-disk $NFS_SERVER_NAME \
            --disk $new_disk_id --device-name $new_disk_id \
            --zone $GCLOUD_ZONE

    # Add this new disk to the ZFS POOL to expand the pool
    gcloud compute ssh --zone $GCLOUD_ZONE $NFS_SERVER_NAME \
            -- sudo zpool add -f nfs-pool /dev/disk/by-id/google-$new_disk_id
}

fill-up-cache () {

    local url=$1
    local dir=$2
    if [ "$url" = "" ] || [ "$dir" = "" ] ; then
        echo "Usage: $0 fill-up-cache <GCloud-Bucket-URL> <directory-to-fill>"
        return 2
    fi

    source /coclo/configuration.env

    echo "Getting a precomputed $dir from $url"
    mkdir -m a+rwx -p $BIOKEPI_WORK_DIR/4dir

    sudo apt-get install -y gcc python-dev python-setuptools
    sudo easy_install -U pip
    sudo pip install -U crcmod

    gsutil -m cp $url \
        $BIOKEPI_WORK_DIR/$dir/$(basename $url)

    ( cd $BIOKEPI_WORK_DIR/$dir/ ; tar xvfz $(basename $url) )
    chmod -R 777 /nfs-pool/
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
    wget -O /coclo/biokepi_machine.ml https://raw.githubusercontent.com/hammerlab/coclobas/master/tools/docker/biokepi_machine.ml
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
    local path=$3
    if [[ -z "$results_directory" ]]; then
        echo "Results directory requires ($1)"
        exit 2
    fi
    if [[ -z "$" ]]; then
        echo "Bucket required ($2)"
        exit 2
    fi
    if [[ -z "$path" ]]; then
        echo "Path not set, creating random path"
        path=$(random-string 64)
    fi
    local res=gs://$bucket/$path
    gsutil -m -h "Cache-Control:private" rsync -r $results_directory $res
    gsutil -m acl ch -r -g AllUsers:R $res
    echo "Created bucket at $res"
}

$*
