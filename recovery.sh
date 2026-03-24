#!/bin/bash

# OpenCode Session Crash Recovery Script
# Author: Assistant
# Date: March 14, 2026
# Purpose: Automatically detect and recover crashed OpenCode sessions
#
# =============================================================================
# HOW SESSION RECOVERY WORKS
# =============================================================================
#
# 1. SESSION IDENTIFICATION:
#    The script retrieves all sessions via `opencode session list --format json`.
#    Each session has an ID (e.g., "abc123") and an "updated" timestamp (epoch ms).
#
# 2. DETECTING RUNNING SESSIONS:
#    To avoid recovering sessions that are currently active, we use multiple methods:
#    - Scan running processes: `ps aux | grep opencode | grep --session`
#    - Check environment: $OPENCODE, $OPENCODE_PID, $OPENCODE_SESSION_ID
#    - Exclude sessions updated in the last 3 minutes (180 seconds)
#
# 3. CLUSTER DETECTION LOGIC:
#    When OpenCode crashes, multiple sessions typically stop updating around the
#    same time. The script groups sessions into "clusters" based on time gaps:
#
#    a) Sort all sessions by their "updated" timestamp (newest first)
#    b) Calculate time difference between consecutive sessions
#    c) If gap > 300 seconds (5 min), start a new cluster
#    d) Each cluster represents one crash event
#
#    Example:
#    Session A: updated at 10:00:00 (most recent)
#    Session B: updated at 10:00:05  (gap: 5s - same cluster)
#    Session C: updated at 09:55:00  (gap: 5min5s - NEW CLUSTER)
#    Session D: updated at 09:50:00  (gap: 5min - same cluster)
#
# 4. RECOVERY:
#    The most recent cluster is assumed to be the latest crash. Users can
#    interactively select older clusters if needed. Each session in the cluster
#    is launched with: opencode --session <session_id>
#
# =============================================================================

# Change to home directory to ensure consistent behavior
cd ~ 2>/dev/null || cd /home/primary

# More lenient error handling for GUI compatibility
set -uo pipefail

# Configuration
SCRIPT_VERSION="1.1.0"
DEFAULT_TIME_CLUSTER_THRESHOLD=300  # 5 minutes to identify crash clusters
DEFAULT_MAX_SESSIONS=15
DEFAULT_LAUNCH_DELAY=1.5  # seconds between launching sessions
LOG_FILE="/tmp/opencode_recovery.log"
TEMP_DIR="/tmp/opencode_recovery"

# Check bash version (pipefail requires bash 3+)
BASH_VERSION_MINOR=$(bash -c 'echo ${BASH_VERSINFO[1]}' 2>/dev/null || echo "0")
if [[ $BASH_VERSION_MINOR -lt 2 ]]; then
    echo "Warning: This script requires bash 3.0 or later"
fi

# Set locale for consistent sorting (avoid locale issues)
export LANG=C LC_ALL=C 2>/dev/null || true

# Color codes - only enable if stdout is a terminal
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    NC=''
fi

# Global variables
DRY_RUN=false
INTERACTIVE=false
VERBOSE=false
MAX_SESSIONS=$DEFAULT_MAX_SESSIONS
LAUNCH_DELAY=$DEFAULT_LAUNCH_DELAY
MODE="recover"

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
debug() { 
    if [[ "$VERBOSE" == true ]]; then
        log "DEBUG" "$@"
    fi
}

