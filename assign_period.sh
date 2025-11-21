#!/bin/bash
# TIMES Category Assigner for Siku Quanshu Corpus
# Do NOT use unless you have already finished downloading and committing stuff. 

CORPUS_ROOT="siku_quanshu_corpus/clean"
LOG_FILE="times_assignment.log"
BACKUP_DIR="backup_before_times_assignment"

echo "📚 TIMES Category Assigner Started"
echo "======================================"

# Create backup first (safety first!)
echo "💾 Creating backup of files..."
mkdir -p "$BACKUP_DIR"
find "$CORPUS_ROOT" -name "*.txt" -exec cp {} "$BACKUP_DIR" \; 2>/dev/null
echo "✅ Backup created in: $BACKUP_DIR"

# Foreign categories to map to nation names
declare -A FOREIGN_MAP=(
    ["日本漢文"]="日本"
    ["朝鮮漢文"]="朝鮮" 
    ["琉球漢文"]="琉球"
    ["越南漢文"]="越南"
)

# Function to extract period from folder structure
get_period_from_path() {
    local file_path="$1"
    
    # Get the directory path and split into components
    local dir_path=$(dirname "$file_path")
    local dir_components=()
    
    # Split path into components
    IFS='/' read -ra dir_components <<< "$dir_path"
    
    # Look for period in the last 3 directory levels
    local depth=${#dir_components[@]}
    local potential_period=""
    
    # Check parent directories (going up to 3 levels)
    for ((i=depth-1; i>=0 && i>=depth-3; i--)); do
        local component="${dir_components[i]}"
        
        # Skip if it's a known top-level category
        case "$component" in
            "clean"|"四庫全書"|"經部"|"史部"|"子部"|"集部"|"日本漢文"|"朝鮮漢文"|"琉球漢文"|"越南漢文")
                continue
                ;;
        esac
        
        # Check if this looks like a period/dynasty name
        if [[ "$component" =~ (唐|宋|元|明|清|五代|遼|金|西夏|春秋|戰國|秦|漢|魏晉|南北朝|隋|民國|中華人民共和國|日本|朝鮮|琉球|越南) ]]; then
            potential_period="$component"
            break
        fi
    done
    
    echo "$potential_period"
}

# Function to determine the appropriate TIMES value
determine_times_value() {
    local file_path="$1"
    local dir_path=$(dirname "$file_path")
    
    # Check for foreign categories first
    for foreign_cat in "${!FOREIGN_MAP[@]}"; do
        if [[ "$dir_path" == *"$foreign_cat"* ]]; then
            echo "${FOREIGN_MAP[$foreign_cat]}"
            return 0
        fi
    done
    
    # Try to extract from folder structure
    local folder_period=$(get_period_from_path "$file_path")
    if [ -n "$folder_period" ]; then
        echo "$folder_period"
        return 0
    fi
    
    # Default for 四庫全書 without period
    if [[ "$dir_path" == *"四庫全書"* ]]; then
        echo "清"
        return 0
    fi
    
    # Could not determine
    echo ""
}

# Function to add TIMES tag to file
add_times_tag() {
    local file="$1"
    local times_value="$2"
    
    # Create temporary file for safety
    local temp_file="${file}.tmp"
    
    # Process the file
    local times_added=false
    local has_author=false
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Check if we've reached the content (after metadata)
        if [[ "$line" =~ ^[^#] ]] && [ "$times_added" = false ]; then
            # We're at content, insert TIMES before content
            if [ "$has_author" = true ]; then
                echo "# TIMES: $times_value" >> "$temp_file"
            else
                # No AUTHOR line found, add both AUTHOR and TIMES
                echo "# AUTHOR: 佚名" >> "$temp_file"  
                echo "# TIMES: $times_value" >> "$temp_file"
            fi
            times_added=true
        fi
        
        # Check for existing AUTHOR line
        if [[ "$line" == "# AUTHOR:"* ]]; then
            has_author=true
        fi
        
        # Write the current line
        echo "$line" >> "$temp_file"
        
        # If this is the last metadata line before content, insert TIMES here
        if [[ "$line" == "# PAGE_TITLE:"* ]] && [ "$times_added" = false ]; then
            if [ "$has_author" = true ]; then
                echo "# TIMES: $times_value" >> "$temp_file"
            else
                echo "# AUTHOR: 佚名" >> "$temp_file"
                echo "# TIMES: $times_value" >> "$temp_file"
            fi
            times_added=true
        fi
        
    done < "$file"
    
    # Replace original file if we made changes
    if [ "$times_added" = true ]; then
        mv "$temp_file" "$file"
        echo "✅ Added TIMES: $times_value to $(basename "$file")" | tee -a "$LOG_FILE"
        return 0
    else
        rm -f "$temp_file"
        echo "❌ Failed to add TIMES to $(basename "$file")" | tee -a "$LOG_FILE"
        return 1
    fi
}

# Main processing loop
echo "🔍 Scanning for files without TIMES tags..."
processed_count=0
error_count=0

find "$CORPUS_ROOT" -name "*.txt" | while read -r file; do
    echo "Processing: $file" >> "$LOG_FILE"
    
    # Skip if file already has TIMES tag
    if grep -q "^# TIMES:" "$file"; then
        echo "⏩ Skipping (has TIMES): $(basename "$file")" >> "$LOG_FILE"
        continue
    fi
    
    # Determine the TIMES value
    times_value=$(determine_times_value "$file")
    
    if [ -z "$times_value" ]; then
        echo "❓ Could not determine period for: $file" | tee -a "$LOG_FILE"
        ((error_count++))
        continue
    fi
    
    # Add the TIMES tag
    if add_times_tag "$file" "$times_value"; then
        ((processed_count++))
    else
        ((error_count++))
    fi
    
done

echo "======================================"
echo "🎉 TIMES Assignment Complete!"
echo "📊 Files processed: $processed_count"
echo "❌ Errors: $error_count"
echo "📋 Detailed log: $LOG_FILE"
echo "💾 Backup available in: $BACKUP_DIR"
