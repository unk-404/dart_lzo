#!/usr/bin/env bash
# Regenerate the all-family fixtures under test/data/families with liblzo2.
#
#   tool/vectors/generate_families.sh
#   LZO_PREFIX=/opt/lzo-2.10 tool/vectors/generate_families.sh
#   LZO_ORACLE=/path/to/lzo_oracle tool/vectors/generate_families.sh
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"

if [[ -z "${LZO_ORACLE:-}" ]]; then
  make -C "$repository_root/tool/oracle" >/dev/null
  LZO_ORACLE="$repository_root/tool/oracle/lzo_oracle"
fi

exec dart run "$repository_root/tool/vectors/generate_families.dart" \
  --oracle "$LZO_ORACLE" "$@"
