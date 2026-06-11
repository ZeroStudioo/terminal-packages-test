#!/usr/bin/env bash

set -euo pipefail

script=$(realpath "$0")
script_dir=$(dirname "$script")

# shellcheck source=common.sh
. "$script_dir/common.sh"

COTG_RELEASE="false"
COTG_LOCAL="false"

declare -a PATCHES=(

  # Adds our own GPG keys
  "termux-keyring.patch"

  # Update mirror configurations
  "termux-tools-mirrors.patch"

  # Update motd
  "termux-tools-motd.patch"

  # Makes some of the packages depend on and link against libandroid-shmem.so
  # Required to fix some build failures
  "libdb-depend-on-android-shmem.patch"
  "libunbound-depend-on-android-shmem.patch"
  "libx11-depend-on-android-shmem.patch"

  # Fix dependencies in binutils-libs
  "binutils-libs-fix-dependencies.patch"

  # libxml2 v2.14.4 has build errors
  # "libxml2-revert-to-2.14.3.patch"

  # Remove 'scalar' binary from $PREFIX/bin and make it a symlink
  # to $PREFIX/libexec/git-core/scalar
  "git-symlink-scalar.patch"

  # subversion fails to compile, complaining that the `apr.h` and other headers
  # could not be found. These headers are located in $PREFIX/include/apr-1
  "subversion-missing-apr-includes.patch"

  # libuv has missing sources in their Makefile configuration
  # This missing source issue was fixed in their CMake configuration
  # So we force termux-packages to build using CMake instead of Makefile
  "libuv-force-cmake-build.patch"

  # Changes for our version of bootstrap-*.zip files
  # This also handles the process of creating a brotli archive
  # from the generated ZIP archive
  "scripts-generate-bootstraps-CoGo-changes.patch"

  # Update package name in termux-tools
  "termux-tools-update-package-name.patch"

  # Cleanup OpenJDK 21 to remove postinst & prerm scripts
  "openjdk-21-cleanup.patch"

  # Cleanup vim to remove postinst scripts
  "vim-cleanup.patch"

  # Restore files and cleanup in second stage
  "scripts-cleanup-in-second-stage.patch"

  # Link pulseaudio against libiconv to resolve linker errors at build time
  "pulseaudio-link-against-libiconv.patch"

  # `rm` command complains about missing libacl.so after updating packages
  # This ensures that libacl package is installed before coreutils
  "coreutils-depend-on-libacl.patch"

  # `libapr-1.so` needs to be linked against libandroid-shmem.so
  # in order to fix undefined symbol error when building subversion
  "apr-link-against-libandroid-shmem.patch"

  # v0.7 of the libandroid-shmem library patches shmem.c to use ASharedMemory_* from libandroid.so
  # to work with shared memory regions. However, libandroid.so pulls in a bunch of other system
  # libraries, including libperfetto_framework_jni.so, which assumes an ART environment and tries
  # to register native methods of classes. This makes our tooling API server, running in a JVM env,
  # crash due to the obviously missing Android-specific classes.
  "libandroid-shmem-revert-a-shared-memory-patch.patch"

  # termux-packages/build-package.sh contains hardcoded names for keyring files
  # these keyring files are used when we build packages with the -I flag
  # since we use a different signing key, we need to update the reference here
  "use-our-keys-to-install-deps.patch"
)

usage() {
  echo "Script to generate bootstrap archives for Code On the Go."
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -g        Generate bootstrap archive for release builds."
  echo "            Defaults to ${COTG_RELEASE}."
  echo "  -l        Use local packages repository. Defaults to ${COTG_LOCAL}."
  echo "            This takes precendence over the repository provided using -r."
  echo "  -r        The repository where the built packages will be published."
  echo "            Defaults to '${COTG_REPO}'."
  echo
  echo "  -h        Show this help message and exit."
}

apply_patches() {
  pushd "$TERMUX_PACKAGES_DIR" || scribe_error_exit "Unable to pushd"

  for patch in "${PATCHES[@]}"; do
    scribe_info "Applying patch: $patch"

    if patch -p1 --no-backup-if-mismatch < "$script_dir/patches/$patch"; then
      scribe_ok "Applied $patch"
    else
      scribe_error_exit "Failed patch: $patch"
    fi
  done

  popd || scribe_error_exit "Unable to popd"
}

build_boostrap() {
  variant="$1"
  arch="$2"
  repo="$3"

  shift 3
  pkgs=("$@")
  packages=$(
    IFS=,
    echo "${pkgs[*]}"
  )

  if [[ -z "$variant" ]]; then
    scribe_error_exit "Target variant must not be empty"
  fi

  if [[ -z "$arch" ]]; then
    scribe_error_exit "Target arch must not be empty"
  fi

  if [[ -z "$repo" ]]; then
    scribe_error_exit "Target repo must not be empty"
  fi

  bootstrap_name="bootstrap-${arch}.zip"
  bootstrap_out="${COTG_OUTPUT_DIR}/bootstrap-${variant}-${arch}.zip"

  echo
  echo "==="
  echo "Building bootstrap: $(realpath --relative-to="$(pwd)" "${bootstrap_out}")"
  echo "==="
  echo

  out_dir="$script_dir/output/$arch"
  pushd "$out_dir" ||
    scribe_error_exit "Unable to switch to output dir: ${out_dir}"

  if ! {
    set -x
    time "$TERMUX_PACKAGES_DIR/scripts/generate-bootstraps.sh" \
      --architectures "$arch" \
      --repository "$repo" \
      --add "${packages}" |&
      tee "$out_dir/generate-bootstrap-${variant}.log"
  }; then
    scribe_error_exit "Failed to generate boostrap for ${arch} ${variant}."
  fi

  # Rename the built files
  mv "${bootstrap_name}" "${bootstrap_out}"
  mv "${bootstrap_name}.9" "${bootstrap_out}.9"

  popd ||
    scribe_error_exit "Unable to switch from output dir: ${out_dir}"
}

while getopts "glr:h" opt; do
  case "$opt" in
  g) COTG_RELEASE="true" ;;
  l) COTG_LOCAL="true" ;;
  r) COTG_REPO="$OPTARG" ;;
  h)
    usage
    exit 0
    ;;
  *)
    scribe_error "Invalid option" >&2
    exit 1
    ;;
  esac
done

shift $((OPTIND - 1))

if [[ "$COTG_LOCAL" == "true" ]]; then
  COTG_REPO="file://${COTG_REPO_DIR}"
fi

if [[ -z "${COTG_REPO}" ]]; then
  scribe_error_exit "A package repository URL must be specified."
fi

COTG_VARIANT="debug"

declare -a COTG_EXTRA_PACKAGES
COTG_EXTRA_PACKAGES=("${COTG_PACKAGES__BASE[@]}")

if [[ "$COTG_RELEASE" == "true" ]]; then
  COTG_VARIANT="release"
  COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__RELEASE[@]}")
else
  COTG_EXTRA_PACKAGES+=("${COTG_PACKAGES__DEBUG[@]}")
fi

echo "Using configuration:"
echo "  Variant        : ${COTG_VARIANT}"
echo "  Repository     : ${COTG_REPO}"
echo "  Extra packages : ${COTG_EXTRA_PACKAGES[@]}"

apply_patches

for arch in aarch64 arm; do
  build_boostrap "$COTG_VARIANT" "$arch" "$COTG_REPO" "${COTG_EXTRA_PACKAGES[@]}" ||
    scribe_error_exit "Unable to build bootstrap for ${arch}"
done
