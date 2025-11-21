#!/bin/bash
# 🚨 NUCLEAR OPTION - Isolated File Committer

# Configuration
COMMIT_SIZE=200  # Very small batches
SLEEP_TIME=30
MAX_RETRIES=3
LOG_FILE="nuclear_committer.log"

echo "🚨 NUCLEAR OPTION - Isolated Batch Committer" | tee "$LOG_FILE"
echo "==============================================" | tee -a "$LOG_FILE"

# Simple isolated logging
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Basic Git config
git config core.longpaths true
git config core.quotepath off

# ISOLATED file counting - no variable contamination
count_untracked_files() {
    # Write count to temporary file, then read it
    find . -type f -not -path "./.git/*" -not -path "./*.log" 2>/dev/null | wc -l > /tmp/file_count.txt
    cat /tmp/file_count.txt | tr -d ' '
}

# ISOLATED batch adding - no stdout contamination
add_files_isolated() {
    local batch_size=$1
    local added_count=0
    
    # Create clean file list
    find . -type f -not -path "./.git/*" -not -path "./*.log" 2>/dev/null | head -n $batch_size > /tmp/clean_files.txt
    
    while IFS= read -r file; do
        if [[ -n "$file" && -f "$file" ]]; then
            if git add "$file" 2>/dev/null; then
                added_count=$((added_count + 1))
                # Only log every 25 files to reduce noise
                if [[ $((added_count % 25)) -eq 0 ]]; then
                    echo "Progress: $added_count files" >> /tmp/add_progress.txt
                fi
            fi
        fi
    done < /tmp/clean_files.txt
    
    # Output progress if any
    if [[ -f /tmp/add_progress.txt ]]; then
        while IFS= read -r progress_line; do
            log "$progress_line"
        done < /tmp/add_progress.txt
        rm -f /tmp/add_progress.txt
    fi
    
    rm -f /tmp/clean_files.txt
    echo "$added_count"  # ONLY this echo goes to stdout
}

# Main commit function with complete isolation
safe_commit_cycle() {
    log "Counting files..."
    local total_files
    total_files=$(count_untracked_files)
    
    if [[ $total_files -eq 0 ]]; then
        log "No untracked files found"
        return 0
    fi
    
    log "Found $total_files untracked files total"
    
    local batch_size=$(( total_files < COMMIT_SIZE ? total_files : COMMIT_SIZE ))
    log "Processing batch of $batch_size files"
    
    log "Starting file addition..."
    local added_count
    added_count=$(add_files_isolated "$batch_size")
    
    log "Added $added_count files successfully"
    
    if [[ $added_count -eq 0 ]]; then
        log "No files were added in this batch"
        return 1
    fi
    
    # CLEAN commit message
    local commit_msg="Add $added_count files - batch $(date '+%Y%m%d_%H%M%S')"
    log "Committing: $commit_msg"
    
    if git commit -m "$commit_msg" 2>/dev/null; then
        log "Commit successful"
        
        # Push with retries
        for ((push_attempt=1; push_attempt<=MAX_RETRIES; push_attempt++)); do
            log "Push attempt $push_attempt/$MAX_RETRIES"
            if git push origin main 2>/dev/null; then
                log "✅ SUCCESS: Pushed $added_count files"
                return 0
            else
                log "Push failed attempt $push_attempt"
                sleep 10
            fi
        done
        
        log "❌ All push attempts failed"
        return 1
    else
        log "❌ Commit failed - resetting"
        git reset --quiet 2>/dev/null
        return 2
    fi
}

# Cleanup function
cleanup() {
    rm -f /tmp/file_count.txt /tmp/clean_files.txt /tmp/add_progress.txt
    log "Cleanup completed"
}

# Set trap for cleanup
trap cleanup EXIT

# Main loop
log "Starting isolated processing loop..."

while true; do
    log "=== Starting new cycle ==="
    
    safe_commit_cycle
    result=$?
    
    case $result in
        0) log "✅ Cycle completed successfully" ;;
        1) log "⚠️  No files to add" ;;
        2) log "❌ Commit failed" ;;
        *) log "❓ Unknown result: $result" ;;
    esac
    
    log "Waiting $SLEEP_TIME seconds..."
    echo "" >> "$LOG_FILE"
    sleep $SLEEP_TIME
done
