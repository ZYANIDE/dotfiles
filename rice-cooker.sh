#!/bin/sh
set -e # Exit immediately if a command exits with a non-zero status.

: '#####################
   ###   EXIT CODES  ###
   #####################'
#
# 0   : Success
# 1   :
# 2   :
#
: '#####################
   ###   UTILITIES   ###
   #####################'

COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RESET="\033[0m"

# die <exit-code> <message>
die() (
  exit_code="$1"; message="$2"
  if [ -n "$message" ]; then
    if [ "$exit_code" = 0 ];
    then printf '%s' "$message" >> /dev/tty
    else printf "\n${COLOR_RED}%s${COLOR_RESET}\n" "$message" >> /dev/stderr; fi
  fi
  exit "$exit_code"
)

# assert_dependency ...<command>
assert_dependency() (
  for cmd in "$@"; do
    [ -z "$(command -v "$cmd")" ] && printf "Dependency missing: %s\n" "$1" >> /dev/tty && return 1
  done
  return 0
)

# xor_list <list1> <list2>
xor_list() (
  for i in $1; do
    found=false

    for j in $2; do
      if [ "$i" = "$j" ]; then
        found=true
        break
      fi
    done

    if [ "$found" = false ]; then
      echo "$i"
    fi
  done
)

# join_paths <path1> <path2>
join_paths() (
  case "$2" in
    /*) combined_path="$2" ;;
    *) case "$1" in
      */) combined_path="$1$2" ;;
      *) combined_path="$1/$2" ;;
    esac ;;
  esac
  echo "$combined_path" | sed 's|[^/]*/\.\./||g'
)

# upsert_file <source> <target> <mode>
upsert_file() (
  source="${1%/}"; target="${2%/}"; mode="$3";
  if [ -f "$target" ] || [ -d "$target" ]; then cp -r "$target" "$target.$(date +%s).bak"; fi
  if ! [ "$(echo $source)" = "$source" ]; then mkdir -p "$target"
  else mkdir -p "$(join_paths "$target" "../")"; fi
  cp -rf $source "$target"
  chmod -R "$mode" "$target"
)

# prompt_boolean <message> [<default=y>]
prompt_boolean() (
  DEFAULT="$(echo "${2:-'y'}" | tr '[:upper:]' '[:lower:]')"
  DEFAULT_INDICATOR="$([ "$DEFAULT" = 'y' ] && echo 'n/Y' || echo 'N/y')"
  while [ "$IN" != 'y' ] && [ "$IN" != 'n' ]; do
    printf '%s' "$1 ($DEFAULT_INDICATOR): " >> /dev/tty
    read -r IN
    IN="$(echo "${IN:-"$DEFAULT"}" | tr '[:upper:]' '[:lower:]')"
  done
  [ "$IN" = 'y' ] && echo 'true' || echo 'false'
)

# prompt_text [-rh] <prompt_message> [<default> <default_message>]
prompt_text() (
  while getopts 'rh' OPTKEY; do
    case "$OPTKEY" in
      r) is_required=true ;;
      h) is_hidden=true ;;
      *) printf '%s: option %s does not exist fr the internal function prompt_text\n' "$PROGRAM_NAME" "$OPTARG" && exit 1 ;;
    esac
  done
  shift "$((OPTIND -1))"; DEFAULT="$2"
  if [ -n "$3" ]; then PROMPT_HINT="$3"
  elif [ "$is_hidden" = true ]; then PROMPT_HINT='[Hidden]' && stty -echo
  elif [ -n "$DEFAULT" ]; then PROMPT_HINT="$DEFAULT"
  elif [ "$is_required" = true ]; then PROMPT_HINT='[Required]'
  else PROMPT_HINT='[Empty]'; fi
  while [ -z "${IN+x}" ] || { [ -z "$IN" ] && [ "$is_required" = true ]; } do
    printf '%s' "$1 ($PROMPT_HINT): " >> /dev/tty
    read -r IN
  done
  [ "$is_hidden" = true ] && stty echo && printf '\n' >> /dev/tty
  echo "${IN:-"$DEFAULT"}"
)

safe_run() (
  if [ "$DRY_RUN" = true ];
  then printf "${COLOR_BLUE}[DRY RUN] %s${COLOR_RESET}\n" "$*" >> /dev/tty
  else "$@"; fi
)

