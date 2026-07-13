#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build --configuration release

bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
destination="$bin_dir/heard"
temporary="$bin_dir/.heard-install-$$"

mkdir -p "$bin_dir"
install -m 755 .build/release/heard "$temporary"
mv -f "$temporary" "$destination"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    printf '%s\n' "Installed to $destination"
    printf '%s\n' "Add this directory to your PATH: $bin_dir"
    exit 0
    ;;
esac

printf '%s\n' "Installed $destination"
"$destination" status
