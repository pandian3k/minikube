#!/bin/bash

# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# This script downloads the test files from the build bucket and makes some executable.

# The script expects the following env variables:
# OS_ARCH: The operating system and the architecture separated by a hyphen '-' (e.g. darwin-amd64, linux-amd64, windows-amd64)
# VM_DRIVER: the vm-driver to use for the test
# EXTRA_START_ARGS: additional flags to pass into minikube start
# EXTRA_ARGS: additional flags to pass into minikube
# JOB_NAME: the name of the logfile and check name to update on github

readonly TEST_ROOT="${HOME}/minikube-integration"
readonly TEST_HOME="${TEST_ROOT}/${OS_ARCH}-${VM_DRIVER}-${MINIKUBE_LOCATION}-$$-${COMMIT}"
echo ">> Starting at $(date)"
echo ""
echo "arch:      ${OS_ARCH}"
echo "build:     ${MINIKUBE_LOCATION}"
echo "driver:    ${VM_DRIVER}"
echo "job:       ${JOB_NAME}"
echo "test home: ${TEST_HOME}"
echo "sudo:      ${SUDO_PREFIX}"
echo "kernel:    $(uname -v)"
echo "uptime:    $(uptime)"
# Setting KUBECONFIG prevents the version ceck from erroring out due to permission issues
echo "kubectl:   $(env KUBECONFIG=${TEST_HOME} kubectl version --client --short=true)"
echo "docker:    $(docker version --format '{{ .Client.Version }}')"

case "${VM_DRIVER}" in
  kvm2)
    echo "virsh:     $(virsh --version)"
  ;;
  virtualbox)
    echo "vbox:      $(vboxmanage --version)"
  ;;
esac

echo ""
mkdir -p out/ testdata/

# Install gsutil if necessary.
if ! type -P gsutil >/dev/null; then
  if [[ ! -x "out/gsutil/gsutil" ]]; then
    echo "Installing gsutil to $(pwd)/out ..."
    curl -s https://storage.googleapis.com/pub/gsutil.tar.gz | tar -C out/ -zxf -
  fi
  PATH="$(pwd)/out/gsutil:$PATH"
fi

# Add the out/ directory to the PATH, for using new drivers.
PATH="$(pwd)/out/":$PATH
export PATH

echo ""
echo ">> Downloading test inputs from ${MINIKUBE_LOCATION} ..."
gsutil -qm cp \
  "gs://minikube-builds/${MINIKUBE_LOCATION}/minikube-${OS_ARCH}" \
  "gs://minikube-builds/${MINIKUBE_LOCATION}/docker-machine-driver"-* \
  "gs://minikube-builds/${MINIKUBE_LOCATION}/e2e-${OS_ARCH}" out

