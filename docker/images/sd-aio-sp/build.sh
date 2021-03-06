#!/bin/bash
# Docker build wrapper

set -e

################################################################################
# Configuration
################################################################################

ISO_MOUNT_POINT=iso

# Name for the image to be built
IMGNAME=sd-aio-sp

# SD version the image is based on
SDVERSION=2.8.2

# Base tag name
BASETAG=${BASETAG:-latest}

# Whether to include 1st run setup as part of the image
DEFAULT_PREPARED=false
PREPARED=${PREPARED:-$DEFAULT_PREPARED}

# Whether to not use cache when building the image
NOCACHE=${NOCACHE:-false}

# Whether to generate a squashed version of the image
SQUASH=${SQUASH:-false}

# Whether to tag the built image
TAG=${TAG:-true}

# Whether to generate a squashed version of the image
IDFILE=${IDFILE:-}

# Path to distfiles file
DISTFILES=${DISTFILES:-./distfiles}

# Proxy configuration
# Will use current environment configuration if available
HTTP_PROXY=${HTTP_PROXY:-}
HTTPS_PROXY=${HTTPS_PROXY:-$HTTP_PROXY}
NO_PROXY=${NO_PROXY:-}
http_proxy=${http_proxy:-$HTTP_PROXY}
https_proxy=${https_proxy:-$HTTPS_PROXY}
no_proxy=${no_proxy:-$NO_PROXY}

################################################################################
# Functions
################################################################################

function fetch_distfile {
    local d=$1
    local s=$2
    echo "Trying to fetch '$d' from '$s'..."
    if [[ $s =~ ^http(s)?://.+ ]]; then
        curl $s -o $d
    elif [[ $s =~ ^iso://(.+) ]]; then
        local p="${BASH_REMATCH[1]}"
        cp -v $ISO_MOUNT_POINT/$p $d
    else
        echo "Unknown source type in '$s', cannot fetch"
        exit 1
    fi
}

function check_distfile {
    local d=$1
    local p=$2
    local s=$3
    echo $d $p | sha1sum -c -- || {
        if [[ -z $s ]]; then
            echo "No source specified for '$p', cannot fetch"
            exit 1
        fi
        fetch_distfile $p $s
        echo $d $p | sha1sum -c --
    }
}

function check_distfiles {
    if [[ ! -f "$DISTFILES" ]]; then
        return
    fi

    echo "Checking distfiles..."

    while read line; do
        check_distfile $line
    done < "$DISTFILES"

    echo
}

function cleanup_distfiles {
    if [[ ! -f "$DISTFILES" ]]; then
        return
    fi

    echo "Cleaning up distfiles..."

    local tmp=$(mktemp -d)
    awk '{ print $2 }' "$DISTFILES" | sort -u > $tmp/expected
    find kits -type f | sort -u > $tmp/found
    for f in $(comm -3 $tmp/expected $tmp/found); do
        rm -v $f
    done
    rm -fr $tmp
    echo
}

function check_iso {
    if ! stat \
        $ISO_MOUNT_POINT/AutomaticInstallation/roles \
        $ISO_MOUNT_POINT/Binaries/Components/Linux \
        $ISO_MOUNT_POINT/Binaries/EmbeddedProducts/UOC/Linux \
        > /dev/null 2>&1 ;
    then
        echo "Could not find the expected SD ISO contents."
        echo "Make sure ISO is mounted/extracted into the 'iso' directory."
        exit 1
    fi
}

function check_ansible {
    if [[ ! -d ansible/roles ]]
    then
        echo "Could not find roles in the product Ansible repo."
        echo "Make sure you have properly initialized submodules."
        echo
        echo "In order to initialize submodules issue the following commands:"
        echo
        echo "  - git submodule init"
        echo "  - git submodule update"
        echo
        echo "Then try building the image again."
        exit 1
    fi
}

function add_arg {
    build_args+=("$@")
}

################################################################################
# Main
################################################################################

# Ensure required directories exist
mkdir -p kits iso

# Check ISO is mounted
check_iso

# Check dist files are available
check_distfiles

# Cleanup unnecessary dist files
cleanup_distfiles

# Disable squashing if not available
if [[ $SQUASH == true ]]; then
    experimental=$(docker version --format '{{.Server.Experimental}}')
    if [[ $experimental != true ]]; then
        echo "WARNING: Squashing images requires enabling experimental features for the Docker daemon."
        echo "More information here: https://docs.docker.com/engine/reference/commandline/dockerd/#description"
        echo
        echo "Squashing will be disabled now."
        SQUASH=false
    fi
fi


build_args=()

# Discard build cache if NOCACHE is specified
if [[ $NOCACHE == true ]]; then
    add_arg --no-cache
fi

# Save built image id to $IDFILE if specified
if [[ -n $IDFILE ]]; then
    idfile=$IDFILE
else
    idfile=$(mktemp)
fi
add_arg --iidfile $idfile

# Add VCS reference if available
if git describe --always 2>&1 > /dev/null; then
    ref=$(git describe --tags --always --dirty)
    add_arg --label "org.label-schema.vcs-ref=$ref"
fi

# Add build args for proxy environment variables
# This enables Internet access behind corporate proxy for intermediate containers
for v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
    if [[ -v $v ]]; then
        add_arg --build-arg "$v=${!v}"
    fi
done

add_arg --build-arg prepared=$PREPARED

# Build
docker build "${build_args[@]}" .
id=$(cat $idfile)
id_nonsquashed=$id

# Squash
if [[ $SQUASH == true ]]; then
    docker build "${build_args[@]}" --squash .
    id=$(cat $idfile)
    id_squashed=$id
fi

# Remove ID file if not explicit
if [[ -z $IDFILE ]]; then
    rm -f $idfile
fi

if [[ $TAG == true ]]; then

# Tag image
if [[ $BASETAG == latest ]]; then
    docker tag $id $IMGNAME:$BASETAG
    tag_prefix=$SDVERSION
else
    tag_prefix=$BASETAG
fi

if [[ $PREPARED == true ]]; then
    tag_suffix_prep=prepared
else
    tag_suffix_prep=nonprepared
fi

docker tag $id_nonsquashed $IMGNAME:$tag_prefix-$tag_suffix_prep-nonsquashed

if [[ -n $id_squashed ]]; then
    docker tag $id_squashed $IMGNAME:$tag_prefix-$tag_suffix_prep-squashed
fi

docker tag $id $IMGNAME:$tag_prefix-$tag_suffix_prep

if [[ $PREPARED == $DEFAULT_PREPARED ]]; then
    docker tag $id $IMGNAME:$tag_prefix
fi

fi # [[ $TAG == true ]]
