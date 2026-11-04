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
# 20250522 - Added functionality to get a copy of the SSR list and report top 10 stocks
# 20250522 - Fixed email attachment functionality using mpack on MacOS
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

# Additional commands required for attachment mode
# (checked after the config is loaded so SENDSTYLE from the config is honored)
if [[ "${SENDSTYLE}" -eq 1 ]]; then
    REQUIRED_COMMANDS="${REQUIRED_COMMANDS} mpack"  # mpack is required for sending attachments on MacOS
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
MAILSUBJECT="SSR Report: Positions & Top 10 Stocks for ${TODAY}"
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
    TOP10_PATH="${TEMPDIR}/top10_ssr.txt"
    
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
            if [[ "${cmd}" == "mpack" ]]; then
                log "ERROR" "mpack is required for sending attachments on MacOS"
                log "ERROR" "Install using: brew install mpack"
                log "ERROR" "Alternatively, set SENDSTYLE=0 in ${CONFIG_FILE} to send emails without attachments"
            else
                log "ERROR" "On MacOS, install using: brew install ${cmd}"
            fi
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

save_ssr_list() {
    log "INFO" "Processing SSR list to extract top 10 stocks"
    
    # Save header from original file
    head -n 1 "${SSRFILE_PATH}" > "${TOP10_PATH}"
    
    # Filter out warrants and process to get top 10 stocks sorted by trigger time
    grep -v "Warrant" "${SSRFILE_PATH}" | 
    grep -v "Wt," | 
    grep -v "Wts" | 
    tail -n +2 | 
    sort -t ',' -k4,4 | 
    head -n 10 >> "${TOP10_PATH}"
    
    # Check if we successfully created the top 10 list
    if [[ ! -s "${TOP10_PATH}" ]]; then
        log "WARN" "Failed to create top 10 SSR list, file is empty"
    else
        local stock_count
        stock_count=$(($(wc -l < "${TOP10_PATH}") - 1)) # Subtract 1 for header
        log "INFO" "Created top 10 SSR list with ${stock_count} stocks"
    fi
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
    log "INFO" "Preparing to send notification with SSR report"
    
    local match_count=0
    local top10_count=0
    
    # Check if we have matches for owned positions
    if [[ -s "${HITS_PATH}" ]]; then
        match_count=$(wc -l < "${HITS_PATH}")
        log "INFO" "Found ${match_count} position matches on SSR list"
    else
        log "INFO" "No position matches found on SSR list"
    fi
    
    # Check if we have top 10 stocks list
    if [[ -s "${TOP10_PATH}" ]]; then
        top10_count=$(($(wc -l < "${TOP10_PATH}") - 1)) # Subtract 1 for header
        log "INFO" "Found ${top10_count} stocks in top 10 SSR list"
    else
        log "WARN" "Top 10 SSR list is empty or not available"
    fi
    
    # Always send notification with both hits (if any) and top 10 list
    log "INFO" "Sending notification email to ${MAILTO}"
    
    if [[ "${SENDSTYLE}" -eq 1 ]]; then
        # Send as attachments
        log "INFO" "Sending report as attachments"
        local email_body="SSR Report for ${TODAY}:\n\n"
        
        if [[ ${match_count} -gt 0 ]]; then
            email_body+="Found ${match_count} of your positions on the SSR list.\n"
            email_body+="See attachment for details.\n\n"
        else
            email_body+="None of your positions were found on the SSR list.\n\n"
        fi
        
        if [[ ${top10_count} -gt 0 ]]; then
            email_body+="Top ${top10_count} stocks on the SSR list are included as attachment."
        else
            email_body+="No top stocks list available."
        fi
        
        # Send email with body content
        local temp_email_file="${TEMPDIR}/email_body.txt"
        echo -e "${email_body}" > "${temp_email_file}"
        
        # Use mpack for attachments (MacOS compatible)
        log "INFO" "Using mpack to send email with attachments"
        
        # Build attachment list for mpack
        local attachment_files=""
        if [[ -s "${HITS_PATH}" ]]; then
            attachment_files+=" ${HITS_PATH}"
        fi
        
        if [[ -s "${TOP10_PATH}" ]]; then
            attachment_files+=" ${TOP10_PATH}"
        fi
        
        # Send email with attachments using mpack
        if ! mpack -s "${MAILSUBJECT}" -d "${temp_email_file}" ${attachment_files} "${MAILTO}"; then
            log "ERROR" "Failed to send email with attachments"
            log "ERROR" "Check that mpack is installed and configured correctly"
        fi
    else
        # Send in email body
        log "INFO" "Sending report in email body"
        local email_body="SSR Report for ${TODAY}:\n\n"
        
        # Add position matches if any
        if [[ ${match_count} -gt 0 ]]; then
            email_body+="YOUR POSITIONS ON SSR LIST:\n"
            email_body+="==========================\n"
            email_body+="$(perl -p -e 's/\r\n/\n/g' "${HITS_PATH}")\n\n"
        else
            email_body+="None of your positions were found on the SSR list.\n\n"
        fi
        
        # Add top 10 stocks
        if [[ ${top10_count} -gt 0 ]]; then
            email_body+="TOP ${top10_count} STOCKS ON SSR LIST:\n"
            email_body+="==========================\n"
            email_body+="$(perl -p -e 's/\r\n/\n/g' "${TOP10_PATH}")\n"
        else
            email_body+="No top stocks list available."
        fi
        
        # Send email with body content
        echo -e "${email_body}" | mail -s "${MAILSUBJECT}" "${MAILTO}"
    fi
    log "INFO" "Notification sent successfully"
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
save_ssr_list
search
notify

log "INFO" "SSR check complete"
# Note: Cleanup is handled automatically by the trap set in setup_temp_files
