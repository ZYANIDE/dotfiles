#!/bin/sh
set -e # Exit immediately if a command exits with a non-zero status.

# die <exit-code> <message>
die() (
  echo "$2" >> /dev/tty
  exit "$1"
)

# check_dependency [dependency-name] <dependency-cmd>
check_dependency() (
  [ -z "$(command -v ${2:-"$1"})" ] && die 1 "Dependency missing: $1"
  return 0
)

check_dependency yq

# TODO: read the given manifest
manifest_path=./manifest.yaml

packages="$(yq -r '.packages[]' "$manifest_path")"

# TODO: what mode is the script running in? (factory, update, backup, restore)
# TODO: install all @.packages using @.package_manager
# TODO: install all packages in @.applications (optional)
# TODO: install all @.dotfiles