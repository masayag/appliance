#!/bin/bash
set -x

function patch_openshift_install_release_version() {
    local version=$1
    local res=$(grep -oba ._RELEASE_VERSION_LOCATION_.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX bin/openshift-install)
    local location=${res%%:*}

    # If the release marker was found then it means that the version is missing
    if [[ ! -z ${location} ]]; then
        echo "Patching openshift-install with version ${version}"
        printf "${version}\0" | dd of=bin/openshift-install bs=1 seek=${location} conv=notrunc &> /dev/null 
    else
        echo "Version already patched"
    fi
}

function patch_openshift_install_release_image() {
    local image=$1
    local res=$(grep -oba ._RELEASE_IMAGE_LOCATION_.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX bin/openshift-install)
    local location=${res%%:*}

    # If the release marker was found then it means that the image is missing
    if [[ ! -z ${location} ]]; then
        echo "Patching openshift-install with image ${image}"
        printf "${image}\0" | dd of=bin/openshift-install bs=1 seek=${location} conv=notrunc &> /dev/null 
    else
        echo "Image already patched"
    fi
}

release_image=quay.io/openshift-release-dev/ocp-release:4.12.4-x86_64
release_version=$(oc adm release info -o template --template '{{.metadata.version}}' --insecure=true ${release_image})

patch_openshift_install_release_version $release_version
patch_openshift_install_release_image $release_image

