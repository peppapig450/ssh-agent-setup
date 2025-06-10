#!/usr/bin/env bash
# ==============================================================================
# logging.lib.sh — Logging utilities for Bash scripts
#
# This library provides timestamped, color-coded log output and error handling
# utilities suitable for CI pipelines or general-purpose scripting.
#
# Features:
#   - Structured log levels: INFO, WARN, ERROR
#   - Color-coded output to stderr
#   - Namespaced function names via `logging::` convention
#       - Uses some conventions from the Google Shell Style Guide:
#       - https://google.github.io/styleguide/shellguide.html
#       - Particularly the use of `namespace::function` for namespacing.
#   - Drop-in error trap handler and safe trap appender
#
# Usage:
#   source ./logging.lib.sh
#   logging::log_info "Things are fine"
#   logging::add_err_trap
#
# This file is intended to be sourced, not executed.
# ==============================================================================
set -Eeuo pipefail

# Bail if we're not being sourced
(return 0 2> /dev/null) || {
  printf "This script is meant to be sourced, not executed.\n" >&2
  exit 1
}

# helper: what’s our current shell?
_detect_shell() {
  # try /proc → otherwise ps
  if [ -r "/proc/$$/exe" ]; then
    basename "$(readlink /proc/$$/exe)"
  else
    basename "$(ps -p $$ -o comm= 2> /dev/null)"
  fi
}

# if not bash, complain and bail
if [ -z "${BASH_VERSION-}" ]; then
  shell="$(_detect_shell 2> /dev/null || echo unknown)"
  printf 'Error: this script requires Bash. You appear to be running in %s.\n' \
    "${shell}" >&2
  return 1
fi

# logging::log LEVEL MESSAGE
# Logs a message to stderr with UTC timestamp and color-coded level.
# Usage: logging::log INFO "Message"
# Note: For internal use by other logging functions.
logging::log() {
  local level="${1^^}" # Capitalize input for case-insensitive matching
  shift
  local ts script="${LOGGING_SCRIPT_NAME:-}"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local color_reset=$'\033[0m' # Use ANSI-C quoting
  local color

  # CI pipelines need more color...
  case "${level}" in
    INFO) color=$'\033[0;32m' ;;  # Green!
    WARN) color=$'\033[0;33m' ;;  # Yellow!
    ERROR) color=$'\033[0;31m' ;; # Red!
    *)
      printf "Invalid log level: %s\n" "${level}"
      exit 1
      ;;
  esac

  local -a fmt_parts args
  fmt_parts+=("%b" "[%s]" "[%s]") # Color, timestamp, level
  args+=("${color}" "${ts}" "${level}")

  if [[ -n ${script} ]]; then
    fmt_parts+=("[%s]") # Script name
    args+=("${script}")
  fi

  fmt_parts+=("%s%b\n")
  args+=("$*" "${color_reset}")

  # Send to stderr like a good log citizen
  LC_ALL=C printf "${fmt_parts[*]}" "${args[@]}" >&2
}

logging::log_info() { logging::log INFO "$@"; }
logging::log_warn() { logging::log WARN "$@"; }
logging::log_error() { logging::log ERROR "$@"; }
logging::log_fatal() {
  logging::log ERROR "$@"
  exit 1
}

# logging::init SCRIPT_NAME
# Initializes logging for the current script.
#
# Sets the global LOGGING_SCRIPT_NAME variable for log prefixing
# and automatically wires up both error (ERR) and exit (EXIT) traps.
# This enables consistent, script-tagged log output and ensures cleanup
# behavior runs even on graceful exits.
#
# Usage:
#   logging::init "$0"
#
# This should be called once after sourcing logging.lib.sh.
logging::init() {
  if (($# != 1)); then
    logging::log_warn "logging::init requires a script name argument."
    return 1
  fi

  local source_path="${1:-${BASH_SOURCE[1]}}"
  if [[ -n ${source_path} ]]; then
    declare -gx LOGGING_SCRIPT_NAME="$(basename "$(realpath "${source_path}")" 2> /dev/null || echo "(unknown)")"
  fi

  # Setup traps
  logging::setup_traps
}

# logging::trap_err_handler
# A trap-safe fatal error logger. Logs an error message with source and line,
# then exits the script. Use this in a trap, e.g.:
#   trap 'logging::trap_err_handler' ERR
logging::trap_err_handler() {
  logging::log_fatal "Unexpected fatal error in ${BASH_SOURCE[1]} on line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
}

# logging::add_err_trap
# Appends logging::trap_err_handler to an existing ERR trap without overwriting it.
# Uses Perl to safely parse and chain existing trap commands.
logging::add_err_trap() {
  local existing

  # Extract any existing ERR trap command.
  # This matches lines like: trap -- 'echo something' ERR
  # We use Perl because quoting rules in shell are cursed and sed can't be trusted.
  # This extracts the inner single-quoted command safely—even if it contains
  # spaces, quotes, or other fragile syntax.
  existing="$(perl -lne '
        # Match a line that starts with `trap -- '...command...' ERR`
        if (/^trap -- '\''([^'\'']*)'\'' ERR$/) {
            print "$1"; # Print just the command portion inside the single quotes
        }
    ' <<< "$(trap -p ERR)" || true)"

  if [[ -z ${existing:-} ]]; then
    trap -- 'logging::trap_err_handler' ERR
  else
    trap -- "$(printf '%s; logging::trap_err_handler' "$existing")" ERR
  fi
}

# logging::cleanup
# Unsets any global logging state (e.g., script name)
logging::cleanup() {
  unset LOGGING_SCRIPT_NAME
}

# logging::add_exit_trap
# Appends logging::cleanup to the EXIT trap without overwriting it.
logging::add_exit_trap() {
  local existing

  existing="$(perl -lne '
    if (/^trap -- '\''([^'\'']*)'\'' EXIT$/) {
      print "$1"
    }
  ' <<< "$(trap -p EXIT)" || true)"

  if [[ -z ${existing:-} ]]; then
    trap -- 'logging::cleanup' EXIT
  else
    trap -- "$(printf '%s; logging::cleanup' "$existing")" EXIT
  fi
}

# logging::setup_traps
# Sets up both ERR and EXIT traps for error logging and cleanup.
logging::setup_traps() {
  logging::add_err_trap
  logging::add_exit_trap
}
