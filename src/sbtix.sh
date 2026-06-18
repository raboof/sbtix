#!@shell@
set -euo pipefail

SBT_OPTS=${SBT_OPTS:-}

detect_project_sbt_version() {
  if [ -f "project/build.properties" ]; then
    sed -n 's/^[[:space:]]*sbt\.version[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*$/\1/p' \
      "project/build.properties" | head -n 1
  fi
}

SBTIX_SBT_VERSION="$(detect_project_sbt_version)"
case "${SBTIX_SBT_VERSION}" in
  2.*)
    SBTIX_SBT_MAJOR=2
    SBTIX_PLUGIN_JAR_PATH="@pluginJarSbt2@"
    ;;
  *)
    SBTIX_SBT_MAJOR=1
    SBTIX_PLUGIN_JAR_PATH="@pluginJarSbt1@"
    ;;
esac

# Ensure the JVM sees a consistent user home.
#
# Why: Nix shells / CI often set $HOME to a temp directory, but the Java
# `user.home` property can still point at the real account home (or even
# `/var/empty`). sbt (and sbtix) use `user.home` for Ivy-local paths, which can
# lead to stale plugin jars being loaded from a different location and trip the
# "plugin jar mismatch" guard during `genComposition`.
#
# Force `user.home` to match $HOME. If the caller already set `-Duser.home=...`,
# appending our value makes the JVM pick up the last one.
SBT_OPTS="${SBT_OPTS} -Duser.home=${HOME}"

IVY_LOCAL_ROOT="${HOME}/.ivy2/local"
IVY_LOCAL="${IVY_LOCAL_ROOT}/se.nullable.sbtix"
if [ -e "${IVY_LOCAL}" ] || [ -L "${IVY_LOCAL}" ]; then
  echo "Deleting any cached sbtix plugins in '~/.ivy2/local'. So the most recent version from nix is used."
  rm -rf "${IVY_LOCAL}"
fi
mkdir -p "${IVY_LOCAL_ROOT}"
ln -s "@pluginRepoOrg@" "${IVY_LOCAL}"

GLOBAL_DIR="${HOME}/.sbtix"
PLUGIN_DIR="${GLOBAL_DIR}/plugins"
# Force sbt to use a deterministic, user-writable global base so we can drop in
# the sbtix plugin wrapper and avoid hitting system locations like /var/empty.
mkdir -p "${PLUGIN_DIR}"

# Invalidate the compiled global-plugins build when switching sbtix wrappers.
#
# Why: sbt caches the compiled "global plugins" build under:
#   ${PLUGIN_DIR}/project/** and ${PLUGIN_DIR}/target/**
# When sbtix is upgraded/downgraded, the global plugin definition we symlink
# (`sbtix_plugin.sbt`) changes, but sbt may still reuse the old compiled build
# and keep trying to resolve the old sbtix plugin version (e.g. 0.4-SNAPSHOT).
# This is especially likely with Nix store files, which often have an epoch
# mtime that can confuse file-change detection.
PLUGIN_STAMP_FILE="${GLOBAL_DIR}/.sbtix-plugin-stamp"
CURRENT_PLUGIN_STAMP="@plugin@|${SBTIX_PLUGIN_JAR_PATH}|sbt-${SBTIX_SBT_MAJOR}"
OLD_PLUGIN_STAMP=""
if [ -f "${PLUGIN_STAMP_FILE}" ]; then
  OLD_PLUGIN_STAMP="$(cat "${PLUGIN_STAMP_FILE}" 2>/dev/null || true)"
fi
if [ "${OLD_PLUGIN_STAMP}" != "${CURRENT_PLUGIN_STAMP}" ]; then
  echo "sbtix: detected a different wrapper/plugin; clearing global plugin build caches"
  rm -rf "${PLUGIN_DIR}/project" "${PLUGIN_DIR}/target"
  printf '%s' "${CURRENT_PLUGIN_STAMP}" > "${PLUGIN_STAMP_FILE}"
fi

# Expose the in-store plugin JAR to any sbt process launched through this
# wrapper so generated nix expressions can reference it directly.
export SBT_OPTS="$SBT_OPTS -Dsbtix.pluginJarPath=${SBTIX_PLUGIN_JAR_PATH}"

# Prefer the in-store checkout of the sbtix sources that produced this wrapper.
# This keeps generated Nix files fully offline (no GitHub fetch) in CI and in
# local dev shells, even when the working tree is dirty.
if [ -n "@sourcePath@" ]; then
  export SBTIX_SOURCE_PATH="@sourcePath@"
fi

if [ -n "${SBTIX_SOURCE_PATH:-}" ]; then
  export SBT_OPTS="$SBT_OPTS -Dsbtix.sourcePath=$SBTIX_SOURCE_PATH"
fi

# Use an isolated Coursier cache under the sbtix global base so we don't
# accidentally reuse stale sbt plugin artifacts across wrapper rebuilds.
export SBT_OPTS="$SBT_OPTS -Dcoursier.cache=${GLOBAL_DIR}/.coursier-cache"
export COURSIER_CACHE="${GLOBAL_DIR}/.coursier-cache/v1"