: '####################
   ###   ROUTINES   ###
   ####################'

# enable_multilib
enable_multilib() (
  printf 'Enabling the multilib repository...\n' >> /dev/tty
  safe_run sudo sed -i ':a;N;$!ba;s/#\[multilib\]\n#Include/\[multilib\]\nInclude/' /etc/pacman.conf
  safe_run sudo pacman -Sy
)

# install_package_manager <name> <verify_script> <prepare_script> <install_script> <cleanup_script>
install_package_manager() (
  name="$1"; verify="$2"; prepare="$3"; install="$4"; cleanup="$5";
  printf "Verifying if '%s' is already installed..." "$name" >> /dev/tty
  if ! sh -c "$verify" &>> /dev/null; then
    printf ' not found.\n' >> /dev/tty
    printf 'Preparing for installation...\n' >> /dev/tty
    safe_run sh -c "$prepare"
    printf 'Installing...\n' >> /dev/tty
    safe_run sh -c "$install"
    printf 'Cleaning up...\n' >> /dev/tty
    safe_run sh -c "$cleanup"
  else
    printf ' found.\nSkipping installation...\n' >> /dev/tty
  fi
)

# install_pm_packages <add_pkg_script> <packages>
install_pm_packages() (
  add_pkg="$1"; packages="$2";
  printf 'Installing %s packages:\n%s\n' "$package_manager" "$packages" >> /dev/tty
  PKGS="$packages" safe_run sh -c "$add_pkg"
)

# enable_systemd_services <service>
enable_systemd_service() (
  service="$1";
  printf "Verifying if '%s' is already started and enabled..." "$service" >> /dev/tty
  if ! systemctl is-enabled "$service" &>> /dev/null || ! systemctl is-active "$service" &>> /dev/null; then
    printf ' inactive.\n' >> /dev/tty
    printf 'Systemctl starting and enabling %s...\n' "$service" >> /dev/tty
    safe_run systemctl enable --now "$service"
  else
    printf ' active.\nSkipping service...\n' >> /dev/tty
  fi
)

# upsert_managed_files <file_table>
# file_table=(MODE TARGET SOURCE)[]
upsert_managed_files() (
  file_table="$1"
  while read -r file; do
    mode="$(echo "$file" | awk '{print $1}')"
    target="$(echo "$file" | awk '{print $2}' | sed "s|~|$HOME|g; s|\$HOME|$HOME|g")"
    source="$(echo "$file" | awk '{print $3}' | sed "s|~|$HOME|g; s|\$HOME|$HOME|g")"
    source="$(join_paths "$MANIFEST_PATH/.." "$source")"
    # TODO: dont stop script when diff return exit code 1
    # if ! [ "$(echo $source)" = "$source" ]; then diff -rq "${source%/*}" "$target"
    # else diff -rq "$source" "$target"; fi
    printf 'Updating %s\n' "$target" >> /dev/tty
    safe_run upsert_file "$source" "$target" "$mode"
  done <<< "$file_table"
)

: '###################
   ###   PROGRAM   ###
   ###################'

PROGRAM_NAME="$(basename "$0")"
PROGRAM_VERSION="v0.3.0"
PROGRAM_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_version() (
  printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION" >> /dev/tty
)

print_help() (
  printf '\n' >> /dev/tty
  printf 'Usage %s <command> [subcommands...] [operands...] [options...]\n' "$PROGRAM_NAME" >> /dev/tty
  printf ' -m --manifest                          : Path to the manifest\n' >> /dev/tty
  printf ' -p --prune                             : Remove unmanaged, orphaned packages and artefacts\n' >> /dev/tty
  printf ' -t --dry-run                           : Dry-run test\n' >> /dev/tty
  printf ' -v --version                           : Shows the program version\n' >> /dev/tty
  printf ' -h --help                              : Shows this prompt\n' >> /dev/tty
  printf '\n' >> /dev/tty
)

while getopts ':m:ptvh' OPTKEY; do
  case "$OPTKEY" in
    m) MANIFEST_PATH="$OPTARG" ;;
    p) PRUNE=true ;;
    t) DRY_RUN=true ;;
    v) print_version && die 0 ;;
    h) print_help && die 0 ;;
    *) die 1 "$PROGRAM_NAME: illegal option -- $OPTARG" ;;
  esac
