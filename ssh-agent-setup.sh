#!/usr/bin/env bash

# ----------------------------------------------------------------------------------
# ssh-agent-setup.sh
#
# Description:
#   This script automates the setup of systemd user services for managing the
#   SSH agent (`ssh-agent.service`) and automatically adding one or more
#   private SSH keys via `ssh-add.service`. It supports both non-interactive
#   and interactive modes.
#
#   It performs the following steps:
#     - Validates required dependencies (`systemctl`, `awk`, `grep`, `ssh-add`)
#     - Parses SSH private key paths from CLI arguments or user input
#     - Validates that each key is readable and exists
#     - Creates or updates `~/.config/systemd/user/ssh-add.service` by injecting
#       ExecStart lines for each provided SSH key
#     - Symlinks `ssh-agent.service` into the user systemd directory
#     - Appends `SSH_AUTH_SOCK` export to the user shell rc file (bash or zsh)
#     - Reloads systemd user daemon and starts/enables both services
#
# Usage:
#   ./ssh-agent-setup.sh [key1 [key2 ...]]
#
# Options:
#   -h, --help      Show usage information
#
# Notes:
#   - If no key paths are provided as arguments, the script prompts the user
#     to enter them interactively (if stdin is a terminal).
#   - The script assumes the existence of `ssh-agent.service` and a template
#     `ssh-add.service` file with the line "# INSERT KEYS HERE" as a placeholder.
# ----------------------------------------------------------------------------------
set -Eeuo pipefail

# Helper function to resolve symlinks to their real canonical path
# Tries in order: realpath -> readlink -f -> fallback (errors if still a symlink)
resolve_file_path() {
  local path="${1}"

  if command -v realpath > /dev/null 2>&1; then
    realpath -- "${path}" 2> /dev/null || printf "%s\n" "${path}"
  elif command -v readlink > /dev/null 2>&1 && readlink -f -- / > /dev/null 2>&1; then
    readlink -f -- "${path}" 2> /dev/null || printf "%s\n" "${path}"
  else
    if [[ -L ${path} ]]; then
      printf "Error: Cannot resolve symlink '%s' and no suitable tool is available.\n" "${path}" >&2
      exit 1
    fi
    printf "%s\n" "${path}"
  fi
}

# source_and_setup_logging
#
# Resolves this script's directory, builds the path to the logging library
# (assumed at ../../shell/general/logging.shlib), and sources it. Exits if missing.
#
# This loads the namespaced logging functions defined in logging.shlib:
#   - logging::init logging::log_info, logging::log_warn, logging::log_error,
#   - logging::log_fatal, logging::add_err_trap, logging::trap_err_handler
#   - logging::setup_traps logging::add_exit_trap
#
# The `logging::` prefix follows the convention described in the
# Google Shell Style Guide: https://google.github.io/styleguide/shellguide.html
source_and_setup_logging() {
  local script_dir logging_path

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  logging_path="$(resolve_file_path "${script_dir}/../../shell/general/logging.shlib")"

  if [[ -f ${logging_path} ]]; then
    # shellcheck source=../../shell/general/logging.shlib
    source "${logging_path}"
    logging::init "$0"
  else
    printf "Something went wrong sourcing the logging lib: %s\n" "${logging_path}" >&2
    exit 1
  fi
}

# Show usage details and exit.
usage() {
  cat << GET_YO_KEYS_WET
Usage: $(basename "${0}") [key1 [key2...]]
Options:
	-h, --help	Show this help message and exit.

If no keys are provided as arguments, you will be prompted (interactive only)
to enter one or more paths to SSH private key files to auto-load.
GET_YO_KEYS_WET
  exit 1
}

