#!/bin/bash

# --- Configuration ---
BASE_DIR="/mas/robots/prg-egocom/EGOCOM/720p/5min_parts/"
OUTPUT_DIR="processed_videos"
NUM_GPUS=4

# --- Script Start ---
echo "Starting Face Recognition Batch Processing..."
echo "============================================="

# Check if the base directory exists
if [ ! -d "$BASE_DIR" ]; then
    echo "Error: Directory $BASE_DIR does not exist!"
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Step 1: Find all video files and group them by their common pattern
declare -A video_groups
echo "Grouping video files..."

# Loop through all .MP4 files (case-insensitive)
for f in "$BASE_DIR"/*.MP4; do
    if [ -f "$f" ]; then
        # Extract the pattern (e.g., day_1__con_1__person_1) from the filename
        filename=$(basename "$f")
        pattern=$(echo "$filename" | sed -E 's/vid_[0-9]+__(.*)_part[0-9]+\.MP4/\1/')
        
        # Add the file to its group
        if [[ -n "$pattern" && "$pattern" != "$filename" ]]; then
            video_groups["$pattern"]+="$f "
        fi
    fi
done

# Get the list of unique patterns (our job list)
mapfile -t patterns < <(printf "%s\n" "${!video_groups[@]}" | sort)
num_groups=${#patterns[@]}

if [ "$num_groups" -eq 0 ]; then
    echo "No valid video groups found to process."
    exit 1
fi

echo "Found $num_groups unique video groups to process."

# Step 2: Distribute the groups across the available GPUs
declare -a gpu_jobs
for ((i=0; i<NUM_GPUS; i++)); do
    gpu_jobs[$i]=""
done

for ((i=0; i<num_groups; i++)); do
    gpu_index=$((i % NUM_GPUS))
    # Add the pattern to the job list for that GPU, using a separator
    gpu_jobs[$gpu_index]+="${patterns[$i]};"
done

# Step 3: Launch parallel screen sessions for each GPU
echo "Launching $NUM_GPUS parallel screen sessions..."
echo "============================================="

for ((gpu=0; gpu<NUM_GPUS; gpu++)); do
    job_list=${gpu_jobs[$gpu]}
    if [ -z "$job_list" ]; then
        echo "[GPU $gpu] No jobs assigned. Skipping."
        continue
    fi

    session_name="face_rec_gpu${gpu}"
    log_file="${session_name}.log"
    
    # Create a temporary script for the screen session
    temp_script="${session_name}_run.sh"
    echo "#!/bin/bash" > "$temp_script"
    echo "echo '[GPU $gpu] Starting processing... Log file: $log_file'" >> "$temp_script"
    echo "IFS=';' read -ra patterns_to_process <<< \"$job_list\"" >> "$temp_script"
    # --- FIXED LINE: Added the missing closing double-quote ---
    echo "for pattern in \"\${patterns_to_process[@]}\"; do" >> "$temp_script"
    echo "    if [ -n \"\$pattern\" ]; then" >> "$temp_script"
    echo "        echo \"[GPU $gpu] --------------------------------------------------\"" >> "$temp_script"
    echo "        echo \"[GPU $gpu] Processing group: \$pattern\"" >> "$temp_script"
    echo "        CUDA_VISIBLE_DEVICES=$gpu python face_recognition_global_gallery.py \\" >> "$temp_script"
    echo "            --search_path \"$BASE_DIR\" \\" >> "$temp_script"
    echo "            --pattern_to_match \"\$pattern\" \\" >> "$temp_script"
    echo "            --output_dir \"$OUTPUT_DIR\"" >> "$temp_script"
    echo "    fi" >> "$temp_script"
    echo "done" >> "$temp_script"
    echo "echo \"[GPU $gpu] All assigned jobs are complete.\"" >> "$temp_script"
    
    chmod +x "$temp_script"

    # Launch the screen session in detached mode
    screen -dmS "$session_name" bash -c "./$temp_script &> $log_file"
    echo "Launched screen session '$session_name' for GPU $gpu. Log: $log_file"
done

echo "============================================="
echo "All processing jobs launched!"
echo "Use 'screen -ls' to see running sessions."
echo "Attach with 'screen -r $session_name' to monitor a specific GPU."
echo "Output files will be saved in: $OUTPUT_DIR/"
