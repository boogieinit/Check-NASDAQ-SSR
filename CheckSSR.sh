#!/bin/bash
#
# CheckSSR.sh
#
# Pull SSR list from NASDAQ, interrogate for owned positions, notify
#
# To automate - schedule launchd (Mac) to run weekdays at 5am CT
#
# Changelog:
# 20210227 - Created.
# 20210306 - Changed wget to curl. Now sending hits as attachment
# 20210307 - Added pre-flight check
# 20210308 - Optional to send results in body or as attachment
#            Added perl line to clean up $HITS so it can be cat'd into an email
# 20250514 - Updated for MacOS compatibility, improved error handling and security
#
# Info:
# NASDAQ URL: https://nasdaqtrader.com/dynamic/symdir/shorthalts/shorthaltsYYYYMMDD.txt
# The file is created by NASDAQ about 5am ET each day but can also be created after market close.
#
# Requires:
#   List of ticker symbols to look for (one ticker per line)
#   Configuration file with email settings


############################################
# Script setup
############################################

# Enable strict mode
set -euo pipefail

# Setup logging
SCRIPT_NAME=$(basename "$0")
LOG_DIR="${HOME}/Library/Logs/CheckSSR"
LOG_FILE="${LOG_DIR}/checkssr_$(date +%Y%m%d).log"

# Create log directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log "INFO" "Starting ${SCRIPT_NAME}"

# Configuration
CONFIG_DIR="${HOME}/.config/check-ssr"
CONFIG_FILE="${CONFIG_DIR}/config.sh"

# Default configuration values
WRKDIR="${HOME}/Documents/CheckSSR"  # default work directory
MAILTO=""                            # email to send notifications to
SENDSTYLE=1                          # 0=in body, 1=as attachment
REQUIRED_COMMANDS="curl mail"        # commands required by this script

# Load configuration if it exists
if [[ -f "${CONFIG_FILE}" ]]; then
    log "INFO" "Loading configuration from ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    # Create default config if it doesn't exist
    log "WARN" "Configuration file not found, creating default at ${CONFIG_FILE}"
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_FILE}" << EOL
# CheckSSR Configuration File
# Set your preferences below

# Working directory for temporary files
WRKDIR="${HOME}/Documents/CheckSSR"

# Email address to receive notifications
MAILTO="your.email@example.com"

# Email style: 0=in body, 1=as attachment
SENDSTYLE=1

# Path to your stock positions file
STOCKS="${HOME}/Documents/CheckSSR/positions.txt"
EOL
    log "ERROR" "Please edit ${CONFIG_FILE} to set your preferences then run again"
    exit 1
fi

# Validate configuration
if [[ -z "${MAILTO}" || "${MAILTO}" == "your.email@example.com" ]]; then
    log "ERROR" "Email address not configured. Please edit ${CONFIG_FILE}"
    exit 1
fi


# ----------------------------------------------- #
# -------------- SCRIPT VARIABLES -------------- #
# ----------------------------------------------- #

# Set global variables
TODAY=$(date +%Y%m%d)
MAINURL="https://www.nasdaqtrader.com/trader.aspx?id=ShortSaleCircuitBreaker"
FILEBASE="https://www.nasdaqtrader.com/dynamic/symdir/shorthalts"
SSRFILE="shorthalts${TODAY}.txt"
FILEURL="${FILEBASE}/${SSRFILE}"
MAILSUBJECT="Positions found on SSR for ${TODAY}"
TEMPDIR=""

# Create secure temporary files with predictable cleanup
setup_temp_files() {
    # Create working directory if it doesn't exist
    if [[ ! -d "${WRKDIR}" ]]; then
        log "INFO" "Creating working directory ${WRKDIR}"
        mkdir -p "${WRKDIR}" || {
            log "ERROR" "Failed to create working directory ${WRKDIR}"
            exit 1
        }
    fi
    
    # Check if we can write to the working directory
    if [[ ! -w "${WRKDIR}" ]]; then
        log "ERROR" "Cannot write to working directory ${WRKDIR}"
        exit 1
    fi
    
    # Create temporary files with secure naming
    TEMPDIR=$(mktemp -d "${WRKDIR}/ssr_check.XXXXXXXX") || {
        log "ERROR" "Failed to create temporary directory"
        exit 1
    }
    
    # Set temporary file paths
    SSRFILE_PATH="${TEMPDIR}/${SSRFILE}"
    HITS_PATH="${TEMPDIR}/hits.txt"
    
    # Setup trap to remove temporary files on exit
    trap 'log "INFO" "Cleaning up temporary files"; rm -rf "${TEMPDIR}"; log "INFO" "Script completed"' EXIT
    
    log "INFO" "Temporary files set up in ${TEMPDIR}"
}


