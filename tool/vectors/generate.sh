#!/usr/bin/env bash
# Regenerate test/data vectors with liblzo2.
#
#   tool/vectors/generate.sh
#   LZO_PREFIX=/opt/lzo-2.10 tool/vectors/generate.sh
#   LZO_ORACLE=/path/to/lzo_oracle tool/vectors/generate.sh
#
# Requires a compiler and a liblzo2 2.10 installation (headers + library); see
# tool/oracle/Makefile. Everything is written as raw bytes.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

if [[ -z "${LZO_ORACLE:-}" ]]; then
  make -C "$repository_root/tool/oracle" >/dev/null
  LZO_ORACLE="$repository_root/tool/oracle/lzo_oracle"
fi

exec dart run "$repository_root/tool/vectors/generate.dart" \
  --oracle "$LZO_ORACLE" "$@"
