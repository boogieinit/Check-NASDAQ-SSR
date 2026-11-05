#!/bin/bash
#
# CheckSSR.sh
#
# Pull SSR list from NASDAQ, interrogate for owned positions, notify
#
# To automate - schedule launchd (Mac) to run weekdays at 8:40am CT (just after the 9:30am ET open)
#
# Changelog:
# 20210227 - Created.
# 20210306 - Changed wget to curl. Now sending hits as attachment
# 20210307 - Added pre-flight check
# 20210308 - Optional to send results in body or as attachment
#            Added perl line to clean up $HITS so it can be cat'd into an email
# 20250514 - Updated for MacOS compatibility, improved error handling and security
# 20250522 - Added functionality to get a copy of the SSR list and report top 10 stocks
# 20261105 - Top 10 is now the 10 most recently listed (real date/time sort, newest first);
#            skips the NASDAQ footer row; ticker matching uses the Symbol column only
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

# Send a plain-text email to MAILTO.
# Uses msmtp when installed (authenticated SMTP, e.g. Gmail, configured in ~/.msmtprc),
# otherwise falls back to the system mail command, which often cannot deliver from a
# home network because outgoing port 25 is blocked.
send_mail() {
    local subject="$1"
    local body="$2"
    if command -v msmtp >/dev/null 2>&1; then
        printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
            "${MAILTO}" "${subject}" "${body}" | msmtp "${MAILTO}"
    else
        printf '%s\n' "${body}" | mail -s "${subject}" "${MAILTO}"
    fi
}

log "INFO" "Starting ${SCRIPT_NAME}"

# Configuration
CONFIG_DIR="${HOME}/.config/CheckSSR"
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
# Add one ticker symbol per line (lines starting with # are ignored)
# Example - remove the leading # to activate:
# AAPL
# MSFT
# GOOG
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
    
    # Make sure at least one ticker is present (comments and blank lines do not count)
    if ! grep -v '^#' "${STOCKS}" | grep -v '^$' | grep -q .; then
        log "ERROR" "Stock positions file has no tickers: ${STOCKS}"
        log "ERROR" "Add one ticker symbol per line (lines starting with # are ignored)"
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
        send_mail "SSR Check Failed" "Failed to download SSR file for ${TODAY}"
        exit 1
    fi
    
    # Check if file was received and has content
    if [[ ! -s "${SSRFILE_PATH}" ]]; then
        log "ERROR" "Downloaded SSR file is empty"
        send_mail "SSR Check Failed" "SSR file for ${TODAY} is empty"
        exit 1
    fi
    
    log "INFO" "Successfully downloaded SSR file"
}

save_ssr_list() {
    log "INFO" "Processing SSR list to extract the 10 most recently listed stocks"
    
    # Save header from original file
    head -n 1 "${SSRFILE_PATH}" > "${TOP10_PATH}"
    
    # Filter out warrants, then keep the 10 most recently listed stocks (newest first).
    # Trigger Time looks like "11/4/2026 9:30:00 AM", so it is converted to a sortable
    # YYYYMMDDhhmmss key first (a plain text sort puts 10:00 AM before 9:30 AM).
    # Rows whose last field is not a date/time are skipped, which drops the file's footer
    # line (a file-creation timestamp such as 20261104163025).
    grep -v "Warrant" "${SSRFILE_PATH}" |
    grep -v "Wt," |
    grep -v "Wts" |
    tail -n +2 |
    tr -d '\r' |
    awk -F, '$NF ~ /^[0-9]+\/[0-9]+\/[0-9][0-9][0-9][0-9] [0-9]+:[0-9][0-9]:[0-9][0-9] [AP]M$/ {
        split($NF, dt, " "); split(dt[1], d, "/"); split(dt[2], t, ":")
        h = t[1] % 12; if (dt[3] == "PM") h += 12
        printf "%04d%02d%02d%02d%02d%02d\t%s\n", d[3], d[1], d[2], h, t[2], t[3], $0
    }' |
    sort -t "$(printf '\t')" -r -k1,1 |
    head -n 10 |
    cut -f2- >> "${TOP10_PATH}"
    
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
        send_mail "Could not pull SSR file" "Rate limited by NASDAQ site"
        exit 1
    fi
    
    # Read stocks file and search for each valid ticker in the SSR list
    # Only process lines that don't start with # (comments)
    touch "${HITS_PATH}"
    while IFS= read -r ticker; do
        # Skip comments and empty lines
        [[ "${ticker}" =~ ^#.*$ || -z "${ticker}" ]] && continue
        
        # Match the ticker against the Symbol column only (first CSV field, exact match).
        # Searching the whole row also hit tickers that appear inside other security names
        # (e.g. SHOP matched "Direxion Sh Daily SHOP Bull 2x").
        if awk -F, -v t="${ticker}" '$1 == t { found = 1 } END { exit !found }' "${SSRFILE_PATH}"; then
            log "INFO" "Found match for ${ticker}"
            awk -F, -v t="${ticker}" '$1 == t' "${SSRFILE_PATH}" >> "${HITS_PATH}"
        fi
    done < <(grep -v '^#' "${STOCKS}" | grep -v '^$')
    
    log "INFO" "Search completed, found $(cut -d, -f1 "${HITS_PATH}" | sort -u | wc -l | tr -d ' ') matches"
}

notify() {
    log "INFO" "Preparing to send notification with SSR report"
    
    local match_count=0
    local top10_count=0
    
    # Check if we have matches for owned positions
    if [[ -s "${HITS_PATH}" ]]; then
        match_count=$(cut -d, -f1 "${HITS_PATH}" | sort -u | wc -l | tr -d ' ')
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
            email_body+="${top10_count} MOST RECENTLY LISTED ON SSR (newest first):\n"
            email_body+="===============================================\n"
            email_body+="$(perl -p -e 's/\r\n/\n/g' "${TOP10_PATH}")\n"
        else
            email_body+="No top stocks list available."
        fi
        
        # Send email with body content
        if ! send_mail "${MAILSUBJECT}" "$(echo -e "${email_body}")"; then
            log "ERROR" "Failed to send notification email"
            exit 1
        fi
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