preflight_check() {
    log "INFO" "Running preflight checks"

    # Check if running as root (unnecessary on personal machines but kept for safety)
    if [[ $UID -eq 0 ]]; then
        log "ERROR" "Script should not be run as root"
        exit 1
    fi

    # Check for required commands
    for cmd in ${REQUIRED_COMMANDS}; do
        if ! command -v "${cmd}" &> /dev/null; then
            log "ERROR" "${cmd} is required but not found"
            log "ERROR" "On MacOS, install using: brew install ${cmd}"
            exit 1
        fi
    done

    # Check for ticker list
    if [[ ! -f "${STOCKS}" ]]; then
        log "ERROR" "Stock positions file not found: ${STOCKS}"
        log "INFO" "Creating sample positions file"
        
        mkdir -p "$(dirname "${STOCKS}")"
        cat > "${STOCKS}" << EOL
# Add one ticker symbol per line
# Example:
AAPL
MSFT
GOOG
EOL
        log "ERROR" "Please edit ${STOCKS} with your positions and run again"
        exit 1
    fi

    # Validate stocks file content
    if [[ ! -s "${STOCKS}" ]]; then
        log "ERROR" "Stock positions file is empty: ${STOCKS}"
        exit 1
    fi
    
    # Check that positions file contains valid ticker symbols
    if grep -v '^#' "${STOCKS}" | grep -v '^$' | grep -Ev '^[A-Z0-9.-]+$'; then
        log "ERROR" "Stock positions file contains invalid ticker symbols"
        log "ERROR" "Each line should contain a single valid ticker symbol (letters, numbers, dots or hyphens)"
        exit 1
    fi
    
    log "INFO" "Preflight checks passed"
}

getfile() {
    log "INFO" "Retrieving SSR list from NASDAQ"
    
    # First request to handle SAMEORIGIN requirement
    log "DEBUG" "Making initial request to ${MAINURL}"
    if ! curl --max-time 30 --retry 3 --silent --fail --location "${MAINURL}" > /dev/null 2>&1; then
        log "WARN" "Initial request to NASDAQ failed, trying anyway"
    fi
    
    # Get the actual SSR file
    log "DEBUG" "Downloading SSR file from ${FILEURL}"
    if ! curl --max-time 30 --retry 3 --silent --fail --location "${FILEURL}" > "${SSRFILE_PATH}"; then
        log "ERROR" "Failed to download SSR file"
        mail -s "SSR Check Failed" "${MAILTO}" <<< "Failed to download SSR file for ${TODAY}"
        exit 1
    fi
    
    # Check if file was received and has content
    if [[ ! -s "${SSRFILE_PATH}" ]]; then
        log "ERROR" "Downloaded SSR file is empty"
        mail -s "SSR Check Failed" "${MAILTO}" <<< "SSR file for ${TODAY} is empty"
        exit 1
    fi
    
    log "INFO" "Successfully downloaded SSR file"
}


search() {
    log "INFO" "Searching for positions in SSR list"
    
    # Check for SAMEORIGIN error in response
    if grep -q "SAMEORIGIN" "${SSRFILE_PATH}"; then
        log "ERROR" "Received SAMEORIGIN error, possibly rate-limited by NASDAQ"
        mail -s "Could not pull SSR file" "${MAILTO}" <<< "Rate limited by NASDAQ site"
        exit 1
    fi
    
    # Read stocks file and search for each valid ticker in the SSR list
    # Only process lines that don't start with # (comments)
    touch "${HITS_PATH}"
    while IFS= read -r ticker; do
        # Skip comments and empty lines
        [[ "${ticker}" =~ ^#.*$ || -z "${ticker}" ]] && continue
        
        # Use word boundaries to avoid partial matches
        if grep -q "\<${ticker}\>" "${SSRFILE_PATH}"; then
            log "INFO" "Found match for ${ticker}"
            grep "\<${ticker}\>" "${SSRFILE_PATH}" >> "${HITS_PATH}"
        fi
    done < <(grep -v '^#' "${STOCKS}" | grep -v '^$')
    
    log "INFO" "Search completed, found $(wc -l < "${HITS_PATH}") matches"
}

notify() {
    log "INFO" "Checking if notifications should be sent"
    
    # Only send notification if matches were found
    if [[ -s "${HITS_PATH}" ]]; then
        log "INFO" "Sending notification email to ${MAILTO}"
        local match_count
        match_count=$(wc -l < "${HITS_PATH}")
        
        if [[ "${SENDSTYLE}" -eq 1 ]]; then
            # Send as attachment
            log "INFO" "Sending ${match_count} matches as attachment"
            echo "Found ${match_count} positions on NASDAQ SSR list for ${TODAY}" | 
                mail -s "${MAILSUBJECT}" -a "${HITS_PATH}" "${MAILTO}"
        else
            # Send in email body
            log "INFO" "Sending ${match_count} matches in email body"
            # Convert any Windows line endings to Unix format
            perl -p -e 's/\r\n/\n/g' "${HITS_PATH}" |
                mail -s "${MAILSUBJECT}" "${MAILTO}"
        fi
        log "INFO" "Notification sent successfully"
    else
        log "INFO" "No matches found, no notification sent"
    fi
}


####################################################
# Main execution
####################################################

# Execute the script functions in order
log "INFO" "Beginning SSR check for ${TODAY}"

# Set up temporary files and cleanup trap
setup_temp_files

# Run the process
preflight_check
getfile
search
notify

log "INFO" "SSR check complete"
# Note: Cleanup is handled automatically by the trap set in setup_temp_files