# Print colored output
print_status() { echo -e "${BLUE}[STATUS]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# Verify we're in a usable directory
verify_working_directory() {
    local current_dir
    current_dir=$(pwd 2>/dev/null)
    
    if [[ -z "$current_dir" ]]; then
        print_error "Cannot determine current working directory"
        return 1
    fi
    
    if [[ ! -r "$current_dir" ]]; then
        print_error "No read permission in: $current_dir"
        return 1
    fi
    
    debug "Working directory: $current_dir"
    return 0
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()
    
    if ! command -v opencode >/dev/null 2>&1; then
        missing_tools+=("opencode")
        print_info "opencode not found in PATH"
        print_info "Common install locations: ~/.local/bin, /usr/local/bin, ~/go/bin"
        print_info "Ensure opencode is installed and in your PATH"
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_tools+=("jq")
    fi
    
    if ! command -v ps >/dev/null 2>&1; then
        missing_tools+=("procps (ps)")
    fi
    
    if ! command -v grep >/dev/null 2>&1; then
        missing_tools+=("grep")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Ensure opencode is installed and in your PATH"
        print_info "For jq: sudo apt-get install jq"
        return 1
    fi
    
    if ! mkdir -p "$TEMP_DIR" 2>/dev/null; then
        print_error "Cannot create temp directory: $TEMP_DIR"
        return 1
    fi
    
    debug "All prerequisites satisfied"
    return 0
}

# Get current timestamp in milliseconds
current_timestamp_ms() {
    echo $(($(date +%s) * 1000))
}

# Get session data in JSON format
get_session_data() {
    local session_output
    session_output=$(opencode session list --format json 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        print_error "Failed to retrieve session data: $session_output"
        print_info "Make sure opencode is installed and running"
        exit 1
    fi
    
    # Verify output is valid JSON
    if ! echo "$session_output" | jq -e . >/dev/null 2>&1; then
        print_error "Invalid JSON response from opencode session list"
        debug "Response was: $session_output"
        exit 1
    fi
    
    # Check if sessions array is empty
    local session_count
    session_count=$(echo "$session_output" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$session_count" == "0" ]] || [[ "$session_count" == "null" ]]; then
        print_warning "No sessions found in opencode"
        echo "[]"
        return 0
    fi
    
    echo "$session_output"
}

# Get currently running opencode session IDs
get_running_sessions() {
    # Method 1: Check environment variables (most reliable when running inside opencode)
    local current_session_id=""
    if [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then
        current_session_id="$OPENCODE_SESSION_ID"
    fi
    
    # Method 2: Check parent process if running inside opencode
    if [[ -z "$current_session_id" ]]; then
        local our_pid=$$
        local parent_pid=$PPID
        if [[ -r "/proc/$parent_pid/cmdline" ]]; then
            local parent_cmd
            parent_cmd=$(tr '\0' ' ' < "/proc/$parent_pid/cmdline" 2>/dev/null || echo "")
            if echo "$parent_cmd" | grep -qE 'opencode|node'; then
                # Get sessions updated very recently (last 2 minutes) as likely active
                local recent_sessions
                recent_sessions=$(opencode session list --format json 2>/dev/null | \
                    jq -r 'sort_by(.updated) | reverse | .[] | select(.updated > ($now - 120000)) | .id' \
                    --argjson now "$(date +%s)000" 2>/dev/null || echo "")
                if [[ -n "$recent_sessions" ]]; then
                    echo "$recent_sessions"
                    return 0
                fi
            fi
        fi
    fi
    
    # Method 3: Look for opencode processes and match against recently updated sessions
    local running_pids
    running_pids=$(pgrep -f "opencode" 2>/dev/null || echo "")
    
    if [[ -n "$running_pids" ]]; then
        # Get sessions updated in last 3 minutes (likely active)
        local active_sessions
        active_sessions=$(opencode session list --format json 2>/dev/null | \
            jq -r 'sort_by(.updated) | reverse | .[] | select(.updated > ($now - 180000)) | .id' \
            --argjson now "$(date +%s)000" 2>/dev/null || echo "")
        if [[ -n "$active_sessions" ]]; then
            echo "$active_sessions"
            return 0
        fi
    fi
    
    # Fallback: just output current session if we have one
    if [[ -n "$current_session_id" ]]; then
        echo "$current_session_id"
    fi
}

# Convert timestamp to human readable format
timestamp_to_human() {
    local timestamp_ms=$1
    local seconds=$((timestamp_ms / 1000))
    date -d "@$seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown time"
}

# Find all crash clusters and let user choose
find_crash_clusters() {
    local session_data="$1"
    local current_time=$(current_timestamp_ms)
    local threshold=${2:-$DEFAULT_TIME_CLUSTER_THRESHOLD}
    
    # Get currently running sessions to exclude from crash detection
    local running_sessions_file="$TEMP_DIR/running_sessions"
    get_running_sessions > "$running_sessions_file"
    
    # Also get current session ID if we can determine it
    local current_session_id
    current_session_id=$(get_current_session_id 2>/dev/null || echo "")
    
    # Create temporary file for processing, excluding active sessions
    local temp_file=$(mktemp) || { print_error "Failed to create temporary file"; return 1; }
    trap "rm -f '$temp_file' 2>/dev/null || true" EXIT
    
    # Extract session IDs and timestamps, calculate time since update, excluding active sessions
    echo "$session_data" | jq -r '.[] | "\(.id) \(.updated)"' | \
        while read -r session_id updated_time; do
            # Skip if this is our current session
            if [[ -n "$current_session_id" ]] && [[ "$session_id" == "$current_session_id" ]]; then
                continue
            fi
            
            # Skip if session is currently running
            if grep -q "^${session_id}$" "$running_sessions_file" 2>/dev/null; then
                continue
            fi
            
            # Skip sessions updated very recently (likely current activity)
            # Exclude last few minutes to avoid including active sessions
            local time_since_update=$(( (current_time - updated_time) / 1000 ))
            if [[ $time_since_update -lt 180 ]]; then  # 3 minutes
                continue
            fi
            
            echo "$time_since_update $session_id $updated_time"
        done | sort -n > "$temp_file"
    
    # Check if we have any sessions left to analyze
    local session_count
    session_count=$(wc -l < "$temp_file" | tr -d ' ')
    if [[ $session_count -eq 0 ]]; then
        return 0
    fi
    
    # Find all clusters by looking for groups of sessions with similar update times
    local clusters=()  # Array to store cluster info
    local cluster_index=0
    local cluster_start_time=""
    local cluster_end_time=""
    local cluster_sessions=()
    local cluster_timestamps=()  # Store actual timestamps for human readable time
    
    # Read the sorted data (oldest first)
    while IFS=' ' read -r time_since session_id updated_time; do
        if [[ -z "$cluster_start_time" ]]; then
            cluster_start_time=$time_since
            cluster_end_time=$time_since
            cluster_sessions=("$session_id")
            cluster_timestamps=("$updated_time")
        else
            local time_diff=$((time_since - cluster_end_time))
            if [[ $time_diff -le $threshold ]]; then
                # Part of current cluster
                cluster_end_time=$time_since
                cluster_sessions+=("$session_id")
                cluster_timestamps+=("$updated_time")
            else
                # Save current cluster and start new one
                if [[ ${#cluster_sessions[@]} -ge 2 ]]; then  # Only save clusters with 2+ sessions
                    # Store cluster info using underscores to avoid colon issues
                    # Format: size_START_END_sessionList
                    local start_timestamp=${cluster_timestamps[0]}
                    local end_timestamp=${cluster_timestamps[-1]}
                    # Replace spaces with underscores to avoid parsing issues
                    local start_human=$(timestamp_to_human "$start_timestamp" | tr ' ' '_')
                    local end_human=$(timestamp_to_human "$end_timestamp" | tr ' ' '_')
                    local session_list=$(printf '%s,' "${cluster_sessions[@]}" | sed 's/,$//')
                    clusters+=("${#cluster_sessions[@]}_${start_human}_${end_human}_${session_list}")
                fi
                # Start new cluster
                cluster_start_time=$time_since
                cluster_end_time=$time_since
                cluster_sessions=("$session_id")
                cluster_timestamps=("$updated_time")
            fi
        fi
    done < "$temp_file"
    
    # Check the last cluster
    if [[ ${#cluster_sessions[@]} -ge 2 ]]; then
        local start_timestamp=${cluster_timestamps[0]}
        local end_timestamp=${cluster_timestamps[-1]}
        # Replace spaces with underscores
        local start_human=$(timestamp_to_human "$start_timestamp" | tr ' ' '_')
        local end_human=$(timestamp_to_human "$end_timestamp" | tr ' ' '_')
        local session_list=$(printf '%s,' "${cluster_sessions[@]}" | sed 's/,$//')
        clusters+=("${#cluster_sessions[@]}_${start_human}_${end_human}_${session_list}")
    fi
    
    # Clean up
    rm -f "$temp_file" 2>/dev/null || true
    
    # Output clusters (newest first by reversing the array)
    # clusters are built from oldest to newest, so reverse to get newest first
    if [[ ${#clusters[@]} -gt 0 ]]; then
        for (( idx=${#clusters[@]}-1 ; idx>=0 ; idx-- )); do
            echo "${clusters[idx]}"
        done
    fi
}

# Interactive cluster selection
select_crash_cluster() {
    local session_data="$1"
    local clusters_data="$2"
    
    # Convert clusters_data to array
    local clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && clusters+=("$line")
    done <<< "$clusters_data"
    
    if [[ ${#clusters[@]} -eq 0 ]]; then
        print_warning "No crash clusters found"
        return 1
    fi
    
    if [[ ${#clusters[@]} -eq 1 ]]; then
        # Only one cluster, auto-select it
        local cluster_info="${clusters[0]}"
        local session_list="${cluster_info#*:*:*:}"
        echo "$session_list" | tr ',' '\n'
        return 0
    fi
    
    # Multiple clusters - let user choose
    print_status "Multiple crash clusters detected. Please select which one to recover:"
    echo
    
    local index=1
    for cluster_info in "${clusters[@]}"; do
        local cluster_size="${cluster_info%%:*}"
        local remainder="${cluster_info#*:}"
        local start_time="${remainder%%:*}"
        local remainder="${remainder#*:}"
        local end_time="${remainder%%:*}"
        echo "$index) $cluster_size sessions from $start_time to $end_time"
        ((index++))
    done
    
    echo "$index) Cancel"
    echo
    
    local choice
    while true; do
        read -p "Select cluster to recover (1-$index): " -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $index ]]; then
            if [[ $choice -eq $index ]]; then
                # Cancel
                return 1
            fi
            # Get selected cluster
            local selected_cluster="${clusters[$((choice-1))]}"
            local session_list="${selected_cluster#*:*:*:}"
            echo "$session_list" | tr ',' '\n'
            return 0
        else
            print_warning "Please enter a valid number between 1 and $index"
        fi
    done
}

# Identify crash cluster based on session update timestamps (wrapper for backward compatibility)
identify_crash_cluster() {
    local session_data="$1"
    local current_time=$(current_timestamp_ms)
    
    # Find all clusters
    local clusters_data
    clusters_data=$(find_crash_clusters "$session_data")
    
    if [[ -z "$clusters_data" ]]; then
        return 0
    fi
    
    # For non-interactive mode, select the most recent cluster (first line)
    local clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && clusters+=("$line")
    done <<< "$clusters_data"
    
    if [[ ${#clusters[@]} -gt 0 ]]; then
        # Get the first (most recent) cluster
        local first_cluster="${clusters[0]}"
        local session_list="${first_cluster#*_}"
        session_list="${session_list#*_}"
        session_list="${session_list#*_}"
        echo "$session_list" | tr ',' '\n'
    fi
}

# Get current session ID if we're running inside opencode
get_current_session_id() {
    # Check if we're running inside opencode and can determine our session ID
    # This is a heuristic - we check if our parent process is opencode with a session
    local our_pid=$$
    local parent_pid=$PPID
    
    # Check parent process command line
    if [[ -r "/proc/$parent_pid/cmdline" ]]; then
        # Convert null-separated cmdline to space-separated for easier parsing
        local parent_cmd=$(tr '\0' ' ' < "/proc/$parent_pid/cmdline" 2>/dev/null || echo "")
        if echo "$parent_cmd" | grep -q '\--session'; then
            echo "$parent_cmd" | sed -E 's/.*--session ([^ ]+).*/\1/'
            return 0
        fi
    fi
    
    # Check environment variables
    if [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then
        echo "$OPENCODE_SESSION_ID"
        return 0
    fi
    
    # Could not determine current session ID
    echo ""
    return 1
}

# Get session update time
get_session_update_time() {
    local session_data="$1"
    local session_id="$2"
    echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .updated" 2>/dev/null || echo ""
}

# Filter sessions to recover (exclude running sessions and apply limits)
filter_sessions_to_recover() {
    local crash_sessions=("$@")
    local running_sessions_file="$TEMP_DIR/running_sessions"
    
    # Get currently running sessions
    get_running_sessions > "$running_sessions_file"
    
    # Also get current session ID (if we can determine it)
    local current_session_id
    current_session_id=$(get_current_session_id 2>/dev/null || echo "")
    
    # Get current timestamp to filter out very recent sessions
    local current_time
    current_time=$(current_timestamp_ms)
    
    # Get session data once for all sessions
    local session_data
    session_data=$(get_session_data)
    
    local filtered_sessions=()
    local count=0
    
    # Sort crash sessions by update time (oldest first) to prioritize older crashed sessions
    local sorted_crash_sessions=()
    for session_id in "${crash_sessions[@]}"; do
        local session_updated
        session_updated=$(get_session_update_time "$session_data" "$session_id")
        if [[ -n "$session_updated" ]] && [[ "$session_updated" != "null" ]]; then
            # Create array entry with timestamp and session ID
            sorted_crash_sessions+=("$session_updated:$session_id")
        else
            # Put sessions without timestamp at the end
            sorted_crash_sessions+=("9999999999999:$session_id")
        fi
    done
    
    # Sort by timestamp
    IFS=$'\n' sorted_crash_sessions=($(sort <<<"${sorted_crash_sessions[*]}"))
    unset IFS
    
    # Extract just the session IDs in sorted order
    local ordered_crash_sessions=()
    for entry in "${sorted_crash_sessions[@]}"; do
        local session_id="${entry#*:}"
        ordered_crash_sessions+=("$session_id")
    done
    
    for session_id in "${ordered_crash_sessions[@]}"; do
        if [[ $count -ge $MAX_SESSIONS ]]; then
            break
        fi
        
        # Skip if this is our current session
        if [[ -n "$current_session_id" ]] && [[ "$session_id" == "$current_session_id" ]]; then
            debug "Skipping session $session_id (this is our current session)"
            continue
        fi
        
        # Get session update time
        local session_updated
        session_updated=$(get_session_update_time "$session_data" "$session_id")
        
        # Skip sessions updated in the last 5 minutes (likely current or very recent)
        if [[ -n "$session_updated" ]] && [[ "$session_updated" != "null" ]]; then
            local time_since_update=$(( (current_time - session_updated) / 1000 ))
            if [[ $time_since_update -lt 300 ]]; then  # 5 minutes
                debug "Skipping session $session_id (updated very recently: ${time_since_update}s ago)"
                continue
            fi
        fi
        
        # Check if session is currently running
        if [[ -s "$running_sessions_file" ]] && grep -q "^${session_id}$" "$running_sessions_file" 2>/dev/null; then
            debug "Skipping session $session_id (currently running)"
            continue
        fi
        
        # If we get here, include this session
        filtered_sessions+=("$session_id")
        ((count++))
    done
    
    printf '%s\n' "${filtered_sessions[@]}"
}

# Display status information
show_status() {
    print_status "OpenCode Crash Recovery Status"
    echo "=========================================="
    
    # Get session data
    local session_data
    session_data=$(get_session_data) || { print_error "Failed to get session data"; return 1; }
    
    # Get current time
    local current_time
    current_time=$(current_timestamp_ms)
    
    # Identify crash cluster
    print_info "Analyzing session patterns..."
    local crash_sessions
    crash_sessions=($(identify_crash_cluster "$session_data"))
    
    if [[ ${#crash_sessions[@]} -eq 0 ]]; then
        print_warning "No crash cluster detected"
        return 0
    fi
    
    print_success "Detected crash cluster with ${#crash_sessions[@]} sessions"
    
    # Get running sessions
    local running_sessions
    running_sessions=($(get_running_sessions))
    
    print_info "Currently running sessions: ${#running_sessions[@]}"
    
    # Filter sessions to recover
    local sessions_to_recover
    sessions_to_recover=($(filter_sessions_to_recover "${crash_sessions[@]}"))
    
    print_info "Most recent cluster of sessions to recover: ${#sessions_to_recover[@]}"
    
    if [[ ${#sessions_to_recover[@]} -gt 0 ]]; then
        echo
        print_status "Most recent cluster of sessions that would be recovered:"
        for session_id in "${sessions_to_recover[@]}"; do
            local session_title
            session_title=$(echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .title")
            echo "  • $session_id: $session_title"
        done
        
        if [[ "$DRY_RUN" == false ]]; then
            echo
            print_info "Run with --recover to actually recover these sessions"
            print_info "Run with --dry-run to see exactly what would happen"
        fi
    else
        print_info "No sessions need recovery (all either running or limit reached)"
    fi
    
    echo
    print_info "Log file: $LOG_FILE"
}

# Recover crashed sessions
recover_sessions() {
    print_status "Starting OpenCode Crash Recovery"
    
    # Get session data
    local session_data
    session_data=$(get_session_data) || { print_error "Failed to get session data"; return 1; }
    
    # Identify crash cluster
    print_info "Identifying crash cluster..."
    local crash_sessions
    crash_sessions=($(identify_crash_cluster "$session_data"))
    
    if [[ ${#crash_sessions[@]} -eq 0 ]]; then
        print_warning "No crash cluster detected - nothing to recover"
        return 0
    fi
    
    print_success "Found ${#crash_sessions[@]} sessions in crash cluster"
    
    # Filter sessions to recover
    print_info "Filtering sessions to recover..."
    local sessions_to_recover
    sessions_to_recover=($(filter_sessions_to_recover "${crash_sessions[@]}"))
    
    local recovery_count=${#sessions_to_recover[@]}
    
    if [[ $recovery_count -eq 0 ]]; then
        print_info "No sessions need recovery (all either running or limit reached)"
        return 0
    fi
    
    # Confirmation for interactive mode
    if [[ "$INTERACTIVE" == true ]]; then
        echo
        print_warning "About to recover $recovery_count sessions:"
        for session_id in "${sessions_to_recover[@]}"; do
            local session_title
            session_title=$(echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .title")
            echo "  • $session_id: $session_title"
        done
        echo
        read -p "Continue with recovery? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Recovery cancelled by user"
            return 0
        fi
    fi
    
    # Perform recovery
    print_status "Recovering most recent crash cluster ($recovery_count sessions)..."
    local success_count=0
    local fail_count=0
    
    for session_id in "${sessions_to_recover[@]}"; do
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[DRY RUN] Would recover session: $session_id"
            ((success_count++))
        else
            print_info "Recovering session: $session_id"
            # Launch session in a new visible terminal
            local launch_success=false
            
            # Try different terminal emulators with setsid (ensures visible window)
            if command -v gnome-terminal >/dev/null 2>&1; then
                setsid gnome-terminal --title="OpenCode: $session_id" -- opencode --session "$session_id" && launch_success=true
            elif command -v konsole >/dev/null 2>&1; then
                setsid konsole --title="OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
            elif command -v xterm >/dev/null 2>&1; then
                setsid xterm -title "OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
            elif command -v kitty >/dev/null 2>&1; then
                setsid kitty --title="OpenCode: $session_id" opencode --session "$session_id" && launch_success=true
            elif command -v alacritty >/dev/null 2>&1; then
                setsid alacritty -t "OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
            else
                # Final fallback
                setsid opencode --session "$session_id" >/dev/null 2>&1 & launch_success=true
            fi
            
            if [[ "$launch_success" == true ]]; then
                print_success "  Launched successfully"
                ((success_count++))
                # Delay to avoid overwhelming the system and let terminals open properly
                sleep $DEFAULT_LAUNCH_DELAY
            else
                print_error "  Failed to launch"
                ((fail_count++))
            fi
        fi
    done
    
    echo
    if [[ "$DRY_RUN" == true ]]; then
        print_success "DRY RUN COMPLETE: Would have recovered $success_count sessions"
    else
        print_success "RECOVERY COMPLETE: $success_count sessions recovered, $fail_count failed"
    fi
    
    print_info "Log file: $LOG_FILE"
}

# Show usage information
show_usage() {
    echo "OpenCode Crash Recovery Script v$SCRIPT_VERSION"
    echo "Automatically detects and recovers crashed OpenCode sessions"
    echo
    echo "Usage: $0 [OPTIONS] MODE"
    echo
    echo "Modes:"
    echo "  --status, -s     Show crash recovery status (default)"
    echo "  --recover, -r    Actually recover crashed sessions"
    echo
    echo "Options:"
    echo "  --dry-run, -d    Show what would be done without actually doing it"
    echo "  --interactive, -i Interactive mode with user confirmation"
    echo "  --verbose, -v    Enable verbose output"
    echo "  --max-sessions N Limit number of sessions to recover (default: $DEFAULT_MAX_SESSIONS)"
    echo "  --delay N        Delay between launching sessions in seconds (default: $DEFAULT_LAUNCH_DELAY)"
    echo "  --help, -h       Show this help message"
    echo "  --version        Show version information"
    echo
    echo "Examples:"
    echo "  $0 --status                  # Show status of potential crash recovery"
    echo "  $0 --recover                 # Recover crashed sessions"
    echo "  $0 --dry-run --recover       # See what would be recovered"
    echo "  $0 --interactive --recover   # Recover with user confirmation"
}

# Show version information
show_version() {
    echo "OpenCode Crash Recovery Script v$SCRIPT_VERSION"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --status|-s)
                MODE="status"
                shift
                ;;
            --recover|-r)
                MODE="recover"
                shift
                ;;
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            --interactive|-i)
                INTERACTIVE=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --max-sessions)
                MAX_SESSIONS="$2"
                if ! [[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]]; then
                    print_error "Invalid max-sessions value: $MAX_SESSIONS"
                    exit 1
                fi
                shift 2
                ;;
            --delay)
                LAUNCH_DELAY="$2"
                if ! [[ "$LAUNCH_DELAY" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    print_error "Invalid delay value: $LAUNCH_DELAY"
                    exit 1
                fi
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Check if running interactively (not from a script or pipe)
is_interactive() {
    # More robust check for interactive mode
    if [[ -t 0 ]] && [[ -t 1 ]]; then
        return 0  # Standard interactive check
    fi
    
    # Additional checks for GUI environments
    if [[ -n "$DISPLAY" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
        # We're in a GUI environment, but check if we have proper stdin/stdout
        if [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]]; then
            return 0  # Likely interactive GUI terminal
        fi
    fi
    
    # Check if we're running in a known interactive environment
    if [[ -n "$OPENCODE_SESSION_ID" ]] || [[ -n "$SHELL" ]]; then
        # We're in a shell environment, likely interactive
        return 0
    fi
    
    return 1  # Not interactive
}

# Interactive mode for GUI usage
interactive_mode() {
    while true; do
        # Clear screen for better UX
        clear 2>/dev/null || echo -e "\033[2J\033[H"
        
        print_status "OpenCode Crash Recovery - Interactive Mode"
        echo "============================================="
        echo
        print_info "This script can help recover OpenCode sessions after a crash."
        echo
        
        # Quick analysis for summary only
        print_info "Analyzing sessions for crash recovery..."
        
        local session_data
        session_data=$(get_session_data) || { print_error "Failed to get session data"; return 1; }
        
        # Find all crash clusters (newest first)
        local clusters_data
        clusters_data=$(find_crash_clusters "$session_data")
        
        # DEBUG: Show raw clusters data
        debug "Raw clusters data:"
        debug "$clusters_data"
        
        local cluster_count=0
        if [[ -n "$clusters_data" ]]; then
            # Count non-empty lines only
            cluster_count=$(echo "$clusters_data" | grep -v "^$" | wc -l)
        fi
        
        if [[ $cluster_count -eq 0 ]]; then
            print_warning "No crash clusters detected"
        else
            print_success "Found $cluster_count crash cluster(s)"
            
            # Get running sessions
            local running_sessions
            running_sessions=($(get_running_sessions))
            
            print_info "Currently running sessions: ${#running_sessions[@]}"
            
            # For summary, show info about the most recent cluster
            local clusters=()
            while IFS= read -r line; do
                [[ -n "$line" ]] && clusters+=("$line")
            done <<< "$clusters_data"
            
            if [[ ${#clusters[@]} -gt 0 ]]; then
                local most_recent_cluster="${clusters[0]}"
                # Parse cluster data using underscore format: size_startTime_endTime_sessionList
                local cluster_size="${most_recent_cluster%%_*}"
                
                # Safety check - make sure it's a reasonable number
                if ! [[ "$cluster_size" =~ ^[0-9]+$ ]]; then
                    cluster_size="?"
                fi
                print_info "Most recent cluster: $cluster_size sessions (select option 3 to see all clusters)"
            fi
        fi
        
        echo
        print_status "What would you like to do?"
        echo "1) Live recovery - Actually recover the most recent crash cluster"
        echo "2) Dry run - See what would be recovered (choose cluster or most recent)"
        echo "3) View all crash clusters - See details of all detected crash clusters"
        echo "4) Interactive cluster selection - Choose which crash cluster to recover"
        echo "5) Restore any session - List all recoverable sessions (newest first) and pick one"
        echo "6) Exit"
        echo "i) About - Learn how the crash detection and recovery algorithm works"
        echo
        local choice
        read -p "Please select an option (1-6 or i for info): " -r choice
        
        case $choice in
            1)
                echo
                print_info "Starting live recovery of most recent crash cluster..."
                recover_sessions
                echo
                read -p "Press Enter to continue..."
                ;;
            2)
                echo
                echo "Dry run options:"
                echo "1) Most recent cluster"
                echo "2) Select specific cluster"
                echo
                local dry_run_choice
                read -p "Select option (1-2): " -r dry_run_choice
                
                if [[ "$dry_run_choice" == "2" ]]; then
                    echo
                    print_info "Select a cluster for dry run:"
                    echo
                    # Build clusters array from clusters_data (already newest first)
                    local clusters=()
                    while IFS= read -r line; do
                        [[ -n "$line" ]] && clusters+=("$line")
                    done <<< "$clusters_data"
                    
                    local cluster_index=1
                    for cluster_info in "${clusters[@]}"; do
                        local cluster_size="${cluster_info%%_*}"
                        local remainder="${cluster_info#*_}"
                        local start_time="${remainder%%_*}"
                        local remainder="${remainder#*_}"
                        local end_time="${remainder%%_*}"
                        echo "$cluster_index) $cluster_size sessions from $start_time to $end_time"
                        ((cluster_index++))
                    done
                    echo "$cluster_index) Cancel"
                    echo
                    local choice
                    read -p "Select cluster (1-$cluster_index): " -r choice
                    
                    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -lt $cluster_index ]]; then
                        local selected_cluster="${clusters[$((choice-1))]}"
                        local session_list="${selected_cluster#*_}"
                        session_list="${session_list#*_}"
                        session_list="${session_list#*_}"
                        
                        IFS=',' read -ra dry_run_sessions <<< "$session_list"
                        
                        if [[ ${#dry_run_sessions[@]} -gt 0 ]]; then
                            echo
                            print_info "Sessions in selected cluster (dry run - no filtering applied):"
                            local count=0
                            for sid in "${dry_run_sessions[@]}"; do
                                if [[ $count -ge 15 ]]; then
                                    print_info "... and $((${#dry_run_sessions[@]} - 15)) more sessions"
                                    break
                                fi
                                local stitle
                                stitle=$(echo "$session_data" | jq -r ".[] | select(.id == \"$sid\") | .title")
                                echo "  • $sid: $stitle"
                                ((count++))
                            done
                            echo
                            print_info "Total: ${#dry_run_sessions[@]} sessions in this cluster"
                        fi
                    else
                        print_info "Cancelled."
                    fi
                else
                    print_info "Running detailed dry-run analysis of most recent cluster..."
                    # Show detailed session information for dry run
                    local crash_sessions
                    crash_sessions=($(identify_crash_cluster "$session_data"))
                    
                    if [[ ${#crash_sessions[@]} -eq 0 ]]; then
                        print_warning "No crash cluster detected"
                    else
                        # Filter sessions to recover (again for display)
                        local detailed_sessions_to_recover
                        detailed_sessions_to_recover=($(filter_sessions_to_recover "${crash_sessions[@]}"))
                        
                        local detailed_recovery_count=${#detailed_sessions_to_recover[@]}
                        
                        if [[ $detailed_recovery_count -eq 0 ]]; then
                            print_info "No sessions need recovery (all either running or limit reached)"
                        else
                            echo
                            print_info "Sessions that would be recovered (most recent cluster):"
                            local count=0
                            for session_id in "${detailed_sessions_to_recover[@]}"; do
                                if [[ $count -ge 15 ]]; then
                                    print_info "... and $((detailed_recovery_count - 15)) more sessions"
                                    break
                                fi
                                local session_title
                                session_title=$(echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .title")
                                echo "  • $session_id: $session_title"
                                ((count++))
                            done
                        fi
                    fi
                fi
                echo
                print_info "Dry run analysis complete."
                echo
                read -p "Press Enter to continue..."
                ;;
            3)
                echo
                print_info "Displaying all detected crash clusters (newest first):"
                echo
                # Build clusters array from clusters_data (already newest first)
                local clusters=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && clusters+=("$line")
                done <<< "$clusters_data"
                
                local cluster_index=1
                for cluster_info in "${clusters[@]}"; do
                    # Parse using underscore format: size_startTime_endTime_sessionList
                    local cluster_size="${cluster_info%%_*}"
                    local remainder="${cluster_info#*_}"
                    local start_time="${remainder%%_*}"
                    local remainder="${remainder#*_}"
                    local end_time="${remainder%%_*}"
                    echo "$cluster_index) $cluster_size sessions from $start_time to $end_time"
                    ((cluster_index++))
                done
                echo
                print_info "Total clusters: ${#clusters[@]}"
                echo
                read -p "Press Enter to continue..."
                ;;
            4)
                echo
                print_info "Select a cluster to recover:"
                echo
                # Build clusters array from clusters_data (already newest first)
                local clusters=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && clusters+=("$line")
                done <<< "$clusters_data"
                
                local cluster_index=1
                for cluster_info in "${clusters[@]}"; do
                    # Parse using underscore format: size_startTime_endTime_sessionList
                    local cluster_size="${cluster_info%%_*}"
                    local remainder="${cluster_info#*_}"
                    local start_time="${remainder%%_*}"
                    local remainder="${remainder#*_}"
                    local end_time="${remainder%%_*}"
                    echo "$cluster_index) $cluster_size sessions from $start_time to $end_time"
                    ((cluster_index++))
                done
                echo "$cluster_index) Cancel"
                echo
                local choice
                read -p "Select cluster to recover (1-$cluster_index): " -r choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -lt $cluster_index ]]; then
                    # Get selected cluster
                    local selected_cluster="${clusters[$((choice-1))]}"
                    # Extract session IDs from the cluster
                    local session_list="${selected_cluster#*_}"
                    session_list="${session_list#*_}"  # Remove start time
                    session_list="${session_list#*_}"  # Remove end time
                    
                    # Convert comma-separated session IDs to array
                    local selected_sessions=()
                    IFS=',' read -ra selected_sessions <<< "$session_list"
                    
                    if [[ ${#selected_sessions[@]} -gt 0 ]]; then
                        echo
                        print_info "Sessions in selected cluster:"
                        for session_id in "${selected_sessions[@]}"; do
                            local session_title
                            session_title=$(echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .title")
                            echo "  • $session_id: $session_title"
                        done
                        
                        echo
                        read -p "Recover these sessions? (y/N): " -r confirm
                        if [[ "$confirm" =~ ^[Yy]$ ]]; then
                            # Directly recover the selected sessions
                            print_status "Starting OpenCode Crash Recovery"
                            
                            # Get session data
                            local session_data
                            session_data=$(get_session_data) || { print_error "Failed to get session data"; return 1; }
                            
                            local recovery_count=0
                            local fail_count=0
                            
                            print_info "Recovering selected cluster (${#selected_sessions[@]} sessions)..."
                            
                            for session_id in "${selected_sessions[@]}"; do
                                print_info "Recovering session: $session_id"
                                local launch_success=false
                                
                                # Try different terminal emulators with setsid (ensures visible window)
                                if command -v gnome-terminal >/dev/null 2>&1; then
                                    setsid gnome-terminal --title="OpenCode: $session_id" -- opencode --session "$session_id" && launch_success=true
                                elif command -v konsole >/dev/null 2>&1; then
                                    setsid konsole --title="OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
                                elif command -v xterm >/dev/null 2>&1; then
                                    setsid xterm -title "OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
                                elif command -v kitty >/dev/null 2>&1; then
                                    setsid kitty --title="OpenCode: $session_id" opencode --session "$session_id" && launch_success=true
                                elif command -v alacritty >/dev/null 2>&1; then
                                    setsid alacritty -t "OpenCode: $session_id" -e opencode --session "$session_id" && launch_success=true
                                else
                                    setsid opencode --session "$session_id" >/dev/null 2>&1 & launch_success=true
                                fi
                                
                                if [[ "$launch_success" == true ]]; then
                                    print_success "  Launched successfully"
                                    ((recovery_count++))
                                    sleep $DEFAULT_LAUNCH_DELAY
                                else
                                    print_error "  Failed to launch"
                                    ((fail_count++))
                                fi
                            done
                            
                            echo
                            print_success "RECOVERY COMPLETE: $recovery_count sessions recovered, $fail_count failed"
                        else
                            print_info "Recovery cancelled."
                        fi
                    fi
                else
                    print_info "Returning to main menu."
                fi
                echo
                read -p "Press Enter to continue..."
                ;;
            5)
                echo
                print_info "Listing all recoverable sessions (newest first)..."
                
                # Get all session data
                local session_data
                session_data=$(get_session_data) || { print_error "Failed to get session data"; return 1; }
                
                # Get currently running sessions to exclude them
                local running_sessions_file="$TEMP_DIR/running_sessions"
                get_running_sessions > "$running_sessions_file"
                
                # Get current session ID if any
                local current_session_id
                current_session_id=$(get_current_session_id 2>/dev/null || echo "")
                
                # Current timestamp for freshness filter
                local current_time
                current_time=$(current_timestamp_ms)
                
                # Build list of all sessions with their update time
                local all_sessions=()
                while IFS= read -r session_id; do
                    # Skip empty lines
                    [[ -z "$session_id" ]] && continue
                    
                    # Skip if this is our current session
                    if [[ -n "$current_session_id" ]] && [[ "$session_id" == "$current_session_id" ]]; then
                        continue
                    fi
                    
                    # Skip if session is currently running
                    if grep -q "^${session_id}$" "$running_sessions_file" 2>/dev/null; then
                        continue
                    fi
                    
                    # Get update time
                    local updated
                    updated=$(get_session_update_time "$session_data" "$session_id")
                    
                    # Skip if updated too recently (< 3 minutes)
                    if [[ -n "$updated" ]] && [[ "$updated" != "null" ]]; then
                        local time_since=$(( (current_time - updated) / 1000 ))
                        if [[ $time_since -lt 180 ]]; then
                            continue
                        fi
                    fi
                    
                    # Store with timestamp for sorting
                    if [[ -n "$updated" ]] && [[ "$updated" != "null" ]]; then
                        all_sessions+=("$updated:$session_id")
                    else
                        # Put sessions without timestamp at the end
                        all_sessions+=("0:$session_id")
                    fi
                done < <(echo "$session_data" | jq -r '.[].id')
                
                # Sort by timestamp descending (newest first)
                IFS=$'\n' all_sessions=($(sort -r <<<"${all_sessions[*]}"))
                unset IFS
                
                # Extract just the session IDs in sorted order
                local sorted_ids=()
                for entry in "${all_sessions[@]}"; do
                    sorted_ids+=("${entry#*:}")
                done
                
                if [[ ${#sorted_ids[@]} -eq 0 ]]; then
                    print_warning "No recoverable sessions found."
                    echo
                    read -p "Press Enter to continue..."
                    break
                fi
                
                # Display up to 50 sessions (configurable)
                local display_limit=50
                echo
                print_info "Recoverable sessions (newest first):"
                local index=1
                for session_id in "${sorted_ids[@]}"; do
                    if [[ $index -gt $display_limit ]]; then
                        print_info "... and $((${#sorted_ids[@]} - $display_limit)) more sessions (not shown)"
                        break
                    fi
                    local title
                    title=$(echo "$session_data" | jq -r ".[] | select(.id == \"$session_id\") | .title")
                    local updated
                    updated=$(get_session_update_time "$session_data" "$session_id")
                    local time_ago=""
                    if [[ -n "$updated" ]] && [[ "$updated" != "null" ]]; then
                        local seconds=$(( (current_time - updated) / 1000 ))
                        if [[ $seconds -lt 60 ]]; then
                            time_ago="${seconds}s ago"
                        elif [[ $seconds -lt 3600 ]]; then
                            time_ago="$((seconds/60))m ago"
                        else
                            time_ago="$((seconds/3600))h ago"
                        fi
                    fi
                    printf "%3d) %s - %s [%s]\n" "$index" "$session_id" "$title" "$time_ago"
                    ((index++))
                done
                echo
                echo "$index) Cancel"
                echo
                
                local pick
                read -p "Select session to recover (1-$index): " -r pick
                if [[ "$pick" =~ ^[0-9]+$ ]] && [[ $pick -ge 1 ]] && [[ $pick -lt $index ]]; then
                    local selected_id="${sorted_ids[$((pick-1))]}"
                    echo
                    read -p "Recover session $selected_id? (y/N): " -r confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        # Launch the selected session
                        print_info "Recovering session: $selected_id"
                        local launch_success=false
                        if command -v gnome-terminal >/dev/null 2>&1; then
                            setsid gnome-terminal --title="OpenCode: $selected_id" -- opencode --session "$selected_id" && launch_success=true
                        elif command -v konsole >/dev/null 2>&1; then
                            setsid konsole --title="OpenCode: $selected_id" -e opencode --session "$selected_id" && launch_success=true
                        elif command -v xterm >/dev/null 2>&1; then
                            setsid xterm -title "OpenCode: $selected_id" -e opencode --session "$selected_id" && launch_success=true
                        elif command -v kitty >/dev/null 2>&1; then
                            setsid kitty --title="OpenCode: $selected_id" opencode --session "$selected_id" && launch_success=true
                        elif command -v alacritty >/dev/null 2>&1; then
                            setsid alacritty -t "OpenCode: $selected_id" -e opencode --session "$selected_id" && launch_success=true
                        else
                            setsid opencode --session "$selected_id" >/dev/null 2>&1 & launch_success=true
                        fi
                        
                        if [[ "$launch_success" == true ]]; then
                            print_success "Session launched."
                        else
                            print_error "Failed to launch session."
                        fi
                    else
                        print_info "Cancelled."
                    fi
                else
                    print_info "Returning to main menu."
                fi
                echo
                read -p "Press Enter to continue..."
                ;;
            6|"")
                echo
                print_info "Exiting..."
                return 0
                ;;
            i|I)
                echo
                echo "============================================================================"
                print_status "HOW THIS SCRIPT WORKS"
                echo "============================================================================"
                echo
                echo "1. SESSION DETECTION"
                echo "   The script retrieves all OpenCode sessions using:"
                echo "   \$ opencode session list --format json"
                echo "   Each session has an ID (e.g., 'abc123') and an 'updated' timestamp."
                echo
                echo "2. RUNNING SESSION EXCLUSION"
                echo "   To avoid recovering currently-active sessions, three methods are used:"
                echo "   a) Process scanning: looks for 'opencode --session' in running processes"
                echo "   b) Environment check: checks \$OPENCODE, \$OPENCODE_PID, \$OPENCODE_SESSION_ID"
                echo "   c) Timestamp filter: excludes sessions updated within the last 3 minutes"
                echo "      (configurable via SESSION_EXCLUDE_THRESHOLD)"
                echo
                echo "3. CRASH CLUSTER IDENTIFICATION"
                echo "   When OpenCode crashes (or sessions are rapidly closed), multiple sessions"
                echo "   stop updating around the same time. The script groups sessions into clusters"
                echo "   based on time gaps. Note: This detects ANY event where multiple sessions"
                echo "   stop updating together - not just crashes, but also intentional batch"
                echo "   closures, system shutdowns, or OOM kills."
                echo
                echo "   Algorithm:"
                echo "   - Sort all sessions by 'updated' timestamp (newest first)"
                echo "   - Calculate time difference between consecutive sessions"
                echo "   - If gap > 300 seconds (5 min), start a NEW cluster"
                echo "   - Each cluster represents one crash event"
                echo
                echo "   Example timeline:"
                echo "   Session A: 10:00:00  (most recent)"
                echo "   Session B: 10:00:05  (gap: 5s - same cluster)"
                echo "   Session C: 09:55:00  (gap: 5m05s - NEW CLUSTER)"
                echo "   Session D: 09:50:00  (gap: 5m - same cluster)"
                echo
                echo "4. CLUSTER FORMAT"
                echo "   Clusters are stored as: size_startTime_endTime_session1,session2,..."
                echo "   Example: '2_2026-03-14_10-00-00_abc123,def456'"
                echo "   (Underscores used instead of colons to avoid parsing issues)"
                echo
                echo "5. RECOVERY PROCESS"
                echo "   For each session in the selected cluster:"
                echo "   - Launch with: opencode --session <session_id>"
                echo "   - Add delay between launches (default: 1.5 seconds)"
                echo "   - Maximum sessions per run: 15 (configurable)"
                echo
                echo "6. OPTIONS EXPLAINED"
                echo "   1) Live recovery   - Actually launches the most recent crash cluster"
                echo "   2) Dry run          - Shows what WOULD be recovered without launching"
                echo "   3) View clusters    - Lists all detected crash events"
                echo "   4) Interactive      - Pick any cluster, not just the most recent"
                echo "   5) Restore any      - Pick any single session (newest first)"
                echo "   6) Exit             - Quit the program"
                echo
                echo "============================================================================"
                echo
                read -p "Press Enter to continue..."
                ;;
            *)
                print_warning "Invalid choice. Please select 1, 2, 3, 4, 5, 6, or i."
                sleep 2
                ;;
        esac
    done
}

# Main function
main() {
    # Verify we're in a usable directory first
    if ! verify_working_directory; then
        print_error "Working directory verification failed"
        exit 1
    fi
    
    # Parse arguments
    parse_args "$@"
    
    # Create temp directory
    mkdir -p "$TEMP_DIR" || { print_error "Failed to create temp directory"; exit 1; }
    
    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi
    
    # If no arguments provided and running interactively, use interactive mode
    if [[ $# -eq 0 ]] && is_interactive; then
        interactive_mode
        return $?
    fi
    
    # Execute based on mode
    case "$MODE" in
        "status")
            if ! show_status; then
                print_error "Failed to show status"
                exit 1
            fi
            ;;
        "recover")
            if [[ "$DRY_RUN" == true ]]; then
                if ! show_status; then
                    print_error "Failed to show status"
                    exit 1
                fi
            else
                if ! recover_sessions; then
                    print_error "Failed to recover sessions"
                    exit 1
                fi
            fi
            ;;
        *)
            print_error "Invalid mode: $MODE"
            show_usage
            exit 1
            ;;
    esac
}

# Only execute main if script is run directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