# Also purge cached copies of the sbtix plugin to make sure we always load the
# freshly built jar from the nix store. Otherwise Ivy may silently reuse an old
# snapshot, which then misses the latest template fixes.
IVY_CACHE_DIR="${HOME}/.ivy2/cache/se.nullable.sbtix"
if [ -d "${IVY_CACHE_DIR}" ]; then
  echo "Deleting cached sbtix plugin from '~/.ivy2/cache' so the nix-built jar is reloaded."
  rm -rf "${IVY_CACHE_DIR}"
fi

export SBT_OPTS="-Dsbt.global.base=${GLOBAL_DIR}${SBT_OPTS:+ ${SBT_OPTS}}"
echo "Updating ${PLUGIN_DIR}/sbtix_plugin.sbt symlink"
ln -sf "@plugin@" "${PLUGIN_DIR}/sbtix_plugin.sbt"

INJECTED_PLUGIN_FILES=""
CREATED_PLUGIN_DIRS=""

cleanup_injected_plugins() {
  for file in ${INJECTED_PLUGIN_FILES}; do
    if [ -L "${file}" ] || [ -f "${file}" ]; then
      rm -f "${file}"
    fi
  done
  if [ -L "${IVY_LOCAL}" ] && [ "$(readlink "${IVY_LOCAL}")" = "@pluginRepoOrg@" ]; then
    rm -f "${IVY_LOCAL}"
  fi
  for dir in ${CREATED_PLUGIN_DIRS}; do
    rmdir "${dir}" 2>/dev/null || true
  done
}

inject_sbt_file() {
  dir="$1"
  source="$2"
  name="$3"
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
    CREATED_PLUGIN_DIRS="${dir} ${CREATED_PLUGIN_DIRS}"
  fi

  file="${dir}/${name}-$$.sbt"
  if [ -e "${file}" ] || [ -L "${file}" ]; then
    echo "sbtix: refusing to overwrite existing temporary plugin file: ${file}" >&2
    exit 1
  fi

  ln -s "${source}" "${file}"
  INJECTED_PLUGIN_FILES="${file} ${INJECTED_PLUGIN_FILES}"
}

inject_project_plugin() {
  inject_sbt_file "$1" "@plugin@" "sbtix-auto-plugin"
}

inject_generated_ide_plugin_compat() {
  inject_sbt_file "$1" "@generatedIdePluginCompat@" "zz-sbtix-generated-ide-plugin-compat"
}

inject_generated_ide_plugin_compat_files() {
  if [ ! -d "project" ]; then
    return
  fi

  metals_dirs="$(find project -name metals.sbt -type f -exec dirname {} \; 2>/dev/null | sort -u || true)"
  for dir in ${metals_dirs}; do
    inject_generated_ide_plugin_compat "${dir}"
  done
}

trap cleanup_injected_plugins EXIT

if [ "${SBTIX_SBT_MAJOR}" = 2 ]; then
  inject_generated_ide_plugin_compat_files
  inject_project_plugin "project"
  inject_project_plugin "project/project"
fi

if [ -n "@sourceRev@" ] && [ -n "@sourceNarHash@" ]; then
  export SBTIX_SOURCE_URL="@sourceUrl@"
  export SBTIX_SOURCE_REV="@sourceRev@"
  export SBTIX_SOURCE_NAR_HASH="@sourceNarHash@"
fi

if [ -n "${SBTIX_SOURCE_REV:-}" ] && [ -n "${SBTIX_SOURCE_NAR_HASH:-}" ]; then
  sourceUrl="${SBTIX_SOURCE_URL:-https://github.com/natural-transformation/sbtix}"
  export SBT_OPTS="$SBT_OPTS -Dsbtix.sourceUrl=$sourceUrl -Dsbtix.sourceRev=$SBTIX_SOURCE_REV -Dsbtix.sourceNarHash=$SBTIX_SOURCE_NAR_HASH"
fi

if [ "$#" -gt 0 ]; then
  case "$1" in
    genNix)
      # Run genNix for the main build, reload into the meta-build to capture
      # plugin dependencies, then return to the main build.
      if [ "${SBTIX_SBT_MAJOR}" = 2 ]; then
        set -- "; genNix; reload plugins; genNix; reload return"
      else
        set -- \
          genNix \
          "reload plugins" \
          genNix \
          "reload return"
      fi
      ;;
    genComposition)
      # Ensure both the project and meta-build repos are up-to-date before
      # emitting sbtix-generated.nix.
      if [ "${SBTIX_SBT_MAJOR}" = 2 ]; then
        set -- "; genNix; reload plugins; genNix; reload return; genComposition"
      else
        set -- \
          genNix \
          "reload plugins" \
          genNix \
          "reload return" \
          genComposition
      fi
      ;;
  esac
fi

set +e
@sbt@ "$@"
status=$?
set -e
trap - EXIT
cleanup_injected_plugins
exit "${status}"
