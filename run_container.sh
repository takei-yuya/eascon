#!/bin/bash
# vim: background=dark ts=2 sts=2 sw=2 et

set -e

scriptdir="$(cd "$(dirname "$0")"; pwd)"
script="${scriptdir%/}/$(basename "$0")"

readonly IMAGE_DIR="${HOME}/images/"
readonly CONTAINER_DIR="${HOME}/container/"


# escape docker tag for filename
escape() {
  for (( i = 0; i < "${#1}"; ++i )); do
    case "${1:i:1}" in
      ":"|"/")
        printf '%%%X' "'${1:i:1}"
        ;;
      *)
        printf '%c' "${1:i:1}"
        ;;
    esac
  done
}

pull_image() {
  mkdir -p "${IMAGE_DIR}"
  local repo="${1}"
  local tag="${2}"

  if [ -d "${IMAGE_DIR}/layers/$(escape "${repo}:${tag}")" ]; then
    # already exist
    return
  fi

  local tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" RETURN

  local token="$(curl -sSf -L "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -rc .token)"
  curl -sSf -L --header "Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" -o "${tmpdir}/manifest"

  local blobs=($(jq -rc '.fsLayers | .[].blobSum' "${tmpdir}/manifest"))
  local ids=($(jq -rc '.history | .[].v1Compatibility | fromjson | .id' "${tmpdir}/manifest"))
  local parents=($(jq -rc '.history | .[].v1Compatibility | fromjson | .parent' "${tmpdir}/manifest"))
  local sha256s=("${blobs[@]#sha256:}")

  for ((i = 0; i < ${#sha256s[@]}; ++i)); do
    if [ ! -f "${IMAGE_DIR}/blobs/${sha256s[i]}.tar-split.gz" ]; then
      mkdir -p "${IMAGE_DIR}/blobs/"
      curl -Sf -L --header "Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo}/blobs/sha256:${sha256s[i]}" -o "${IMAGE_DIR}/blobs/${sha256s[i]}.tar-split.gz"
    fi

    if [ ! -d "${IMAGE_DIR}/blobs/${sha256s[i]}" ]; then
      mkdir -p "${IMAGE_DIR}/blobs/${sha256s[i]}"
      tar -C "${IMAGE_DIR}/blobs/${sha256s[i]}" -zxf "${IMAGE_DIR}/blobs/${sha256s[i]}.tar-split.gz"
    fi

    mkdir -p "${IMAGE_DIR}/layers/${ids[i]}"
    if [ "${parents[i]}" != "null" ]; then
      ln -T -sf "../${parents[i]}" "${IMAGE_DIR}/layers/${ids[i]}/parent"
    fi
    ln -T -sf "../../blobs/${sha256s[i]}.tar-split.gz" "${IMAGE_DIR}/layers/${ids[i]}/blob.tar-split.gz"
    ln -T -sf "../../blobs/${sha256s[i]}" "${IMAGE_DIR}/layers/${ids[i]}/blob"
  done

  ln -T -sf "${ids[0]}" "${IMAGE_DIR}/layers/$(escape "${repo}:${tag}")"
}

main() {
  local repo="${1}"; shift
  local tag="${1}"; shift
  local container_name="$(date +"%Y%m%d-%H%M%S")"

  local tmpdir="${CONTAINER_DIR}/${container_name}/tmp"

  uid_map="$(sed "s/^${USER}:\([0-9]*\):\([0-9]*\)/1 \1 \2/p;d" /etc/subuid)"
  gid_map="$(sed "s/^${USER}:\([0-9]*\):\([0-9]*\)/1 \1 \2/p;d" /etc/subgid)"

  mkdir -p "${tmpdir}"
  mkfifo "${tmpdir}/pid4userns"
  {
    pid="$(cat "${tmpdir}/pid4userns")"

    newuidmap ${pid} 0 $(id -u) 1 ${uid_map}
    newgidmap ${pid} 0 $(id -g) 1 ${gid_map}
    echo "ok" > "${tmpdir}/pid4userns"

    echo 'nameserver 10.0.2.3' > "${tmpdir}/resolv.conf"
    # ip link set up dev tap0
    # ip addr add 10.0.2.100/24 dev tap0
    # ip route add default via 10.0.2.2 dev tap0
    exec slirp4netns -c "${pid}" tap0 >"${tmpdir}/slirp4netns.stdout" 2>"${tmpdir}/slirp4netns.stderr"
  } &
  trap 'kill %1' RETURN

  unshare -U -m -n "${script}" Mounter "${repo}" "${tag}" "${container_name}" "${@}"
}

Mounter() {
  # unshared user mnt net
  local repo="${1}"; shift
  local tag="${1}"; shift
  local container_name="${1}"; shift

  local tmpdir="${CONTAINER_DIR}/${container_name}/tmp"
  local upperdir="${CONTAINER_DIR}/${container_name}/upper"
  local workdir="${CONTAINER_DIR}/${container_name}/work"
  local mergeddir="${CONTAINER_DIR}/${container_name}/merged"

  echo "$$" > "${tmpdir}/pid4userns"
  cat "${tmpdir}/pid4userns" >/dev/null

  local layer="${IMAGE_DIR}/layers/$(escape "${repo}:${tag}")"
  local lowerdirs="${layer}/blob"
  while test -e "${layer}/parent"; do
    layer="${layer}/parent"
    lowerdirs="${layer}/blob:${lowerdirs}"
  done

  mkdir -p "${upperdir}" "${workdir}" "${mergeddir}"
  fuse-overlayfs  -o "lowerdir=${lowerdirs},upperdir=${upperdir},workdir=${workdir}" "${mergeddir}" \
    >"${tmpdir}/overlayfs.stdout" 2>"${tmpdir}/overlayfs.stderr"

  cd "${mergeddir}"

  {
    sleep 1  # TODO: ensure unshare(1) is running in this directory
    umount -l .
  } &

  # To keep fuse-overlayfs's root, unshare mnt namespace again
  unshare -m -u -i -pf "${script}" Runner "${container_name}" "${@}"
}

Runner() {
  # unshared mnt uts ipc pid (and forked)
  local container_name="${1}"; shift

  local tmpdir="${CONTAINER_DIR}/${container_name}/tmp"

  mkdir -p proc
  mount -t proc proc proc

  mkdir -p sys
  mount -t sysfs sysfs sys

  mkdir -p dev
  touch dev/null
  mount --bind /dev/null dev/null
  touch dev/full
  mount --bind /dev/full dev/full
  touch dev/zero
  mount --bind /dev/zero dev/zero
  touch dev/random
  mount --bind /dev/random dev/random
  touch dev/urandom
  mount --bind /dev/urandom dev/urandom
  touch dev/tty
  mount --bind /dev/tty dev/tty

  ln -T -sf /proc/self/fd/0 dev/stdin
  ln -T -sf /proc/self/fd/1 dev/stdout
  ln -T -sf /proc/self/fd/2 dev/stderr
  ln -T -sf /proc/self/fd dev/fd

  mkdir -p etc
  touch etc/resolv.conf
  mount --bind "${tmpdir}/resolv.conf" etc/resolv.conf

  mkdir .old
  pivot_root . .old
  mount --make-rprivate .old
  umount -l .old
  rmdir .old

  # set HOME, keep TERM
  chroot . env - HOME=~root TERM="${TERM}" /bin/bash -l
}

repo="takei/centos"
tag="centos7"

pull_image "${repo}" "${tag}"
if [ $# -eq 0 ]; then
  main "${repo}" "${tag}"
else
  ${@}
fi
