#!/bin/bash

# Improved chapter handling functions to properly handle chapter length requirements
#
# Two ways to use this file:
#   1. Sourced (original behaviour): call process_chapter_by_length or
#      extend_chapter_to_min_length from another script.
#   2. Executed directly: run it against a book directory.
#
#        ./optimized_chapter_handler.sh <book_dir> [--min 2000] [--max 2500] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults for values normally supplied by the sourcing script
: "${DRY_RUN:=false}"
: "${DELAY_BETWEEN_CHAPTERS:=3}"

# Animation function for waiting periods
show_wait_animation() {
    local wait_time=$1
    local message=$2
    local animation_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    local start_time=$(date +%s)
    local end_time=$((start_time + wait_time))
    local current_time=$start_time
    
    # Hide cursor
    echo -en "\033[?25l"
    
    while [ $current_time -lt $end_time ]; do
        local remaining=$((end_time - current_time))
        local char="${animation_chars[$i]}"
        echo -ne "\r${CYAN}${char}${RESET} ${message} (${YELLOW}${remaining}s${RESET} remaining)     "
        i=$(((i + 1) % ${#animation_chars[@]}))
        sleep 0.1
        current_time=$(date +%s)
    done
    
    # Show cursor and clear line
    echo -e "\r\033[K${GREEN}✓${RESET} ${message} completed!     "
    echo -en "\033[?25h"
}

# Strip common LLM artefacts so generated prose can be written verbatim:
# UTF-8 BOM, a fence wrapping the whole response, a leading "Here is..."
# preamble, and a trailing "I hope this helps" style sign-off.
clean_llm_output() {
    local content="$1"

    # Normalise line endings and strip a UTF-8 BOM
    content=$(printf '%s' "$content" | tr -d '\r')
    content="${content#$'\xEF\xBB\xBF'}"

    # Drop leading blank lines, stray counter lines, and a conversational preamble
    content=$(printf '%s\n' "$content" | awk '
        BEGIN { stripping = 1 }
        stripping && /^[[:space:]]*$/ { next }
        stripping && /^[[:space:]]*[0-9]+[[:space:]]*$/ { next }
        stripping && /^#[[:space:]]+Chapter[[:space:]]+[0-9]+/ { next }
        stripping && /^[[:space:]]*(Here|Sure|Certainly|Of course)[^.]*:?[[:space:]]*$/ { next }
        { stripping = 0; print }
    ')

    # Drop trailing blank lines and a sign-off line
    content=$(printf '%s\n' "$content" | awk '
        { line[NR] = $0 }
        END {
            last = NR
            while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
            while (last > 0 && line[last] ~ /^[[:space:]]*(I hope|Hope this|Let me know|This (chapter|extension|revision)|Note:)/) last--
            for (i = 1; i <= last; i++) print line[i]
        }
    ')

    # Remove a fence that wraps the entire response
    local first_line last_line
    first_line=$(printf '%s\n' "$content" | head -n 1)
    last_line=$(printf '%s\n' "$content" | tail -n 1)
    if printf '%s' "$first_line" | grep -qE '^```[[:alpha:]]*[[:space:]]*$' \
       && printf '%s' "$last_line" | grep -qE '^```[[:space:]]*$'; then
        content=$(printf '%s\n' "$content" | sed '1d;$d')
        # Strip blank lines exposed by removing the opening fence
        content=$(printf '%s\n' "$content" | awk 'BEGIN { stripping = 1 } stripping && /^[[:space:]]*$/ { next } { stripping = 0; print }')
    fi

    printf '%s\n' "$content"
}

# Heuristic: a chapter that stops mid-sentence was cut off by the token limit
# and must not replace a complete one.
output_looks_complete() {
    local content="$1"
    printf '%s\n' "$content" | awk '
        { line[NR] = $0 }
        END {
            last = ""
            for (i = NR; i > 0; i--) {
                if (line[i] ~ /[^[:space:]]/) { last = line[i]; break }
            }
            exit (last ~ /[.!?"”’)*`][[:space:]]*$/) ? 0 : 1
        }'
}

# Chapter files in numeric order (chapter_2 before chapter_10)
list_chapter_files() {
    local book_dir="$1"
    local f num
    for f in "$book_dir"/chapter_*.md; do
        [ -e "$f" ] || continue
        num=$(basename "$f" | sed -E 's/^chapter_([0-9]+).*/\1/')
        printf '%s\t%s\n' "$num" "$f"
    done | sort -n -k1,1 | cut -f2-
}

# ============================================================================
# SESSION (IN-PROCESS) PROVIDER
# ============================================================================
#
# Instead of calling a remote model, the handler can hand its prompts to the
# agent running the session. A shell script cannot wait for a human or agent
# mid-run, so this is two-phase:
#
#   1. --agent-prepare <spool>  writes <chapter>.prompt.md for every chapter
#                               below the minimum, then exits.
#   2. the agent writes <chapter>.response.md next to each prompt.
#   3. --agent-apply <spool>    validates those responses and installs them,
#                               with the same guards as the API path.

agent_prompt_path() {
    printf '%s/%s.prompt.md' "$1" "$(basename "$2" .md)"
}

agent_response_path() {
    printf '%s/%s.response.md' "$1" "$(basename "$2" .md)"
}

agent_prepare() {
    local book_dir="$1"
    local spool="$2"
    local min_words="$3"

    mkdir -p "$spool"

    local count=0
    local file base current_words words_needed prompt_file
    while IFS= read -r file; do
        current_words=$(wc -w < "$file" | tr -d ' ')
        [ "$current_words" -ge "$min_words" ] && continue

        base=$(basename "$file" .md)
        words_needed=$((min_words - current_words))
        prompt_file=$(agent_prompt_path "$spool" "$file")

        {
            echo "# Extension request: $base"
            echo
            echo "- Source file: $file"
            echo "- Current words: $current_words"
            echo "- Minimum words: $min_words"
            echo "- Words to add: at least $words_needed"
            echo
            echo "Rewrite the chapter so the COMPLETE text is at least $min_words words."
            echo
            echo "Rules:"
            echo "- Keep the existing meaning, order, arguments, and voice."
            echo "- Expand with concrete detail: examples, mechanism, consequence."
            echo "- Do not add a chapter title heading; the title comes from the outline."
            echo "- No preamble, no sign-off, no code fences."
            echo "- End on a complete sentence."
            echo "- Write only the finished chapter to: $(agent_response_path "$spool" "$file")"
            echo
            echo "--- BEGIN CHAPTER ---"
            cat "$file"
            echo
            echo "--- END CHAPTER ---"
        } > "$prompt_file"

        count=$((count + 1))
    done < <(list_chapter_files "$book_dir")

    echo "📝 Wrote $count prompt(s) to $spool"
    echo "   Next: write <chapter>.response.md for each, then rerun with --agent-apply $spool"
    return 0
}

agent_apply() {
    local book_dir="$1"
    local spool="$2"
    local min_words="$3"

    if [ ! -d "$spool" ]; then
        echo "❌ Spool directory not found: $spool" >&2
        return 1
    fi

    local applied=0
    local missing=0
    local rejected=0
    local file base response_file current_words new_words content
    while IFS= read -r file; do
        current_words=$(wc -w < "$file" | tr -d ' ')
        [ "$current_words" -ge "$min_words" ] && continue

        base=$(basename "$file" .md)
        response_file=$(agent_response_path "$spool" "$file")

        if [ ! -f "$response_file" ]; then
            echo "⏭️  $base: no response file, leaving unchanged"
            missing=$((missing + 1))
            continue
        fi

        content=$(clean_llm_output "$(cat "$response_file")")

        if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
            echo "⚠️  $base: response is empty, leaving unchanged"
            rejected=$((rejected + 1))
            continue
        fi

        if ! output_looks_complete "$content"; then
            echo "⚠️  $base: response appears truncated, leaving unchanged"
            rejected=$((rejected + 1))
            continue
        fi

        new_words=$(printf '%s\n' "$content" | wc -w | tr -d ' ')
        if [ "$new_words" -le "$current_words" ]; then
            echo "⚠️  $base: response is not longer ($new_words vs $current_words words), leaving unchanged"
            rejected=$((rejected + 1))
            continue
        fi

        if [ "$DRY_RUN" = "true" ]; then
            echo "🧪 $base: would apply $current_words → $new_words words"
            applied=$((applied + 1))
            continue
        fi

        cp "$file" "${file}.before_extension"
        printf '%s\n' "$content" > "$file"
        echo "✅ $base: $current_words → $new_words words"
        applied=$((applied + 1))
    done < <(list_chapter_files "$book_dir")

    echo ""
    echo "Applied: $applied | Rejected: $rejected | No response: $missing"

    [ "$missing" -eq 0 ] && [ "$rejected" -eq 0 ]
}

# Function to calculate tokens required for chapter extension
# Formula: MAX_TOKENS = (500 minimum word length * 1.25) - (current chapter word length * 1.25) 
#          + (system prompt word length * 1.25) + (user prompt word length * 1.25) + 250
calculate_chapter_extension_tokens() {
    local current_words="$1"
    local min_words="${2:-500}"
    local system_prompt_words="${3:-50}"  # Estimated system prompt length
    local user_prompt_words="${4:-200}"   # Estimated user prompt length
    
    # Calculate using formula
    local tokens=$(( (min_words * 125 / 100) - (current_words * 125 / 100) + 
                     (system_prompt_words * 125 / 100) + (user_prompt_words * 125 / 100) + 250 ))
    
    # Ensure we don't go below a reasonable minimum
    if [ "$tokens" -lt 500 ]; then
        tokens=500
    fi
    
    echo "$tokens"
}

# Function to review and process chapter based on length
process_chapter_by_length() {
    local chapter_file="$1"
    local min_words="${2:-2000}"
    local max_words="${3:-2500}"
    
    # Get current word count
    local current_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
    echo "📊 Current word count: $current_word_count words"
    
    if [ "$current_word_count" -ge "$min_words" ]; then
        # Chapter is already long enough, just review for quality
        echo "✅ Chapter meets minimum word count requirement ($current_word_count words)"
        # review_chapter_quality "$chapter_file"
        return 0
    fi

    # Chapter needs extension
    echo "⚠️ Chapter below minimum word count: $current_word_count/$min_words words"
    extend_chapter_to_min_length "$chapter_file" "$min_words" "$max_words"

    # Check if extension succeeded
    local final_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
    if [ "$final_word_count" -ge "$min_words" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "🧪 Dry run: chapter would still be below minimum ($final_word_count/$min_words words)"
        return 0
    fi

    echo "⚠️ Chapter still below minimum after extension: $final_word_count/$min_words words"
    echo "🔄 Trying one final extension attempt..."
    extend_chapter_to_min_length "$chapter_file" "$min_words" "$max_words" "final"

    final_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
    if [ "$final_word_count" -lt "$min_words" ]; then
        echo "❌ Chapter remains below minimum: $final_word_count/$min_words words"
        return 1
    fi

    return 0
}

# Function to review chapter quality without changing length
review_chapter_quality() {
    local chapter_file="$1"
    
    echo "🔍 Reviewing chapter quality..."
    local chapter_content=$(cat "$chapter_file")
    
    # Create a review prompt that doesn't change length
    local review_prompt="Review and improve this chapter for quality without significantly changing its length. 

Focus on:
- Improving flow and readability
- Enhancing clarity and precision
- Fixing grammar and style issues
- Ensuring consistency in tone and voice
- Strengthening arguments and examples

DO NOT:
- Add significant new content
- Remove substantial content
- Change the structure or organization

Return the complete revised chapter with the same approximate word count.

CHAPTER CONTENT:
$chapter_content"

    local review_system_prompt="You are an expert book editor who improves content quality without changing length."
    
    # Call API to review the chapter
    echo "🤖 Generating quality improvements..."
    local reviewed_content
    reviewed_content=$(smart_api_call "$review_prompt" "$review_system_prompt" "quality_check" 0.7 3000 1 "llama3.2:1b")
    local api_status=$?

    # Check if API call was successful
    if [ $api_status -eq 0 ] && [ -n "$reviewed_content" ]; then
        # Clean up the content
        reviewed_content=$(clean_llm_output "$reviewed_content")

        if [ -z "$(printf '%s' "$reviewed_content" | tr -d '[:space:]')" ]; then
            echo "⚠️ Quality review returned no usable content, keeping original chapter"
            return 1
        fi

        if ! output_looks_complete "$reviewed_content"; then
            echo "⚠️ Quality review returned content that appears truncated, keeping original chapter"
            return 1
        fi

        if [ "$DRY_RUN" = "true" ]; then
            echo "🧪 Dry run: would replace $(basename "$chapter_file") with a reviewed version"
            return 0
        fi

        # Save the reviewed chapter
        local backup_file="${chapter_file}.before_review"
        cp "$chapter_file" "$backup_file"
        printf '%s\n' "$reviewed_content" > "$chapter_file"
        echo "✅ Quality review completed and saved (backup: $(basename "$backup_file"))"

        # Final word count
        local final_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
        echo "📊 Final word count after review: $final_word_count words"
        return 0
    fi

    echo "⚠️ Quality review failed, keeping original chapter"
    return 1
}

# Function to extend chapter to meet minimum length
extend_chapter_to_min_length() {
    local chapter_file="$1"
    local min_words="$2"
    local max_words="$3"
    local attempt_type="${4:-standard}"
    
    # Get current content and word count
    local chapter_content=$(cat "$chapter_file")
    local current_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
    local words_needed=$((min_words - current_word_count))
    
    echo "🔍 Extending chapter by approximately $words_needed words..."
    
    # Calculate tokens based on our formula
    local extension_tokens=$(calculate_chapter_extension_tokens "$current_word_count" "$min_words")
    echo "ℹ️ Using $extension_tokens tokens for chapter extension"
    
    # Create an extension prompt
    local extension_prompt="Extend this chapter to reach a minimum of ${min_words} words (currently ${current_word_count} words).

REQUIREMENTS:
- Add approximately ${words_needed} more words
- Expand existing ideas with more depth, examples, and explanations
- Maintain the same style, tone, and voice as the original
- Add substantive content, not just filler text
- Integrate new content seamlessly with existing content
- Return the COMPLETE chapter with your additions integrated

CHAPTER CONTENT:
$chapter_content"

    local extension_system_prompt="You are an expert book author who excels at extending chapters with substantive, valuable content."
    
    # Use a more capable model for the final attempt
    local model="llama3.2:1b"
    if [ "$attempt_type" = "final" ]; then
        model="gemma2:2b"
        # Increase token count by 20% for final attempt
        extension_tokens=$(( extension_tokens * 120 / 100 ))
    fi
    # API rate limit delay
    local jitter=$((RANDOM % 5))
    show_wait_animation "$((DELAY_BETWEEN_CHAPTERS + jitter))" "Chapter cooldown"
    # Call API to extend the chapter
    echo "🤖 Requesting extended content (preferred model: $model)..."
    local extended_content
    extended_content=$(smart_api_call "$extension_prompt" "$extension_system_prompt" "chapter_extension" 0.7 "$extension_tokens" 1 "$model")
    local api_status=$?

    # Check if API call was successful
    if [ $api_status -eq 0 ] && [ -n "$extended_content" ]; then
        # Clean up the content
        extended_content=$(clean_llm_output "$extended_content")

        if [ -z "$(printf '%s' "$extended_content" | tr -d '[:space:]')" ]; then
            echo "⚠️ Extension returned no usable content, keeping original chapter"
            return 1
        fi

        if ! output_looks_complete "$extended_content"; then
            echo "⚠️ Generated content appears truncated mid-sentence, keeping original chapter"
            return 1
        fi

        # Refuse to overwrite the chapter with something that is not longer.
        # Model failures and refusals tend to come back shorter than the input.
        local new_word_count=$(printf '%s\n' "$extended_content" | wc -w | tr -d ' ')
        if [ "$new_word_count" -le "$current_word_count" ]; then
            echo "⚠️ Generated content is not longer than the original ($new_word_count vs $current_word_count words), keeping original chapter"
            return 1
        fi

        if [ "$DRY_RUN" = "true" ]; then
            echo "🧪 Dry run: would extend $(basename "$chapter_file") from $current_word_count to $new_word_count words"
            return 0
        fi

        # Save the extended chapter
        local backup_file="${chapter_file}.before_extension"
        cp "$chapter_file" "$backup_file"
        printf '%s\n' "$extended_content" > "$chapter_file"
        echo "✅ Chapter extension completed and saved (backup: $(basename "$backup_file"))"
        
        # Final word count
        local final_word_count=$(wc -w < "$chapter_file" | tr -d ' ')
        echo "📊 Final word count after extension: $final_word_count words"
        
        # Check if we're still below minimum
        if [ "$final_word_count" -lt "$min_words" ] && [ "$attempt_type" != "final" ]; then
            echo "⚠️ Still below minimum word count: $final_word_count/$min_words words"
        elif [ "$final_word_count" -ge "$min_words" ]; then
            echo "✅ Successfully extended chapter to meet minimum word count"
        fi
        return 0
    fi

    echo "⚠️ Chapter extension failed, keeping original chapter"
    return 1
}

# ============================================================================
# COMMAND-LINE ENTRY POINT
# ============================================================================

usage() {
    cat <<'USAGE'
Usage: optimized_chapter_handler.sh <book_dir> [options]

Extend every chapter below the minimum word count using the configured AI provider.

Options:
  --min <words>          Minimum words per chapter (default: 2000)
  --max <words>          Target maximum words (default: 2500)
  --dry-run              Report what would change without writing files
  --agent-prepare <dir>  Write prompts for the running session to answer; no API calls
  --agent-apply <dir>    Install the session's responses, with validation; no API calls
  -h, --help             Show this help

Provider mode requires Ollama running, or GEMINI_API_KEY / GROQ_API_KEY set.
Chapters are backed up as <chapter>.before_extension before being replaced.

Session mode:
  1. optimized_chapter_handler.sh <book_dir> --agent-prepare .spool
  2. write <chapter>.response.md in .spool for each <chapter>.prompt.md
  3. optimized_chapter_handler.sh <book_dir> --agent-apply .spool
USAGE
}

main() {
    local book_dir=""
    local min_words=2000
    local max_words=2500
    local agent_prepare_dir=""
    local agent_apply_dir=""
    DRY_RUN=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --min)
                [ -n "${2:-}" ] || { echo "❌ --min requires a value" >&2; return 2; }
                min_words="$2"; shift 2 ;;
            --max)
                [ -n "${2:-}" ] || { echo "❌ --max requires a value" >&2; return 2; }
                max_words="$2"; shift 2 ;;
            --agent-prepare)
                [ -n "${2:-}" ] || { echo "❌ --agent-prepare requires a directory" >&2; return 2; }
                agent_prepare_dir="$2"; shift 2 ;;
            --agent-apply)
                [ -n "${2:-}" ] || { echo "❌ --agent-apply requires a directory" >&2; return 2; }
                agent_apply_dir="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            -h|--help)
                usage; return 0 ;;
            -*)
                echo "❌ Unknown option: $1" >&2
                usage >&2
                return 2 ;;
            *)
                book_dir="$1"; shift ;;
        esac
    done

    if [ -z "$book_dir" ] || [ ! -d "$book_dir" ]; then
        echo "❌ Please provide an existing book directory." >&2
        usage >&2
        return 2
    fi

    # Session mode: no provider, no network calls
    if [ -n "$agent_prepare_dir" ]; then
        agent_prepare "$book_dir" "$agent_prepare_dir" "$min_words"
        return $?
    fi

    if [ -n "$agent_apply_dir" ]; then
        agent_apply "$book_dir" "$agent_apply_dir" "$min_words"
        return $?
    fi

    # Load the provider layer when this script is executed on its own
    if ! declare -F smart_api_call >/dev/null 2>&1; then
        local lib="$SCRIPT_DIR/multi_provider_ai.sh"
        if [ -f "$lib" ]; then
            # shellcheck source=multi_provider_ai.sh
            source "$lib"
        else
            echo "❌ multi_provider_ai.sh not found next to this script" >&2
            return 1
        fi
    fi

    # Populate the provider status file that smart_api_call consults
    if declare -F setup_multi_provider_system >/dev/null 2>&1; then
        echo "🔧 Initializing providers..."
        setup_multi_provider_system >/dev/null 2>&1 || true
    fi

    echo "🔌 Checking for an available AI provider..."
    if ! smart_api_call "Reply with the single word: READY" "You are a connectivity probe." "fast" 0 8 1 >/dev/null 2>&1; then
        echo "❌ No AI provider is available (Ollama not running, no API keys set)." >&2
        echo "   Nothing was changed." >&2
        return 1
    fi

    # Collect chapters in numeric order (chapter_2 before chapter_10)
    local files=()
    local entry num
    while IFS= read -r entry; do
        files+=("$entry")
    done < <(
        for f in "$book_dir"/chapter_*.md; do
            [ -e "$f" ] || continue
            num=$(basename "$f" | sed -E 's/^chapter_([0-9]+).*/\1/')
            printf '%s\t%s\n' "$num" "$f"
        done | sort -n -k1,1 | cut -f2-
    )

    if [ ${#files[@]} -eq 0 ]; then
        echo "❌ No chapter_*.md files found in $book_dir" >&2
        return 1
    fi

    echo "📚 Book: $book_dir"
    echo "   Chapters: ${#files[@]} | minimum: $min_words words | dry run: $DRY_RUN"
    echo ""

    local failed=0
    local file
    for file in "${files[@]}"; do
        echo "── $(basename "$file") ──"
        if ! process_chapter_by_length "$file" "$min_words" "$max_words"; then
            failed=$((failed + 1))
        fi
        echo ""
    done

    if [ "$DRY_RUN" = "true" ]; then
        echo "🧪 Dry run complete: no files were written"
        return 0
    fi

    if [ "$failed" -gt 0 ]; then
        echo "⚠️ $failed chapter(s) remain below $min_words words"
        return 1
    fi

    echo "✅ All ${#files[@]} chapters meet the $min_words word minimum"
    return 0
}

# Only run main if the script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
