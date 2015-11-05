#!/bin/bash

set -e
set -x

MYSELF=`basename $0`
MY_DIR=`echo $(cd $(dirname $0); pwd)`

pushd `pwd`
pushd $MY_DIR

. $MY_DIR/settings.sh

if [ ! -d $OUTPUT_DIRECTORY ]; then
  git checkout $OUTPUT_DIRECTORY
fi

# Ensure that local clones also track any required upstream packaging branches.
# If they don't then the subsequent git clones in the VM, which are cloned from
# this local clone, will fail with errors such as:
#
#     fatal: Cannot update paths and switch to branch 'rpm-1.0' at the same time.
#     Did you intend to checkout 'origin/rpm' which can not be resolved as commit?
#
# This is because after `git clone /vagrant/ kafka-platform` in the VM, the VM's
# origin is pointing # to the local clone (not upstream's origin), and the local
# clone may not yet track the upstream branches such as `origin/rpm`.
for remote_branch in rpm debian confluent-platform; do
  echo "Tracking remote branch '$remote_branch'"
  git branch -d $remote_branch || true
  git branch --track $remote_branch origin/$remote_branch
done

pushd repos
for REPO in $KAFKA_REPO \
    $KAFKA_PACKAGING_REPO \
    $COMMON_REPO \
    $REST_UTILS_REPO \
    $SCHEMA_REGISTRY_REPO \
    $KAFKA_REST_REPO \
    $CAMUS_REPO; do
    REPO_DIR=`basename $REPO`
    if [ ! -e $REPO_DIR ]; then
        # Using mirror makes sure we get copies of all the branches. It also
        # uses a bare repository, which works fine since we want to force the
        # build scripts to copy to a temp directory in the VM anyway in order to
        # avoid cluttering up this directory with build by-products.
        git clone --mirror $REPO
    else
        pushd $REPO_DIR
        git fetch --tags
        popd
    fi
done
popd


if [ "x$SIGN" == "xyes" ]; then
    if [ "x$SIGN_KEY" == "x" ]; then
        SIGN_KEY=`gpg --list-secret-keys | grep uid | sed -e s/uid// -e 's/^ *//' -e 's/ *$//'`
    fi

    cat <<EOF > .rpmmacros
%_signature gpg
%_gpg_path /root/.gnupg
%_gpg_name $SIGN_KEY
%_gpgbin /usr/bin/gpg
EOF
    vagrant ssh rpm -- sudo cp /vagrant/.rpmmacros /root/.rpmmacros
    rm .rpmmacros
fi

## KAFKA ##
vagrant ssh rpm -- cp /vagrant/build/kafka-archive.sh /tmp/kafka-archive.sh
vagrant ssh rpm -- sudo VERSION=$KAFKA_VERSION REVISION=$REVISION BRANCH=$KAFKA_BRANCH "SCALA_VERSIONS=\"$SCALA_VERSIONS\"" /tmp/kafka-archive.sh
vagrant ssh rpm -- cp /vagrant/build/kafka-rpm.sh /tmp/kafka-rpm.sh
vagrant ssh rpm -- -t sudo VERSION=$KAFKA_VERSION REVISION=$REVISION BRANCH=$KAFKA_BRANCH "SCALA_VERSIONS=\"$SCALA_VERSIONS\"" SIGN=$SIGN /tmp/kafka-rpm.sh
vagrant ssh deb -- cp /vagrant/build/kafka-deb.sh /tmp/kafka-deb.sh
vagrant ssh deb -- -t sudo VERSION=$KAFKA_VERSION REVISION=$REVISION BRANCH=$KAFKA_BRANCH "SCALA_VERSIONS=\"$SCALA_VERSIONS\"" SIGN=$SIGN /tmp/kafka-deb.sh

## CONFLUENT PACKAGES ##
for PACKAGE in $CP_PACKAGES; do
    PACKAGE_BRANCH_VAR="${PACKAGE//-/_}_BRANCH"
    PACKAGE_BRANCH="${!PACKAGE_BRANCH_VAR}"
    if [ -z "$PACKAGE_BRANCH" ]; then
        PACKAGE_BRANCH="$BRANCH"
    fi

    PACKAGE_SKIP_TESTS_VAR="${PACKAGE//-/_}_SKIP_TESTS"
    PACKAGE_SKIP_TESTS="${!PACKAGE_SKIP_TESTS_VAR}"
    if [ -z "$PACKAGE_SKIP_TESTS" ]; then
        PACKAGE_SKIP_TESTS="$SKIP_TESTS"
    fi

    vagrant ssh rpm -- cp "/vagrant/build/${PACKAGE}-archive.sh" "/tmp/${PACKAGE}-archive.sh"
    vagrant ssh rpm -- sudo VERSION=$CONFLUENT_VERSION REVISION=$REVISION BRANCH=$PACKAGE_BRANCH SKIP_TESTS=$PACKAGE_SKIP_TESTS "/tmp/${PACKAGE}-archive.sh"
    vagrant ssh rpm -- cp "/vagrant/build/${PACKAGE}-rpm.sh" "/tmp/${PACKAGE}-rpm.sh"
    vagrant ssh rpm -- -t sudo VERSION=$CONFLUENT_VERSION REVISION=$REVISION BRANCH=$PACKAGE_BRANCH SKIP_TESTS=$PACKAGE_SKIP_TESTS SIGN=$SIGN "/tmp/${PACKAGE}-rpm.sh"
    vagrant ssh deb -- cp "/vagrant/build/${PACKAGE}-deb.sh" "/tmp/${PACKAGE}-deb.sh"
    vagrant ssh deb -- -t sudo VERSION=$CONFLUENT_VERSION REVISION=$REVISION BRANCH=$PACKAGE_BRANCH SKIP_TESTS=$PACKAGE_SKIP_TESTS SIGN=$SIGN "/tmp/${PACKAGE}-deb.sh"
