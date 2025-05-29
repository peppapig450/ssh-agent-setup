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
  cat <<GET_YO_KEYS_WET
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
    if ! command -v "${cmd}" >/dev/null 2>&1; then
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
	' "${TEMPLATE_ADD_SERVICE}" >"${FINAL_ADD_SERVICE}"

  chmod 600 "${FINAL_ADD_SERVICE}"
  logging::log_info "Created ssh-add.service with keys: \"${keys_ref[*]}\""
}

# Append SSH_AUTH_SOCK export to shell RC if missing.
patch_shell_rc() {
  local shell_name rc_file export_line
  shell_name="$(basename "${SHELL:-bash}")"

  case "${shell_name}" in
    bash) rc_file="${HOME}/.bash_profile" ;;
    zsh) rc_file="${HOME}/.zprofile" ;;
    # XXX: this can be easily extended for fish, nu shell, or wtv...
    # IDK how to export vars in those shells though
    # and I don't use them so.
    *)
      logging::log_fatal "Unsupported shell: ${shell_name}"
      ;;
  esac

  # ensure RC file exists
  if [[ ! -f ${rc_file} ]]; then
    touch "${rc_file}"
    logging::log_info "Created shell rc file: ${rc_file}"
  fi

  # We don't want the $XDG_RUNTIME_DIR expanded until $rc_file is loaded.
  # So ignore shellcheck complaining about single quotes.
  # shellcheck disable=SC2016
  export_line='export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"'
  if ! grep -qxF "${export_line}" "${rc_file}"; then
    cat <<-BOOM_SHAKALAKA >>"${rc_file}"
			
			# Added by ssh-agent setup
			${export_line}
		BOOM_SHAKALAKA
    logging::log_info "Appended SSH_AUTH_SOCK to ${rc_file}"
  else
    logging::log_info "SSH_AUTH_SOCK already configured in ${rc_file}"
  fi
}

# Reload user daemon and enable/start services.
reload_and_start() {
  systemctl --user daemon-reload
  systemctl --user enable --now ssh-agent.service ssh-add.service
  logging::log_info "Enabled and started ssh-agent & ssh-add services"
}

# Main entrypoint.
main() {
  local -a keys=() # Pass keys around via nameref

  resolve_and_source_logging
  parse_args keys "$@"
  check_dependencies
  init_paths
  prepare_service_dir
  link_agent
  validate_keys keys
  generate_add_service keys
  patch_shell_rc
  reload_and_start
}

# Make sure main is only ran if executed and not
# if it is sourced.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