gsutil -qm cp -r "gs://minikube-builds/${MINIKUBE_LOCATION}/testdata"/* testdata/

gsutil -qm cp "gs://minikube-builds/${MINIKUBE_LOCATION}/gvisor-addon" testdata/


# Set the executable bit on the e2e binary and out binary
export MINIKUBE_BIN="out/minikube-${OS_ARCH}"
export E2E_BIN="out/e2e-${OS_ARCH}"
chmod +x "${MINIKUBE_BIN}" "${E2E_BIN}" out/docker-machine-driver-*
"${MINIKUBE_BIN}" version

procs=$(pgrep "minikube-${OS_ARCH}|e2e-${OS_ARCH}" || true)
if [[ "${procs}" != "" ]]; then
  echo "Warning: found stale test processes to kill:"
  ps -f -p ${procs} || true
  kill ${procs} || true
  kill -9 ${procs} || true
fi

# Quickly notice misconfigured test roots
mkdir -p "${TEST_ROOT}"

# Cleanup stale test outputs.
echo ""
echo ">> Cleaning up after previous test runs ..."
for entry in $(ls ${TEST_ROOT}); do
  test_path="${TEST_ROOT}/${entry}"
  ls -lad "${test_path}" || continue

  echo "* Cleaning stale test path: ${test_path}"
  for tunnel in $(find ${test_path} -name tunnels.json -type f); do
    env MINIKUBE_HOME="$(dirname ${tunnel})" ${MINIKUBE_BIN} tunnel --cleanup || true
  done

  for home in $(find ${test_path} -name .minikube -type d); do
    env MINIKUBE_HOME="$(dirname ${home})" ${MINIKUBE_BIN} delete --all || true
    sudo rm -Rf "${home}"
  done

  for kconfig in $(find ${test_path} -name kubeconfig -type f); do
    sudo rm -f "${kconfig}"
  done

  # Be very specific to avoid accidentally deleting other items, like wildcards or devices
  if [[ -d "${test_path}" ]]; then
    rm -Rf "${test_path}" || true
  elif [[ -f "${test_path}" ]]; then
    rm -f "${test_path}" || true
  fi
done

# sometimes tests left over zombie procs that won't exit
# for example:
# jenkins  20041  0.0  0.0      0     0 ?        Z    Aug19   0:00 [minikube-linux-] <defunct>
zombie_defuncts=$(ps -A -ostat,ppid | awk '/[zZ]/ && !a[$2]++ {print $2}')
if [[ "${zombie_defuncts}" != "" ]]; then
  echo "Found zombie defunct procs to kill..."
  ps -f -p ${zombie_defuncts} || true
  kill ${zombie_defuncts} || true
fi

if type -P virsh; then
  virsh -c qemu:///system list --all --uuid \
    | xargs -I {} sh -c "virsh -c qemu:///system destroy {}; virsh -c qemu:///system undefine {}" \
    || true
  echo ">> virsh VM list after clean up (should be empty):"
  virsh -c qemu:///system list --all || true
fi

if type -P vboxmanage; then
  killall VBoxHeadless || true
  sleep 1
  killall -9 VBoxHeadless || true

  for guid in $(vboxmanage list vms | grep -Eo '\{[a-zA-Z0-9-]+\}'); do
    echo "- Removing stale VirtualBox VM: $guid"
    vboxmanage startvm "${guid}" --type emergencystop || true
    vboxmanage unregistervm "${guid}" || true
  done

  ifaces=$(vboxmanage list hostonlyifs | grep -E "^Name:" | awk '{ print $2 }')
  for if in $ifaces; do
    vboxmanage hostonlyif remove "${if}" || true
  done

  echo ">> VirtualBox VM list after clean up (should be empty):"
  vboxmanage list vms || true
  echo ">> VirtualBox interface list after clean up (should be empty):"
  vboxmanage list hostonlyifs || true
fi


if type -P hdiutil; then
  hdiutil info | grep -E "/dev/disk[1-9][^s]" || true
  hdiutil info \
      | grep -E "/dev/disk[1-9][^s]" \
      | awk '{print $1}' \
      | xargs -I {} sh -c "hdiutil detach {}" \
      || true
fi

# cleaning up stale hyperkits
if type -P hyperkit; then
  for pid in $(pgrep hyperkit); do
    echo "Killing stale hyperkit $pid"
    ps -f -p $pid || true
    kill $pid || true
    kill -9 $pid || true
  done
fi

if [[ "${VM_DRIVER}" == "hyperkit" ]]; then
  if [[ -e out/docker-machine-driver-hyperkit ]]; then
    sudo chown root:wheel out/docker-machine-driver-hyperkit || true
    sudo chmod u+s out/docker-machine-driver-hyperkit || true
  fi
fi

kprocs=$(pgrep kubectl || true)
if [[ "${kprocs}" != "" ]]; then
  echo "error: killing hung kubectl processes ..."
  ps -f -p ${kprocs} || true
  sudo -E kill ${kprocs} || true
fi

# clean up none drivers binding on 8443
  none_procs=$(sudo lsof -i :8443 | tail -n +2 | awk '{print $2}' || true)
  if [[ "${none_procs}" != "" ]]; then
    echo "Found stale api servers listening on 8443 processes to kill: "
    for p in $none_procs
    do
    echo "Kiling stale none driver:  $p"
    sudo -E ps -f -p $p || true
    sudo -E kill $p || true
    sudo -E kill -9 $p || true
    done
  fi

function cleanup_stale_routes() {
  local show="netstat -rn -f inet"
  local del="sudo route -n delete"

  if [[ "$(uname)" == "Linux" ]]; then
    show="ip route show"
    del="sudo ip route delete"
  fi

  local troutes=$($show | awk '{ print $1 }' | grep 10.96.0.0 || true)
  for route in ${troutes}; do
    echo "WARNING: deleting stale tunnel route: ${route}"
    $del "${route}" || true
  done
}

cleanup_stale_routes || true

mkdir -p "${TEST_HOME}"
export MINIKUBE_HOME="${TEST_HOME}/.minikube"
export KUBECONFIG="${TEST_HOME}/kubeconfig"


# Build the gvisor image so that we can integration test changes to pkg/gvisor
chmod +x ./testdata/gvisor-addon
# skipping gvisor mac because ofg https://github.com/kubernetes/minikube/issues/5137
if [ "$(uname)" != "Darwin" ]; then
  # Should match GVISOR_IMAGE_VERSION in Makefile
  docker build -t gcr.io/k8s-minikube/gvisor-addon:2 -f testdata/gvisor-addon-Dockerfile ./testdata
fi

readonly LOAD=$(uptime | egrep -o "load average.*: [0-9]+" | cut -d" " -f3)
if [[ "${LOAD}" -gt 2 ]]; then
  echo ""
  echo "********************** LOAD WARNING ********************************"
  echo "Load average is very high (${LOAD}), which may cause failures. Top:"
  if [[ "$(uname)" == "Darwin" ]]; then
    # Two samples, macOS does not calculate CPU usage on the first one
    top -l 2 -o cpu -n 5 | tail -n 15
  else
    top -b -n1 | head -n 15
  fi
  echo "********************** LOAD WARNING ********************************"
  echo "Sleeping 30s to see if load goes down ...."
  sleep 30
  uptime
fi

e2e_start_time="$(date -u +%s)"
echo ""
echo ">> Starting ${E2E_BIN} at $(date)"
set -x
${SUDO_PREFIX}${E2E_BIN} \
  -minikube-start-args="--vm-driver=${VM_DRIVER} ${EXTRA_START_ARGS}" \
  -expected-default-driver="${EXPECTED_DEFAULT_DRIVER}" \
  -test.timeout=70m \
  ${EXTRA_TEST_ARGS} \
  -binary="${MINIKUBE_BIN}" && result=$? || result=$?
set +x
echo ">> ${E2E_BIN} exited with ${result} at $(date)"
echo ""

if [[ $result -eq 0 ]]; then
  status="success"
  echo "minikube: SUCCESS"
else
  status="failure"
  echo "minikube: FAIL"
fi

## caclucate the time took to finish running e2e binary test.
e2e_end_time="$(date -u +%s)"
elapsed=$(($e2e_end_time-$e2e_start_time))
min=$(($elapsed/60))
sec=$(tail -c 3 <<< $((${elapsed}00/60)))
elapsed=$min.$sec
description="completed with ${status} in ${elapsed} minute(s)."
echo $description


echo ">> Cleaning up after ourselves ..."
${SUDO_PREFIX}${MINIKUBE_BIN} tunnel --cleanup || true
${SUDO_PREFIX}${MINIKUBE_BIN} delete >/dev/null 2>/dev/null || true
cleanup_stale_routes || true

${SUDO_PREFIX} rm -Rf "${MINIKUBE_HOME}" || true
${SUDO_PREFIX} rm -f "${KUBECONFIG}" || true
rmdir "${TEST_HOME}"
echo ">> ${TEST_HOME} completed at $(date)"

if [[ "${MINIKUBE_LOCATION}" == "master" ]]; then
  exit $result
fi

# retry_github_status provides reliable github status updates
function retry_github_status() {
  local commit=$1
  local context=$2
  local state=$3
  local token=$4
  local target=$5
  local desc=$6

   # Retry in case we hit our GitHub API quota or fail other ways.
  local attempt=0
  local timeout=2
  local code=-1

  while [[ "${attempt}" -lt 8 ]]; do
    local out=$(mktemp)
    code=$(curl -o "${out}" -s --write-out "%{http_code}" -L \
      "https://api.github.com/repos/kubernetes/minikube/statuses/${commit}?access_token=${token}" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "{\"state\": \"${state}\", \"description\": \"Jenkins: ${desc}\", \"target_url\": \"${target}\", \"context\": \"${context}\"}" || echo 999)

    # 2xx HTTP codes
    if [[ "${code}" =~ ^2 ]]; then
      break
    fi

    cat "${out}" && rm -f "${out}"
    echo "HTTP code ${code}! Retrying in ${timeout} .."
    sleep "${timeout}"
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done
}



retry_github_status "${COMMIT}" "${JOB_NAME}" "${status}" "${access_token}" "https://storage.googleapis.com/minikube-builds/logs/${MINIKUBE_LOCATION}/${JOB_NAME}.txt" "${description}"
exit $result