# Parse command-line arguments and collect SSH key paths.
parse_args() {
  local -r _dest="${1}"
  local -n keys_ref="${_dest}"
  shift

  while (($# > 0)); do
    case "${1}" in
      -h | --help) usage ;;
      --)
        shift
        break
        ;;
      -*)
        logging::log_error "Unknown option: ${1}"
        usage
        ;;
      *)
        keys_ref+=("${1}")
        shift
        ;;
    esac
  done

  if ((${#keys_ref[@]} == 0)); then
    if [[ -t 0 ]]; then
      read -rp "Enter SSH key path(s) (space-separated): " -a keys_ref
      ((${#keys_ref[@]} > 0)) || usage
    else
      usage
    fi
  fi
}

# Verify required external commands exist.
check_dependencies() {
  local deps=(systemctl awk grep ssh-add) # Check grep and awk in case someone manages to run this on a toaster

  for cmd in "${deps[@]}"; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
      logging::log_fatal "Required command '${cmd}' not found."
    fi
  done
}

# Initialize paths for templates and output
init_paths() {
  local config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"

  SERVICE_DIR="${config_home}/systemd/user"
  SRC_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TEMPLATE_ADD_SERVICE="${SRC_DIR}/ssh-add.service"
  AGENT_SERVICE_SRC="${SRC_DIR}/ssh-agent.service"
  FINAL_ADD_SERVICE="${SERVICE_DIR}/ssh-add.service"
}

# shell::init_shell_rc_map <map-var>
#   Populate an associative array mapping known shells to their RC file paths.
shell::init_shell_rc_map() {
  local -n shell_rc_map_ref="${1}"

  shell_rc_map_ref=(
    [bash]="${HOME}/.bash_profile"
    [zsh]="${ZDOTDIR:-${HOME}}/.zprofile"
    [fish]="${XDG_CONFIG_HOME:-${HOME}/.config}/fish/conf.d/ssh_agent.fish"
    [elvish]="${XDG_CONFIG_HOME}/elvish/rc.elv" # Elvish won't even launch if XDG_CONFIG_HOME is not set
    # XXX: nu-shell, etc.. could go here
  )
}

# Helper function to infer the current shell name if the user hasn't explicitly selected one.
shell::get_current_shell_name() {
  local shell_name

  shell_name="$(ps -p $$ -o comm=)"
  # Strip path and leading dash to get clean shell name (e.g., 'bash', 'zsh')
  shell_name="${shell_name#-}"
  printf "%s\n" "${shell_name##*/}" # Prints the basename
}

# shell::get_enabled_shells <in-map> <out-map>
#   Populate out-map with only those shells present in /etc/shells and on $PATH.
shell::get_enabled_shells() {
  local -n shell_rc_map_ref="${1}"
  local -n enabled_shell_rc_map_ref="${2}"

  # Parse /etc/shells and deduplicate entries by basename,
  # preferring /usr/bin/* over /bin/* when duplicates exist.
  # This avoids shell path ambiguity (e.g., both /bin/zsh and /usr/bin/zsh),
  # and aligns better with what command -v outputs.
  # Using Perl here for sane text handling and associative hash logic in one pass.
  mapfile -t valid_shells < <(
    perl -ne '
      next unless m{^/}; # Skip non-path lines
      chomp;
      ($base = $_) =~ s{^/usr/bin/|^/bin/}{}; # Strip leading path to get shell name
      $best{$base} = $_ if ! $best{$base} || $best{$base} =~ m{^/bin}; # Prefer /usr/bin
      END { print "$_\n" for sort values %best }
    ' /etc/shells
  ) \
    && ((${#valid_shells[@]} > 0)) \
    || logging::log_fatal "No valid shells found in /etc/shells"

  for shell in "${!shell_rc_map_ref[@]}"; do
    local shell_path

    if shell_path="$(command -v -- "${shell}" 2> /dev/null)"; then
      :
    else
      logging::log_info "Skipping ${shell} (not installed)"
      continue
    fi

    local -i is_valid_shell=0
    for valid in "${valid_shells[@]}"; do
      if [[ ${shell_path} == "${valid}" ]]; then
        is_valid_shell=1
        break
      fi
    done

    if ((is_valid_shell)); then
      enabled_shell_rc_map_ref["${shell}"]="${shell_rc_map_ref["${shell}"]}"
    else
      logging::log_info "Skipping ${shell} (not found in /etc/shells)"
    fi
  done
}

# shell::prompt_user_selection <enabled-map> <selected-map>
#   Present an indexed list of shells (with fzf or fallback), fill selected-map.
shell::prompt_user_selection() {
  local -n enabled_shell_rc_map_ref="${1}"
  local -n selected_shells_ref="${2}"

  local -A index_to_shell
  local -a selections
  local -i i=1
  local shell

  local arrow="->"
  if encoding="$(locale charmap 2> /dev/null)"; then
    if [[ ${encoding} == "UTF-8" ]]; then
      logging::log_info "Unicode support detected, enabling pretty things!"
      arrow=$'\u2192'
    else
      logging::log_warn "No Unicode support. Using ANSI fallback."
    fi
  fi

  printf "Available shells:\n"
  while IFS= read -r -d '' shell; do
    printf "  [%-2d] %-20s %s %s\n" "${i}" "${shell}" "${arrow}" "${enabled_shell_rc_map_ref["${shell}"]}"
    index_to_shell["${i}"]="${shell}"
    ((i++))
  done < <(printf "%s\0" "${!enabled_shell_rc_map_ref[@]}" | sort -z)

  # Use fzf if available for cleaner selection, if not fallback to read
  if command -v fzf > /dev/null 2>&1; then
    logging::log_info "fzf detected. Launching interactive selector..."
    mapfile -t selections < <(printf "%s\n" "${!enabled_shell_rc_map_ref[@]}" | fzf --multi --prompt="Select shells: ")
  else
    if ! [[ -t 0 ]]; then
      logging::log_warn "Non-interactive session detected and fzf is not available."
      logging::log_warn "Skipping shell RC update."
      return 1
    fi

    read -rp "Enter the number(s) of the shells to modify (e.g., 1 3): " -a indices

    if ((${#indices[@]} == 0)); then
      local current_shell
      current_shell="$(shell::get_current_shell_name)"

      if [[ -n ${current_shell} && -v ${enabled_shell_rc_map_ref[${current_shell}]} ]]; then
        logging::log_info "No selection made; defaulting to current shell: ${current_shell}"
        selected_shells_ref["${current_shell}"]="${enabled_shell_rc_map_ref["${current_shell}"]}"
        return
      else
        read -rp "Unable to detect shell. Apply to all available shells? [y/N] " confirm_all
        case "${confirm_all@L}" in
          y | yes)
            for shell in "${!enabled_shell_rc_map_ref[@]}"; do
              selected_shells_ref["$shell"]="${enabled_shell_rc_map_ref[$shell]}"
            done
            ;;
          *)
            logging::log_info "Skipping shell RC update."
            return 1
            ;;
        esac
      fi
    fi

    for index in "${indices[@]}"; do
      if ! [[ ${index} =~ ^[0-9]+$ ]]; then
        logging::log_warn "Invalid input (not a number): ${index}"
        continue
      fi

      shell="${index_to_shell["${index}"]}"
      if [[ -n ${shell} ]]; then
        selections+=("${shell}")
      else
        logging::log_warn "No shell mapped to index: ${index}"
      fi
    done
  fi

  for shell in "${selections[@]}"; do
    selected_shells_ref["${shell}"]="${enabled_shell_rc_map_ref["${shell}"]}"
  done
}

# shell::print_selected_shells <selected-map>
#   Log each shell and its RC file that will be patched.
shell::print_selected_shells() {
  local -n selected_shells_ref="${1}"

  for shell in "${!selected_shells_ref[@]}"; do
    local rc_file="${selected_shells_ref["${shell}"]}"
    logging::log_info "Would update ${shell} RC file at ${rc_file}"
  done
}

chezmoi::load_helpers() {
  if ! command -v chezmoi > /dev/null || ! command -v jq > /dev/null; then
    return 1
  fi

  chezmoi::get_managed_mappings() {
    chezmoi managed -i files -p all -f json \
      | jq -er 'to_entries[] | [.value.absolute, .value.sourceAbsolute] | @tsv'
  }

  chezmoi::populate_map() {
    local -n chezmoi_map_ref="${1}"

    local output
    if ! output="$(chezmoi::get_managed_mappings)"; then
      logging::log_warn "chezmoi::get_managed_mappings failed"
      return 1
    fi

    while IFS=$'\t' read -r real source; do
      [[ -z ${real} || -z ${source} ]] && continue
      chezmoi_map_ref["${real}"]="${source}"
    done <<< "${output}"
  }
  return 0
}

resolve_all_rc_files() {
  local -n input_shells_ref="${1}"
  local -n output_files_ref="${2}"
  local -i check_chezmoi=0

  # If chezmoi::load_helpers returns 0 chezmoi is installed
  # and the functions we need for this are available, so we load the map.
  if chezmoi::load_helpers; then
    local -A chezmoi_map
    chezmoi::populate_map chezmoi_map
    # XXX: maybe double-check that the mapping is populated here
    ((++check_chezmoi))
  else
    logging::log_info "Chezmoi not installed... skipping chezmoi management checks."
  fi

  for shell in "${!input_shells_ref[@]}"; do
    local rc_path resolved_rc_path final_rc_path

    rc_path="${input_shells_ref["${shell}"]}"
    resolved_rc_path="$(resolve_file_path "${rc_path}")"

    # check chezmoi only if it's needed
    if ((check_chezmoi == 1)); then
      local chezmoi_file="${chezmoi_map["${resolved_rc_path}"]-}"

      if [[ -n ${chezmoi_file:-} && -f ${chezmoi_file:-} ]]; then
        final_rc_path="${chezmoi_file}"
      else
        final_rc_path="${resolved_rc_path}"
      fi
    else
      final_rc_path="${resolved_rc_path}"
    fi

    output_files_ref["${shell}"]="${final_rc_path}"
  done
}

# Ensure the systemd user directory exists.
prepare_service_dir() {
  mkdir -p -- "${SERVICE_DIR}" # Avoid race conditions like a smart cookie
  logging::log_info "Service directory ensured: ${SERVICE_DIR}"
}

# Symlink the ssh-agent.service template.
link_agent() {
  if [[ -f ${AGENT_SERVICE_SRC} ]]; then
    # XXX: switch to using install?
    ln -nfs -- "${AGENT_SERVICE_SRC}" "${SERVICE_DIR}/ssh-agent.service"
    logging::log_info "Linked ssh-agent.service"
  else
    logging::log_fatal "Template missing: ${AGENT_SERVICE_SRC}"
  fi
}

# Expand '~' in key paths because ssh-add is dumb.
# Also make sure each key actually exists and is readable.
validate_keys() {
  local -r _dest="${1}"
  local -n keys_ref="${_dest}"

  local key

  for i in "${!keys_ref[@]}"; do
    key="${keys_ref[i]}"
    [[ ${key} == ~* ]] && key="${key/#\~/${HOME}}"
    if [[ ! -r ${key} ]]; then
      logging::log_fatal "SSH key not found or unreadable: ${key}"
    fi
    keys_ref[i]="${key}"
  done
}

# Build ssh-add.service by injecting ExecStart lines with awk.
generate_add_service() {
  local -r _dest="${1}"
  local -n keys_ref="${_dest}"

  local keys_concat ssh_add_bin

  # join keys into a newline-separated string for awk
  keys_concat=$(printf '%s\n' "${keys_ref[@]}")
  ssh_add_bin=$(command -pv ssh-add) || {
    logging::log_fatal "ssh-add not found.. Why are you running an ssh-add script?"
  }

  # XXX: this could probably be perl (dark magic)
  awk \
    -v keys="${keys_concat}" \
    -v ssh_add="${ssh_add_bin}" '
		BEGIN {
			# Split newline-separated keys into array
			n = split(keys, arr, "\n")
		}

		# When we hit the magic comment line, POOF! in goes
		# the ExecStart lines with our SSH key files
		$0 == "# INSERT KEYS HERE" {
			for (i = 1; i <= n; i++)
				printf("ExecStart=%s %s\n", ssh_add, arr[i])
			next
		}
		# Leave the other lines alone
		{ print }
	' "${TEMPLATE_ADD_SERVICE}" > "${FINAL_ADD_SERVICE}"

  chmod 600 "${FINAL_ADD_SERVICE}"
  logging::log_info "Created ssh-add.service with keys: \"${keys_ref[*]}\""
}

# Prompt the user to create the RC file if it is missing.
handle_missing_rc_file() {
  local -r rc_file="${1}"
  local -r export_line="${2}"

  read -rp "RC file '${rc_file}' does not exist. Create it? [y/N] " create_rc
  case "${create_rc@L}" in
    y | yes)
      touch -- "${rc_file}"
      logging::log_info "Created new RC file: ${rc_file}"
      return 0
      ;;
    *)
      echo
      logging::log_warn "Skipped creating ${rc_file}."
      cat <<- __WAKE_UP_SUNSHINE__

To enable SSH agent support for this shell, add following lines to ${rc_file}:

# This agent is brought to you by ssh-agent-setup (by peppapig450)
${export_line}

__WAKE_UP_SUNSHINE__
      return 1
      ;;
  esac
}

# Append SSH_AUTH_SOCK export to shell RC if missing.
patch_shell_rc() {
  local -n rc_files_to_patch="${1}"
  local export_line='export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"'

  for shell in "${!rc_files_to_patch[@]}"; do
    local rc_file="${rc_files_to_patch["${shell}"]}"
    logging::log_info "Setting up SSH_AUTH_SOCK for ${shell}"

    if [[ ! -f ${rc_file} ]]; then
      handle_missing_rc_file "${rc_file}" "${export_line}" || {
        logging::log_warn "Skipped configuring SSH_AUTH_SOCK for ${shell} (no RC file)."
        continue
      }
    fi

    if ! grep -qxF "${export_line}" "${rc_file}"; then
      cat <<- BOOM_SHAKALAKA >> "${rc_file}"
  
# Added by ssh-agent-setup
${export_line}
BOOM_SHAKALAKA
      logging::log_info "Appended SSH_AUTH_SOCK to ${rc_file}"
    else
      logging::log_info "SSH_AUTH_SOCK already configured in ${rc_file}"
    fi
  done
}

# Reload user daemon and enable/start services.
reload_and_start() {
  systemctl --user daemon-reload
  systemctl --user enable --now ssh-agent.service ssh-add.service
  logging::log_info "Enabled and started ssh-agent & ssh-add services"
}

# main:
# 1) setup logging
# 2) build and filter shell -> rc map
# 3) prompt user for shells
# 4) generate systemd services & patch RCs
# 5) reload and start
main() {
  local -a keys=() # Pass keys around via nameref
  local -A shell_rc_map
  local -A enabled_shell_rc_map
  local -A selected_shells
  local -A resolved_rc_files_to_patch

  source_and_setup_logging
  
  if ! [[ -t 0 ]]; then
    logging::log_fatal "This script must be run interactively (stdin is not a tty)."
  fi

  parse_args keys "$@"
  check_dependencies
  init_paths
  prepare_service_dir
  link_agent
  validate_keys keys
  generate_add_service keys

  shell::init_shell_rc_map shell_rc_map
  shell::get_enabled_shells shell_rc_map enabled_shell_rc_map
  shell::prompt_user_selection enabled_shell_rc_map selected_shells || {
    logging::log_warn "Shell selection aborted. Exiting."
    exit 0
  }
  shell::print_selected_shells selected_shells

  resolve_all_rc_files selected_shells resolved_rc_files_to_patch
  patch_shell_rc resolved_rc_files_to_patch
  reload_and_start
}

# Make sure main is only ran if executed and not
# if it is sourced.
if ! (return 0 2> /dev/null); then
  main "$@"
fi
