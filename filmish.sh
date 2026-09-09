#!/usr/bin/env bash

set -euo pipefail

FPS=30
OUTPUT_FILE="filmish.mp4"
BATCH_MODE=0
INPUT_DIR=''
BATCH_DURATION=''
BATCH_TRANSITION='none'
BATCH_TRANSITION_TIME=''
BATCH_FPS=30
BATCH_FADE_IN=''
BATCH_FADE_OUT=''
BATCH_IMAGES=()
BATCH_HOLD_TIMES=()
BATCH_TRANSITION_NAMES=()
BATCH_TRANSITION_TIMES=()
OVERWRITE=0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

report_invalid_input() {
    local message=$1 attempt=$2 remaining attempt_word

    remaining=$((3 - attempt))
    if ((remaining > 0)); then
        attempt_word='attempts'
        ((remaining == 1)) && attempt_word='attempt'
        printf 'ERROR: %s Please try again (%d %s remaining).\n' \
            "$message" "$remaining" "$attempt_word" >&2
    else
        die "$message Three invalid attempts were entered."
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required program '$1' was not found."
}

check_ffmpeg_installation() {
    local missing=''

    command -v ffmpeg >/dev/null 2>&1 || missing=' ffmpeg'
    command -v ffprobe >/dev/null 2>&1 || missing+=" ffprobe"
    [[ -z $missing ]] && return 0

    printf 'ERROR: Required Homebrew tool(s) not found:%s\n' "$missing" >&2
    printf '%s\n' \
        '' \
        'Installation instructions:' \
        '  1. If Homebrew is not installed, visit: https://brew.sh' \
        '  2. Open Terminal and run:' \
        '' \
        '       brew install ffmpeg' \
        '' \
        '  3. After installation, open a new Terminal window and run this script again.' \
        '' \
        'Official FFmpeg formula: https://formulae.brew.sh/formula/ffmpeg' >&2
    exit 1
}

print_usage() {
    printf '%s\n' \
        'Usage:' \
        '  filmish' \
        '  filmish --input DIR --duration SECONDS [options]' \
        '' \
        'Batch-mode options:' \
        '  --input DIR              Image directory (default: current directory)' \
        '  --image FILE             Use FILE in this position (repeat for custom order)' \
        '  --duration SECONDS       Total duration in seconds, for example 10 or 10.5' \
        '  --fps RATE               24, 25, or 30 (default: 30)' \
        '  --hold-time SECONDS|auto Clear display time for one image; repeat for every image' \
        '  --transition NAME        FFmpeg xfade name or none (default: none)' \
        '  --transition-time TIME   Duration in decimal seconds, for example 1 or 1.2' \
        '  --transition-spec NAME SECONDS' \
        '                           Repeat once per image boundary for individual fades' \
        '  --fade-in SECONDS        Fade in from black (default duration in the UI: 1.0)' \
        '  --fade-out SECONDS       Fade out to black (default duration in the UI: 1.0)' \
        '  --output FILE            Output MP4 path (default: filmish.mp4)' \
        '  --overwrite              Replace an existing output file' \
        '  --help                   Show this help'
}

