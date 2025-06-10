# Bashing Logs

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

<detail>
<summary><strong>📋 Table of Contents</strong></summary>
* [Features](#features)
* [Quick Start](#quick-start)
* [Installation](#installation)
* [Requirements](#requirements)
* [API Reference](#api-reference)

  * [Core Logging Functions](#core-logging-functions)

    * [`logging::log_info MESSAGE`](#logginglog_info-message)
    * [`logging::log_warn MESSAGE`](#logginglog_warn-message)
    * [`logging::log_error MESSAGE`](#logginglog_error-message)
    * [`logging::log_fatal MESSAGE`](#logginglog_fatal-message)
  * [Initialization](#initialization)

    * [`logging::init SCRIPT_NAME`](#logginginit-script_name)
* [Advanced Functions](#advanced-functions)

  * [`logging::add_err_trap`](#loggingadd_err_trap)
  * [`logging::add_exit_trap`](#loggingadd_exit_trap)
  * [`logging::setup_traps`](#loggingsetup_traps)
* [The Trap Chaining Magic](#the-trap-chaining-magic)

  * [The Problem](#the-problem)
  * [The Solution](#the-solution)
* [Zero-Setup Error Diagnostics](#zero-setup-error-diagnostics)
* [Best Practices](#best-practices)

  * [1. Initialize Early](#1-initialize-early)
  * [2. Use Appropriate Log Levels](#2-use-appropriate-log-levels)
  * [3. Leverage Automatic Error Tracing](#3-leverage-automatic-error-tracing)
  * [4. Script Name Context](#4-script-name-context)
* [Log Format](#log-format)
* [Technical Implementation Details](#technical-implementation-details)

  * [Shell Detection](#shell-detection)
  * [Source-Only Execution](#source-only-execution)
  * [Strict Mode Compatible](#strict-mode-compatible)
* [Examples](#examples)

  * [CI Pipeline Script](#ci-pipeline-script)
  * [Error Recovery Script](#error-recovery-script)
  * [Multi-Script Coordination](#multi-script-coordination)
* [Contributing](#contributing)
* [License](#license)
* [Credits](#credits)
</details>

# logging.lib.sh

A robust, production-ready logging utility library for Bash scripts with automatic error tracing, safe trap chaining, and zero-setup crash diagnostics.

## Features

* 🎨 **Color-coded output** - INFO (green), WARN (yellow), ERROR (red) for better visibility in CI pipelines
* ⏰ **UTC timestamps** - ISO 8601 formatted timestamps for all log messages
* 🔍 **Automatic error tracing** - Zero-setup crash diagnostics with file, line number, and command information
* 🔗 **Safe trap chaining** - Perl-powered trap parsing that preserves existing ERR/EXIT handlers
* 📝 **Script name prefixing** - Optional script identification in log output
* 🛡️ **Defensive programming** - Shell detection, source-only execution, and strict error handling
* 🎯 **Namespace convention** - Google Shell Style Guide compliant `namespace::function` naming

## Quick Start

```bash
#!/usr/bin/env bash
source ./logging.lib.sh

# Initialize logging with your script name
logging::init "$0"

# Now any error will be automatically logged with context
logging::log_info "Starting deployment..."
logging::log_warn "Configuration file missing, using defaults"

# This will trigger the error trap with full diagnostics
false  # Simulated error
```

Output:

```
[2024-12-15T10:30:45Z][INFO][deploy.sh] Starting deployment...
[2024-12-15T10:30:46Z][WARN][deploy.sh] Configuration file missing, using defaults
[2024-12-15T10:30:47Z][ERROR][deploy.sh] Unexpected fatal error in deploy.sh on line 8: false
```

## Installation

Simply copy `logging.lib.sh` to your project and source it:

```bash
source /path/to/logging.lib.sh
```

### Requirements

* Bash 4.0+ (enforced at runtime)
* Standard Unix utilities: `date`, `basename`, `realpath`
* Perl (for safe trap parsing)

## API Reference

### Core Logging Functions

#### `logging::log_info MESSAGE`

Logs an informational message in green.

```bash
logging::log_info "Database connection established"
```

#### `logging::log_warn MESSAGE`

Logs a warning message in yellow.

```bash
logging::log_warn "Retrying operation, attempt 3/5"
```

#### `logging::log_error MESSAGE`

Logs an error message in red.

```bash
logging::log_error "Failed to connect to API endpoint"
```

#### `logging::log_fatal MESSAGE`

Logs an error message and exits with status 1.

```bash
logging::log_fatal "Critical configuration missing"
```

### Initialization

#### `logging::init SCRIPT_NAME`

Initializes the logging system with automatic error trapping and cleanup.

```bash
logging::init "$0"  # Recommended: use $0 for current script
```

This function:

* Sets the script name for log prefixing
* Installs error trap handler for automatic crash diagnostics
* Sets up cleanup on script exit
* Chains with any existing ERR/EXIT traps

### Advanced Functions

#### `logging::add_err_trap`

Manually adds the error trap handler. Called automatically by `logging::init`.

```bash
# Only needed if you want trap handling without full init
logging::add_err_trap
```

#### `logging::add_exit_trap`

Manually adds the cleanup handler. Called automatically by `logging::init`.

```bash
# Only needed for custom cleanup scenarios
logging::add_exit_trap
```

#### `logging::setup_traps`

Sets up both ERR and EXIT traps. Called automatically by `logging::init`.

## The Trap Chaining Magic

One of the most sophisticated features of this library is its ability to safely chain with existing trap handlers. Many logging libraries overwrite existing traps, breaking error handling in complex scripts.

### The Problem

Bash trap syntax is notoriously difficult to parse:

```bash
# Simple trap
trap 'echo "error"' ERR

# Complex trap with quotes and special characters
trap 'echo "Error in $0"; cleanup || true' ERR

# Multiple commands
trap 'cleanup; notify_admin; exit 1' ERR
```

### The Solution

This library uses Perl to safely parse existing trap output:

```perl
perl -lne '
    if (/^trap -- '\''([^'\'']*)'\'' ERR$/) {
        print "$1"
    }
'
```

This regex precisely extracts the command from `trap -p` output, handling:

* Escaped single quotes in the command
* Spaces and special characters
* Multiple commands separated by semicolons

The library then chains the existing handler with its own:

```bash
trap -- "existing_handler; logging::trap_err_handler" ERR
```

## Zero-Setup Error Diagnostics

After calling `logging::init`, any command that fails will automatically log:

1. **Source file** - Which script crashed
2. **Line number** - Exact line of the failure
3. **Failed command** - The actual command that caused the error

Example output:

```
[2024-12-15T10:30:47Z][ERROR][backup.sh] Unexpected fatal error in backup.sh on line 42: rsync -av /source/ /nonexistent/
```

## Best Practices

### 1. Initialize Early

Call `logging::init` as early as possible in your script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source ./logging.lib.sh
logging::init "$0"

# Rest of your script...
```

### 2. Use Appropriate Log Levels

* **INFO**: Normal operational messages
* **WARN**: Recoverable issues or important notices
* **ERROR**: Serious problems that need attention
* **FATAL**: Unrecoverable errors (script will exit)

### 3. Leverage Automatic Error Tracing

With `logging::init`, you don't need explicit error handling for most cases:

```bash
# Without logging.lib.sh
if ! command; then
    echo "Error: command failed" >&2
    exit 1
fi

# With logging.lib.sh - errors are automatically logged with context
command  # Any failure is logged with file:line:command
```

### 4. Script Name Context

The script name in logs helps identify issues in multi-script pipelines:

```
[2024-12-15T10:30:45Z][INFO][db-backup.sh] Starting backup...
[2024-12-15T10:30:46Z][INFO][s3-upload.sh] Uploading to S3...
[2024-12-15T10:30:47Z][ERROR][s3-upload.sh] Unexpected fatal error in s3-upload.sh on line 23: aws s3 cp
```

## Log Format

All logs follow this format:

```
[COLOR][TIMESTAMP][LEVEL][SCRIPT_NAME] MESSAGE[RESET]
```

* **COLOR**: ANSI color code based on level
* **TIMESTAMP**: ISO 8601 UTC timestamp (YYYY-MM-DDTHH\:MM\:SSZ)
* **LEVEL**: INFO, WARN, or ERROR
* **SCRIPT\_NAME**: Basename of the script (optional, set by `logging::init`)
* **MESSAGE**: Your log message
* **RESET**: ANSI reset code

All output goes to stderr, following Unix conventions.

## Technical Implementation Details

### Shell Detection

The library includes robust shell detection to ensure Bash compatibility:

```bash
# First tries /proc (Linux)
if [ -r "/proc/$$/exe" ]; then
    basename "$(readlink /proc/$$/exe)"
# Falls back to ps (macOS, BSD)
else
    basename "$(ps -p $$ -o comm= 2>/dev/null)"
fi
```

### Source-Only Execution

Prevents accidental direct execution:

```bash
(return 0 2>/dev/null) || {
    printf "This script is meant to be sourced, not executed.\n" >&2
    exit 1
}
```

### Strict Mode Compatible

Designed to work with Bash strict mode:

```bash
set -Eeuo pipefail
```

## Examples

### CI Pipeline Script

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source ./logging.lib.sh
logging::init "$0"

logging::log_info "Starting CI pipeline..."

# Build phase
logging::log_info "Building application..."
make build

# Test phase
logging::log_info "Running tests..."
if ! make test; then
    logging::log_warn "Some tests failed, checking if critical..."
    make test-critical || logging::log_fatal "Critical tests failed"
fi

# Deploy phase
logging::log_info "Deploying to staging..."
make deploy-staging

logging::log_info "Pipeline completed successfully"
```

### Error Recovery Script

```bash
#!/usr/bin/env bash
source ./logging.lib.sh
logging::init "$0"

for attempt in {1..3}; do
    logging::log_info "Connection attempt $attempt/3"
    
    if connect_to_service; then
        logging::log_info "Connected successfully"
        break
    else
        logging::log_warn "Connection failed, retrying..."
        sleep $((attempt * 2))
    fi
    
    if [ $attempt -eq 3 ]; then
        logging::log_fatal "Failed to connect after 3 attempts"
    fi
done
```

### Multi-Script Coordination

```bash
# main.sh
#!/usr/bin/env bash
source ./logging.lib.sh
logging::init "$0"

logging::log_info "Starting batch processing"

for script in process-*.sh; do
    logging::log_info "Executing $script"
    
    if ! ./"$script"; then
        logging::log_error "$script failed, continuing with others"
    fi
done

logging::log_info "Batch processing complete"
```

## Contributing

When contributing to this library:

1. Maintain the `namespace::function` naming convention
2. Ensure all functions are documented
3. Test trap chaining with complex existing handlers
4. Verify compatibility with `set -Eeuo pipefail`

## License

This project is licensed under the [MIT License](./LICENSE) — see the [LICENSE](./LICENSE) file for details.

## Credits

This library follows conventions from the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) and implements production-grade error handling suitable for CI/CD pipelines and critical automation tasks.