done


## CONFLUENT PLATFORM PACKAGES ##
# These are also specific to the Scala version so they can't use the standard
# loop above. Note that we also don't have an archive version. Those are handled
# in the compiled packages section below. This step is only used to generate
# system-level dependency packages to make the entire platform easy to
# install. Finally, note that the BRANCH env variable isn't set for these --
# there is no point since they have one fixed branch that they build from (rpm
# or debian, stored in this repository).
vagrant ssh rpm -- cp /vagrant/build/platform-rpm.sh /tmp/platform-rpm.sh
vagrant ssh rpm -- -t sudo VERSION=$CONFLUENT_VERSION REVISION=$REVISION "SCALA_VERSIONS=\"$SCALA_VERSIONS\"" KAFKA_VERSION=$KAFKA_VERSION SIGN=$SIGN /tmp/platform-rpm.sh
vagrant ssh deb -- cp /vagrant/build/platform-deb.sh /tmp/platform-deb.sh
vagrant ssh deb -- -t sudo VERSION=$CONFLUENT_VERSION REVISION=$REVISION "SCALA_VERSIONS=\"$SCALA_VERSIONS\""  KAFKA_VERSION=$KAFKA_VERSION SIGN=$SIGN /tmp/platform-deb.sh



## COMPILED PACKAGES ##
OUTPUT="${MY_DIR}/output"

rm -rf /tmp/confluent-packaging
mkdir -p /tmp/confluent-packaging
pushd /tmp/confluent-packaging

# zip/tar.gz
for SCALA_VERSION in $SCALA_VERSIONS; do
    mkdir "confluent-${CONFLUENT_VERSION}"
    pushd "confluent-${CONFLUENT_VERSION}"
    tar -xz --strip-components 1 -f "${OUTPUT}/confluent-kafka-${KAFKA_VERSION}-${SCALA_VERSION}.tar.gz"
    for PACKAGE in $CP_PACKAGES; do
        tar -xz --strip-components 1 -f "${OUTPUT}/confluent-${PACKAGE}-${CONFLUENT_VERSION}.tar.gz"
    done
    cp ${MY_DIR}/installers/README.archive .
    popd
    tar -czf "${OUTPUT}/confluent-${CONFLUENT_VERSION}-${SCALA_VERSION}.tar.gz" "confluent-${CONFLUENT_VERSION}"
    zip -r "${OUTPUT}/confluent-${CONFLUENT_VERSION}-${SCALA_VERSION}.zip" "confluent-${CONFLUENT_VERSION}"
    rm -rf "confluent-${CONFLUENT_VERSION}"
done

# deb/rpm
for SCALA_VERSION in $SCALA_VERSIONS; do
    for PKG_TYPE in "deb" "rpm"; do
        mkdir "confluent-${CONFLUENT_VERSION}"
        pushd "confluent-${CONFLUENT_VERSION}"
        # Getting the actual filenames is a pain because of the version number
        # mangling. We just use globs to find them instead, but this means you
        # *MUST* work with a clean output/ directory
        eval "cp ${OUTPUT}/confluent-kafka-${SCALA_VERSION}*.${PKG_TYPE} ."
        for PACKAGE in $CP_PACKAGES; do
            eval "cp ${OUTPUT}/confluent-${PACKAGE}*.${PKG_TYPE} ."
        done
        cp ${MY_DIR}/installers/install.sh .
        cp ${MY_DIR}/installers/README .
        popd
        tar -czf "${OUTPUT}/confluent-${CONFLUENT_VERSION}-${SCALA_VERSION}-${PKG_TYPE}.tar.gz" "confluent-${CONFLUENT_VERSION}"
        rm -rf "confluent-${CONFLUENT_VERSION}"
    done
done

popd
rm -rf /tmp/confluent-packaging

popd