parse_cli_args() {
    if (($# == 0)); then
        return
    fi

    BATCH_MODE=1
    while (($# > 0)); do
        case "$1" in
            --input)
                (($# >= 2)) || die "--input requires a directory."
                INPUT_DIR=$2
                shift 2
                ;;
            --duration)
                (($# >= 2)) || die "--duration requires seconds."
                BATCH_DURATION=$2
                shift 2
                ;;
            --image)
                (($# >= 2)) || die "--image requires a file name."
                BATCH_IMAGES+=("$2")
                shift 2
                ;;
            --hold-time)
                (($# >= 2)) || die "--hold-time requires decimal seconds or auto."
                BATCH_HOLD_TIMES+=("$2")
                shift 2
                ;;
            --fps)
                (($# >= 2)) || die "--fps requires 24, 25, or 30."
                BATCH_FPS=$2
                shift 2
                ;;
            --transition)
                (($# >= 2)) || die "--transition requires a name or none."
                BATCH_TRANSITION=$2
                shift 2
                ;;
            --transition-time)
                (($# >= 2)) || die "--transition-time requires a value."
                BATCH_TRANSITION_TIME=$2
                shift 2
                ;;
            --transition-spec)
                (($# >= 3)) || die "--transition-spec requires a transition name and a time."
                BATCH_TRANSITION_NAMES+=("$2")
                BATCH_TRANSITION_TIMES+=("$3")
                shift 3
                ;;
            --fade-in)
                (($# >= 2)) || die "--fade-in requires a value."
                BATCH_FADE_IN=$2
                shift 2
                ;;
            --fade-out)
                (($# >= 2)) || die "--fade-out requires a value."
                BATCH_FADE_OUT=$2
                shift 2
                ;;
            --output)
                (($# >= 2)) || die "--output requires a file path."
                OUTPUT_FILE=$2
                shift 2
                ;;
            --overwrite)
                OVERWRITE=1
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                die "Unknown option '$1'. Use --help for usage."
                ;;
        esac
    done

    [[ -n $BATCH_DURATION ]] || die "Batch mode requires --duration."
    [[ $BATCH_DURATION =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        die "--duration must be a positive number of seconds, for example 10 or 10.5."
    awk -v value="$BATCH_DURATION" 'BEGIN { exit !(value > 0) }' ||
        die "--duration must be greater than zero."
    case "$BATCH_FPS" in
        24|25|30) ;;
        *) die "--fps must be 24, 25, or 30." ;;
    esac
    [[ -n $OUTPUT_FILE ]] || die "--output cannot be empty."
}

cleanup() {
    if [[ -n "${temp_dir:-}" && -d "$temp_dir" ]]; then
        rm -rf -- "$temp_dir"
    fi
}

is_image_name() {
    case "$1" in
        *.[Jj][Pp][Gg]|*.[Jj][Pp][Ee][Gg]|*.[Pp][Nn][Gg]|*.[Ww][Ee][Bb][Pp]|*.[Bb][Mm][Pp]|*.[Tt][Ii][Ff]|*.[Tt][Ii][Ff][Ff]) return 0 ;;
        *) return 1 ;;
    esac
}

probe_image_dimensions() {
    local file=$1 output line probe_path width height

    output=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=s=x:p=0 -- "$file" 2>/dev/null) || true
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9]+x[0-9]+$ ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done <<< "$output"

    if command -v sips >/dev/null 2>&1; then
        probe_path=$file
        [[ $probe_path == -* ]] && probe_path="./$probe_path"
        output=$(sips -g pixelWidth -g pixelHeight "$probe_path" 2>/dev/null) || true
        width=$(awk '/pixelWidth:/ { print $2; exit }' <<< "$output")
        height=$(awk '/pixelHeight:/ { print $2; exit }' <<< "$output")
        if [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]]; then
            printf '%sx%s\n' "$width" "$height"
            return 0
        fi
    fi

    return 1
}

sort_images() {
    local i j key

    # Bash provides locale-aware alphabetical ordering here. Avoiding a separate
    # sort process also preserves file names containing spaces or newlines.
    for ((i = 1; i < ${#images[@]}; i++)); do
        key=${images[i]}
        j=$((i - 1))
        while ((j >= 0)) && [[ ${images[j]} > "$key" ]]; do
            images[j + 1]=${images[j]}
            ((j--)) || true
        done
        images[j + 1]=$key
    done
}

read_frame_rate() {
    local value attempt message

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf '\nFrame rate (24, 25, or 30; Enter = 30): '
        IFS= read -r value || die "Input was interrupted."
        [[ -z $value ]] && value=30
        case "$value" in
            24|25|30)
                FPS=$value
                return
                ;;
            *)
                message="Frame rate must be 24, 25, or 30."
                report_invalid_input "$message" "$attempt"
                ;;
        esac
    done
}

read_total_seconds() {
    local value attempt message

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf '\nTotal MP4 duration in seconds (for example, 10 or 10.5): '
        IFS= read -r value || die "Input was interrupted."
        if [[ $value =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] &&
            awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
            total_seconds=$value
            return
        fi

        message="Total duration must be a positive number of seconds (for example, 10 or 10.5)."
        report_invalid_input "$message" "$attempt"
    done
}

load_transitions() {
    local name

    transitions=()
    while IFS= read -r name; do
        [[ -n $name ]] && transitions+=("$name")
    done < <(
        ffmpeg -hide_banner -h filter=xfade 2>&1 |
            awk '
                /^   transition / { list = 1; next }
                /^   duration /   { list = 0 }
                list && $1 != "custom" && $2 ~ /^[0-9]+$/ { print $1 }
            '
    )

    ((${#transitions[@]} > 0)) || die "Could not read the available xfade transitions from FFmpeg."
}

choose_transition() {
    local i choice attempt message

    printf '\nAvailable transitions:\n'
    printf '%3d) %s\n' 0 'none (hard cuts)'
    for ((i = 0; i < ${#transitions[@]}; i++)); do
        printf '%3d) %s\n' "$((i + 1))" "${transitions[i]}"
    done

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf 'Choose a transition by number (0 or Enter = none): '
        IFS= read -r choice || die "Input was interrupted."

        if [[ -z $choice || $choice == 0 ]]; then
            transition_name='none (hard cuts)'
            transition_enabled=0
            return
        elif [[ ! $choice =~ ^[0-9]+$ ]]; then
            message="Choose the transition using its list number."
        elif ((choice < 1 || choice > ${#transitions[@]})); then
            message="The transition number must be between 0 and ${#transitions[@]}, or press Enter for none."
        else
            transition_name=${transitions[choice - 1]}
            transition_enabled=1
            return
        fi

        report_invalid_input "$message" "$attempt"
    done
}

set_transition_time() {
    local value=$1 candidate_frames candidate_total max_transition_frames

    if ! is_positive_decimal "$value"; then
        transition_time_error="Use a positive number of seconds, for example 1 or 1.2."
        return 1
    fi

    candidate_frames=$(seconds_to_frames "$value")
    candidate_total=$((transition_count * candidate_frames))

    if ((candidate_frames == 0)); then
        transition_time_error="Transition duration is too short at $FPS fps."
        return 1
    elif ((total_frames - candidate_total < image_count)); then
        max_transition_frames=$(((total_frames - image_count) / transition_count))
        transition_time_error="That transition duration leaves no usable clear display time for every image. The approximate maximum is $(frames_to_seconds "$max_transition_frames") seconds."
        return 1
    fi

    transition_frames=$candidate_frames
    transition_display=$(frames_to_seconds "$candidate_frames")
    return 0
}

read_transition_time() {
    local value attempt

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf 'Duration of one transition in seconds (for example 1.2; Enter = 1.0): '
        IFS= read -r value || die "Input was interrupted."
        [[ -z $value ]] && value=1.0
        if set_transition_time "$value"; then
            return
        fi
        report_invalid_input "$transition_time_error" "$attempt"
    done
}

set_edge_fade_time() {
    local value=$1 target=$2 candidate_frames

    if ! is_positive_decimal "$value"; then
        edge_fade_time_error="Use a positive number of seconds, for example 1 or 1.2."
        return 1
    fi

    candidate_frames=$(seconds_to_frames "$value")
    if ((candidate_frames == 0)); then
        edge_fade_time_error="Fade duration is too short at $FPS fps."
        return 1
    elif ((candidate_frames > total_frames)); then
        edge_fade_time_error="Fade duration cannot be longer than the complete video."
        return 1
    fi

    if [[ $target == in ]]; then
        fade_in_frames=$candidate_frames
        fade_in_display=$(frames_to_seconds "$candidate_frames")
    else
        fade_out_frames=$candidate_frames
        fade_out_display=$(frames_to_seconds "$candidate_frames")
    fi
    return 0
}

read_yes_no() {
    local prompt=$1 result_variable=$2 value attempt message

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf '%s' "$prompt"
        IFS= read -r value || die "Input was interrupted."
        case "$value" in
            ''|[Nn]|[Nn][Oo]) printf -v "$result_variable" '%d' 0; return ;;
            [Yy]|[Yy][Ee][Ss]) printf -v "$result_variable" '%d' 1; return ;;
            *)
                message="Enter y for yes or n for no; Enter means no."
                report_invalid_input "$message" "$attempt"
                ;;
        esac
    done
}

read_edge_fades() {
    local value attempt

    printf '\nOptional edge fades (these do not change the total video duration):\n'
    read_yes_no 'Fade in from black at the start? (y/N): ' fade_in_enabled
    read_yes_no 'Fade out to black at the end? (y/N): ' fade_out_enabled
    if ((!fade_in_enabled && !fade_out_enabled)); then
        return 0
    fi

    for ((attempt = 1; attempt <= 3; attempt++)); do
        printf 'Edge fade duration in seconds (for example 1.2; Enter = 1.0): '
        IFS= read -r value || die "Input was interrupted."
        [[ -z $value ]] && value=1.0
        if ((fade_in_enabled)); then
            set_edge_fade_time "$value" in || {
                report_invalid_input "$edge_fade_time_error" "$attempt"
                continue
            }
        fi
        if ((fade_out_enabled)); then
            set_edge_fade_time "$value" out || {
                report_invalid_input "$edge_fade_time_error" "$attempt"
                continue
            }
        fi
        return
    done
}

frames_to_seconds() {
    awk -v frames="$1" -v fps="$FPS" '
        BEGIN {
            value = sprintf("%.6f", frames / fps)
            sub(/0+$/, "", value)
            sub(/[.]$/, "", value)
            print value
        }
    '
}

is_positive_decimal() {
    local value=$1
    [[ $value =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] &&
        awk -v value="$value" 'BEGIN { exit !(value > 0) }'
}

seconds_to_frames() {
    awk -v seconds="$1" -v fps="$FPS" 'BEGIN { printf "%d", int(seconds * fps + 0.5) }'
}

parse_transition_time_value() {
    local value=$1

    if ! is_positive_decimal "$value"; then
        parsed_transition_time_error="Use a positive number of seconds, for example 1 or 1.2."
        return 1
    fi

    parsed_transition_frames=$(seconds_to_frames "$value")
    if ((parsed_transition_frames == 0)); then
        parsed_transition_time_error="Transition duration is too short at $FPS fps."
        return 1
    fi
    parsed_transition_display=$(frames_to_seconds "$parsed_transition_frames")
    return 0
}

read_hold_times() {
    local i value attempt

    BATCH_HOLD_TIMES=()
    printf '\nOptional fixed clear display times (fades are not included).\n'
    printf 'Leave a value blank to distribute the remaining time automatically.\n'
    for ((i = 0; i < image_count; i++)); do
        for ((attempt = 1; attempt <= 3; attempt++)); do
            printf '  %s — clear display seconds (Enter = Auto): ' "${images[i]}"
            IFS= read -r value || die "Input was interrupted."
            if [[ -z $value ]]; then
                BATCH_HOLD_TIMES+=('auto')
                break
            elif is_positive_decimal "$value" && (( $(seconds_to_frames "$value") > 0 )); then
                BATCH_HOLD_TIMES+=("$value")
                break
            else
                report_invalid_input "Use a positive number of seconds, such as 1.2, or press Enter for Auto." "$attempt"
            fi
        done
    done
}

parse_cli_args "$@"

check_ffmpeg_installation
need_command awk

if [[ -n $INPUT_DIR ]]; then
    [[ -d $INPUT_DIR ]] || die "Input directory '$INPUT_DIR' does not exist."
    cd -- "$INPUT_DIR"
fi

if [[ -e $OUTPUT_FILE ]] && ((OVERWRITE == 0)); then
    die "File '$OUTPUT_FILE' already exists; use --overwrite to replace it in batch mode."
fi

images=()
custom_order=0
if ((BATCH_MODE && ${#BATCH_IMAGES[@]} > 0)); then
    custom_order=1
    for file in "${BATCH_IMAGES[@]}"; do
        [[ -n $file && $file != */* && $file != '.' && $file != '..' ]] ||
            die "--image accepts a file name from the input directory, not a path: '$file'."
        is_image_name "$file" || die "Unsupported image file '$file'."
        [[ -f $file ]] || die "Ordered image '$file' was not found in the input directory."
        if ((${#images[@]} > 0)); then
            for existing_image in "${images[@]}"; do
                [[ $existing_image != "$file" ]] || die "Ordered image '$file' was listed more than once."
            done
        fi
        images+=("$file")
    done
else
    while IFS= read -r -d '' file; do
        file=${file#./}
        is_image_name "$file" && images+=("$file")
    done < <(find . -maxdepth 1 -type f -print0)
    sort_images
fi

((${#images[@]} > 0)) || die "No supported image files were found in the working directory."

if ((${#images[@]} == 1)); then
    printf 'Found 1 image.\n'
elif ((custom_order)); then
    printf 'Found %d images in the supplied order.\n' "${#images[@]}"
else
    printf 'Found %d images in alphabetical order.\n' "${#images[@]}"
fi

reference_dimensions=''
dimension_problem=0
image_dimensions=()
for ((i = 0; i < ${#images[@]}; i++)); do
    file=${images[i]}
    if dimensions=$(probe_image_dimensions "$file") && [[ $dimensions =~ ^[0-9]+x[0-9]+$ ]]; then
        image_dimensions[i]=$dimensions
        if [[ -z $reference_dimensions ]]; then
            reference_dimensions=$dimensions
        elif [[ $dimensions != "$reference_dimensions" ]]; then
            dimension_problem=1
        fi
    else
        image_dimensions[i]='UNREADABLE'
        dimension_problem=1
    fi
done

[[ -n $reference_dimensions ]] || dimension_problem=1

if ((dimension_problem)); then
    printf 'ERROR: Image dimensions are not consistent. All detected dimensions:\n' >&2
    for ((i = 0; i < ${#images[@]}; i++)); do
        printf '  %s: %s\n' "${images[i]}" "${image_dimensions[i]}" >&2
    done
    exit 1
fi

width=${reference_dimensions%x*}
height=${reference_dimensions#*x}
((width % 2 == 0 && height % 2 == 0)) ||
    die "Image size $reference_dimensions is not suitable for yuv420p video: both width and height must be even."

if ((BATCH_MODE)); then
    FPS=$BATCH_FPS
    total_seconds=$BATCH_DURATION
else
    read_frame_rate
    read_total_seconds
fi
total_frames=$(seconds_to_frames "$total_seconds")
((total_frames > 0)) || die "Total duration is too short at $FPS fps."
image_count=${#images[@]}

transition_names_by_boundary=()
transition_frames_by_boundary=()
transition_displays_by_boundary=()
transition_frames=0
transition_display='0'
all_transition_frames=0
custom_transition_mode=0

if ((image_count > 1)); then
    load_transitions
    transition_count=$((image_count - 1))
    if ((BATCH_MODE && ${#BATCH_TRANSITION_NAMES[@]} > 0)); then
        custom_transition_mode=1
        ((${#BATCH_TRANSITION_NAMES[@]} == transition_count)) ||
            die "--transition-spec must be repeated exactly $transition_count times for $image_count images."
        [[ -z $BATCH_TRANSITION_TIME && $BATCH_TRANSITION == none ]] ||
            die "Do not combine --transition-spec with --transition or --transition-time."

        transition_enabled=0
        for ((i = 0; i < transition_count; i++)); do
            requested_transition=${BATCH_TRANSITION_NAMES[i]}
            requested_time=${BATCH_TRANSITION_TIMES[i]}
            if [[ -z $requested_transition || $requested_transition == none ]]; then
                transition_names_by_boundary[i]='none'
                transition_frames_by_boundary[i]=0
                transition_displays_by_boundary[i]='0'
                continue
            fi

            transition_found=0
            for available_transition in "${transitions[@]}"; do
                if [[ $available_transition == "$requested_transition" ]]; then
                    transition_found=1
                    break
                fi
            done
            ((transition_found)) || die "Unknown transition '$requested_transition' at image boundary $((i + 1))."
            parse_transition_time_value "$requested_time" ||
                die "Invalid transition time at image boundary $((i + 1)): $parsed_transition_time_error"

            transition_names_by_boundary[i]=$requested_transition
            transition_frames_by_boundary[i]=$parsed_transition_frames
            transition_displays_by_boundary[i]=$parsed_transition_display
            all_transition_frames=$((all_transition_frames + parsed_transition_frames))
            transition_enabled=1
        done

        ((total_frames - all_transition_frames >= image_count)) ||
            die "The individual transitions are too long to leave usable clear display time for every image."
        transition_name='individual per image boundary'
    else
        if ((BATCH_MODE)); then
            if [[ -z $BATCH_TRANSITION || $BATCH_TRANSITION == none ]]; then
                transition_name='none (hard cuts)'
                transition_enabled=0
            else
                transition_found=0
                for available_transition in "${transitions[@]}"; do
                    if [[ $available_transition == "$BATCH_TRANSITION" ]]; then
                        transition_found=1
                        break
                    fi
                done
                ((transition_found)) || die "Unknown transition '$BATCH_TRANSITION'."
                [[ -n $BATCH_TRANSITION_TIME ]] ||
                    die "--transition-time is required when a transition is selected."
                transition_name=$BATCH_TRANSITION
                transition_enabled=1
                set_transition_time "$BATCH_TRANSITION_TIME" || die "$transition_time_error"
            fi
        else
            choose_transition
            if ((transition_enabled)); then
                read_transition_time
            fi
        fi

        if ((transition_enabled)); then
            all_transition_frames=$((transition_count * transition_frames))
            for ((i = 0; i < transition_count; i++)); do
                transition_names_by_boundary[i]=$transition_name
                transition_frames_by_boundary[i]=$transition_frames
                transition_displays_by_boundary[i]=$transition_display
            done
        else
            transition_frames=0
            transition_display='0'
            all_transition_frames=0
            for ((i = 0; i < transition_count; i++)); do
                transition_names_by_boundary[i]='none'
                transition_frames_by_boundary[i]=0
                transition_displays_by_boundary[i]='0'
            done
        fi
    fi

else
    transition_count=0
    transition_name='none (one image)'
    transition_enabled=0
fi

fade_in_enabled=0
fade_out_enabled=0
fade_in_frames=0
fade_out_frames=0
fade_in_display='0'
fade_out_display='0'
if ((BATCH_MODE)); then
    if [[ -n $BATCH_FADE_IN ]]; then
        fade_in_enabled=1
        set_edge_fade_time "$BATCH_FADE_IN" in || die "$edge_fade_time_error"
    fi
    if [[ -n $BATCH_FADE_OUT ]]; then
        fade_out_enabled=1
        set_edge_fade_time "$BATCH_FADE_OUT" out || die "$edge_fade_time_error"
    fi
else
    read_edge_fades
fi
((fade_in_frames + fade_out_frames <= total_frames)) ||
    die "Fade-in and fade-out durations overlap. Their combined duration must not exceed the complete video."

if ((BATCH_MODE)); then
    if ((${#BATCH_HOLD_TIMES[@]} == 0)); then
        for ((i = 0; i < image_count; i++)); do
            BATCH_HOLD_TIMES+=('auto')
        done
    elif ((${#BATCH_HOLD_TIMES[@]} != image_count)); then
        die "--hold-time must be repeated exactly $image_count times (once per image), or omitted so every image uses Auto."
    fi
else
    read_hold_times
fi

clear_display_budget=$((total_frames - all_transition_frames - fade_in_frames - fade_out_frames))
((clear_display_budget >= 0)) ||
    die "The fades exceed the total video duration."

hold_frames_by_image=()
automatic_indices=()
fixed_display_total=0
for ((i = 0; i < image_count; i++)); do
    requested_hold=${BATCH_HOLD_TIMES[i]}
    case "$requested_hold" in
        auto|AUTO|Auto|'')
            automatic_indices+=("$i")
            hold_frames_by_image[i]=0
            ;;
        *)
            is_positive_decimal "$requested_hold" ||
                die "Invalid clear display time for image $((i + 1)): use positive decimal seconds or auto."
            requested_hold_frames=$(seconds_to_frames "$requested_hold")
            ((requested_hold_frames > 0)) ||
                die "Clear display time for image $((i + 1)) is too short at $FPS fps."
            hold_frames_by_image[i]=$requested_hold_frames
            fixed_display_total=$((fixed_display_total + requested_hold_frames))
            ;;
    esac
done

((fixed_display_total <= clear_display_budget)) ||
    die "The fixed clear display times and fades exceed the total video duration."

remaining_auto_frames=$((clear_display_budget - fixed_display_total))
automatic_count=${#automatic_indices[@]}
if ((automatic_count == 0)); then
    ((remaining_auto_frames == 0)) ||
        die "Every image has a fixed clear display time, but those times and the fades do not match the total video duration. Use auto for at least one image or adjust the times."
else
    ((remaining_auto_frames >= automatic_count)) ||
        die "The fixed clear display times and fades leave no usable time for every Auto image."
    base_auto_frames=$((remaining_auto_frames / automatic_count))
    extra_auto_frames=$((remaining_auto_frames % automatic_count))
    for ((i = 0; i < automatic_count; i++)); do
        image_index=${automatic_indices[i]}
        hold_frames_by_image[image_index]=$base_auto_frames
        if ((i < extra_auto_frames)); then
            hold_frames_by_image[image_index]=$((base_auto_frames + 1))
        fi
    done
fi

printf '\nSummary:\n'
printf '  Dimensions:           %s px\n' "$reference_dimensions"
printf '  Frame rate:           %d fps\n' "$FPS"
printf '  Total duration:       %s s\n' "$(frames_to_seconds "$total_frames")"
if ((custom_transition_mode)); then
    printf '  Fades between images: individual\n'
    for ((i = 0; i < transition_count; i++)); do
        if ((transition_frames_by_boundary[i] == 0)); then
            printf '    %d -> %d:             none (hard cut)\n' "$((i + 1))" "$((i + 2))"
        else
            printf '    %d -> %d:             %s, %s s\n' \
                "$((i + 1))" "$((i + 2))" "${transition_names_by_boundary[i]}" \
                "${transition_displays_by_boundary[i]}"
        fi
    done
else
    printf '  Transition:           %s\n' "$transition_name"
    if ((transition_frames > 0)); then
        printf '  Transition duration:  %s s\n' "$transition_display"
    fi
fi
if ((fade_in_enabled)); then
    printf '  Fade in from black:    %s s\n' "$fade_in_display"
else
    printf '  Fade in from black:    none\n'
fi
if ((fade_out_enabled)); then
    printf '  Fade out to black:     %s s\n' "$fade_out_display"
else
    printf '  Fade out to black:     none\n'
fi
printf '  Clear image display:\n'
for ((i = 0; i < image_count; i++)); do
    hold_mode='fixed'
    case "${BATCH_HOLD_TIMES[i]}" in auto|AUTO|Auto|'') hold_mode='Auto' ;; esac
    printf '    %d. %-24s %s s (%s)\n' "$((i + 1))" "${images[i]}" \
        "$(frames_to_seconds "${hold_frames_by_image[i]}")" "$hold_mode"
done
printf '  Output:               %s\n\n' "$OUTPUT_FILE"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/filmish.XXXXXXXX")
trap cleanup EXIT HUP INT TERM

printf 'Preparing image clips...\n'
for ((i = 0; i < image_count; i++)); do
    clip_frames=${hold_frames_by_image[i]}
    if ((image_count > 1)); then
        incoming_transition_frames=0
        outgoing_transition_frames=0
        ((i > 0)) && incoming_transition_frames=${transition_frames_by_boundary[i - 1]}
        ((i < transition_count)) && outgoing_transition_frames=${transition_frames_by_boundary[i]}
        clip_frames=$((clip_frames + incoming_transition_frames + outgoing_transition_frames))
    fi
    ((i == 0)) && clip_frames=$((clip_frames + fade_in_frames))
    ((i == image_count - 1)) && clip_frames=$((clip_frames + fade_out_frames))

    ffmpeg -hide_banner -loglevel error -y \
        -loop 1 -framerate "$FPS" -i "${images[i]}" \
        -frames:v "$clip_frames" \
        -vf "fps=${FPS},format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS" \
        -an -c:v ffv1 -level 3 -pix_fmt yuv420p \
        "$temp_dir/clip_$(printf '%05d' "$i").mkv"
    if ((BATCH_MODE)); then
        printf 'PROGRESS %d %d\n' "$((i + 1))" "$((image_count + 1))"
    fi
done

if ((BATCH_MODE)); then
    printf 'Encoding final MP4...\n'
fi
if ((image_count == 1)); then
    edge_filter=''
    if ((fade_in_enabled)); then
        edge_filter="fade=t=in:start_frame=0:nb_frames=${fade_in_frames}"
    fi
    if ((fade_out_enabled)); then
        [[ -n $edge_filter ]] && edge_filter+=','
        fade_out_start=$((total_frames - fade_out_frames))
        edge_filter+="fade=t=out:start_frame=${fade_out_start}:nb_frames=${fade_out_frames}"
    fi
    single_filter_args=()
    [[ -n $edge_filter ]] && single_filter_args+=( -vf "$edge_filter" )
    ffmpeg -hide_banner -loglevel error -y \
        -i "$temp_dir/clip_00000.mkv" \
        "${single_filter_args[@]}" \
        -frames:v "$total_frames" -an -c:v libx264 -preset medium -crf 18 \
        -pix_fmt yuv420p -movflags +faststart "$OUTPUT_FILE"
else
    ffmpeg_args=()
    for ((i = 0; i < image_count; i++)); do
        ffmpeg_args+=( -i "$temp_dir/clip_$(printf '%05d' "$i").mkv" )
    done

    filter_complex=''
    for ((i = 0; i < image_count; i++)); do
        filter_complex+="[${i}:v]fps=${FPS},format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS[v${i}];"
    done
    previous='[v0]'
    cumulative_hold_frames=0
    cumulative_transition_frames=0
    for ((i = 1; i < image_count; i++)); do
        boundary_index=$((i - 1))
        boundary_transition=${transition_names_by_boundary[boundary_index]}
        boundary_frames=${transition_frames_by_boundary[boundary_index]}
        cumulative_hold_frames=$((cumulative_hold_frames + hold_frames_by_image[i - 1]))
        output_label="[mix${i}]"

        if ((boundary_frames > 0)); then
            transition_seconds=$(frames_to_seconds "$boundary_frames")
            offset_frames=$((fade_in_frames + cumulative_hold_frames + cumulative_transition_frames))
            offset_seconds=$(frames_to_seconds "$offset_frames")
            filter_complex+="${previous}[v${i}]xfade=transition=${boundary_transition}:duration=${transition_seconds}:offset=${offset_seconds}${output_label};"
            cumulative_transition_frames=$((cumulative_transition_frames + boundary_frames))
        else
            filter_complex+="${previous}[v${i}]concat=n=2:v=1:a=0${output_label};"
        fi
        previous=$output_label
    done
    filter_complex=${filter_complex%;}

    if ((fade_in_enabled)); then
        filter_complex+=";${previous}fade=t=in:start_frame=0:nb_frames=${fade_in_frames}[edgein]"
        previous='[edgein]'
    fi
    if ((fade_out_enabled)); then
        fade_out_start=$((total_frames - fade_out_frames))
        filter_complex+=";${previous}fade=t=out:start_frame=${fade_out_start}:nb_frames=${fade_out_frames}[edgeout]"
        previous='[edgeout]'
    fi

    ffmpeg -hide_banner -loglevel error -y \
        "${ffmpeg_args[@]}" \
        -filter_complex "$filter_complex" -map "$previous" \
        -frames:v "$total_frames" -r "$FPS" -an \
        -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
        -movflags +faststart "$OUTPUT_FILE"
fi

if ((BATCH_MODE)); then
    printf 'PROGRESS %d %d\n' "$((image_count + 1))" "$((image_count + 1))"
fi

actual_frames=$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of default=nw=1:nk=1 -- "$OUTPUT_FILE")
[[ $actual_frames == "$total_frames" ]] ||
    die "The finished video contains $actual_frames frames; expected $total_frames."

printf "Done: '%s' (%s seconds).\n" \
    "$OUTPUT_FILE" "$(frames_to_seconds "$actual_frames")"