done

assert_dependency yq

# TODO: what if some configs in the manifest are empty
MANIFEST_PATH="${MANIFEST_PATH:-"$PROGRAM_PATH/manifest.yaml"}"
if ! [ -f "$MANIFEST_PATH" ]; then die 1 "The manifest could not be found at $MANIFEST_PATH"; fi

enableMultilib=$(yq -r '.General.multilib' "$MANIFEST_PATH")
if [ "$enableMultilib" = 'true' ]; then
  printf '\n' >> /dev/tty
  enable_multilib
fi

packages="$(yq -r '.Packages[]' "$MANIFEST_PATH" | tr ' ' '\n' | awk '{gsub(/[\/]/, " "); print}')"
package_managers="$(yq -r '.PackageManagers | keys | .[]' "$MANIFEST_PATH")"
for package_manager in $package_managers; do
  prepare="$(yq -r ".PackageManagers.$package_manager.prepare // \"\"" "$MANIFEST_PATH")"
  install="$(yq -r ".PackageManagers.$package_manager.install // \"\"" "$MANIFEST_PATH")"
  cleanup="$(yq -r ".PackageManagers.$package_manager.cleanup // \"\"" "$MANIFEST_PATH")"
  verify="$(yq -r ".PackageManagers.$package_manager.verify // \"\"" "$MANIFEST_PATH")"
  add_pkg="$(yq -r ".PackageManagers.$package_manager.add_pkg // \"\"" "$MANIFEST_PATH")"
  pm_packages="$(echo "$packages" | awk -v pm="$package_manager" '$1 == pm {print $2}' | tr '\n' ' ')"

  printf '\n' >> /dev/tty
  install_package_manager "$package_manager" "$verify" "$prepare" "$install" "$cleanup"
  printf '\n' >> /dev/tty
  install_pm_packages "$add_pkg" "$pm_packages"
done

if [ "$PRUNE" = true ]; then
  printf '\n' >> /dev/tty
  printf 'Searching for undesired packages...' >> /dev/tty
  unlisted_packages="$(xor_list "$(pacman -Qeq | tr '\n' ' ')" "$(echo "$packages" | awk '{print $2}')" | tr '\n' ' ')"
  orphaned_packages="$(pacman -Qdtq || true)"
  if [ -n "$unlisted_packages" ] || [ -n "$orphaned_packages" ]; then
    printf ' found some.\n' >> /dev/tty
    printf 'Pruning...\n' >> /dev/tty
    safe_run sudo pacman -Rns $unlisted_packages $orphaned_packages --noconfirm
  else
    printf ' nothing found.\nSkipping pruning...\n' >> /dev/tty
  fi
fi

# Compares which packages are new (not yet in manifest) and/or missing (in manifest but not yet installed)
new_packages="$(xor_list "$(pacman -Qeq | tr '\n' ' ')" "$(echo "$packages" | awk '{print $2}')" | tr '\n' ' ')"
printf "\n${COLOR_RED}Package(s) missing in manifest:\n%s${COLOR_RESET}\n" "${new_packages:-[None]}"
missing_packages="$(xor_list "$(echo "$packages" | awk '{print $2}')" "$(pacman -Qeq | tr '\n' ' ')" | tr '\n' ' ')"
printf "\n${COLOR_GREEN}Package(s) to install:\n%s${COLOR_RESET}\n" "${missing_packages:-[None]}"

files="$(yq -r '(.Files // {}) | to_entries | .[] | .key as $parent | .value | "\(.mode) \($parent) \(.source)"' "$MANIFEST_PATH")"
if [ -n "$files" ]; then
  printf '\n' >> /dev/tty 
  upsert_managed_files "$files"
fi

services="$(yq -r '.Services[]' "$MANIFEST_PATH")"
for service in $services; do
  printf '\n' >> /dev/tty
  enable_systemd_service "$service"
done

printf '\n' >> /dev/tty
printf 'Executing post-script commands...\n' >> /dev/tty
safe_run sh -c "$(yq -r '.Commands // ""' "$MANIFEST_PATH")"

printf '\n' >> /dev/tty
