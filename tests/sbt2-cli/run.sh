#!/usr/bin/env bash

set -euxo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

SBTIX_BIN="${SBTIX_BIN:-${repo_root}/result/bin/sbtix}"
if [[ ! -x "${SBTIX_BIN}" ]]; then
  if command -v sbtix >/dev/null 2>&1; then
    SBTIX_BIN="sbtix"
  else
    echo "ERROR: sbtix not found (checked '${SBTIX_BIN}' and PATH)." >&2
    echo "       Build the CLI first with: nix build '.#sbtix'" >&2
    exit 1
  fi
fi

if [[ -d "${repo_root}/result/plugin-repo" ]]; then
  test -f "${repo_root}/result/plugin-repo/se.nullable.sbtix/sbtix_sbt2_3/1.2.0/jars/sbtix_sbt2_3.jar"
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/sbtix-sbt2-cli.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/project"
cat > "${workdir}/project/build.properties" <<'EOF'
sbt.version=2.0.0
EOF
cat > "${workdir}/build.sbt" <<'EOF'
ThisBuild / scalaVersion := "3.7.4"

lazy val root = (project in file("."))
  .settings(
    name := "sbtix-sbt2-cli-smoke"
  )
EOF

(
  cd "${workdir}"
  "${SBTIX_BIN}" --error "show sbtVersion"
)
