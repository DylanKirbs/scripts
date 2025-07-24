#!/usr/bin/env bash
# A script to emulate GNU Stow functionality

SCRIPT_NAME="$(basename "$0")"
VERSION="0.0.1"

USAGE="Usage: $SCRIPT_NAME [OPTIONS] <directory>
Options:
  -h, --help             Show this help message and exit
  -n, --dry-run          Show what would be done without making changes
  -v, --verbose          Enable verbose output
  --version              Show version information and exit
  --ignore <pattern>     Ignore files matching the specified glob pattern (e.g., '*.swp')
  --allow-non-dotfiles   Non-dotfiles to be symlinked (default: only dotfiles)
  --target <dir>         Specify the target directory for symlinks (default: \$HOME)
  --migrate              Copy existing files from target to source and symlink them (migration)

Positional Arguments:
  <directory>            Directory containing dotfiles/configs to symlink into \$HOME

Example:
  $SCRIPT_NAME ~/nfs-home

Description:
This utility creates symbolic links in the target (defaults to \$HOME) directory for all dotfiles (e.g., .vimrc) and configuration directories (e.g., .config or .vscode) found in the specified source directory. It also supports ignore patterns, either specified via the command line or defined in ignore files (e.g., .$0-ignore) located in the source or target directories. Additionally, certain directories are automatically created in the source directory before the script runs, such as .config, .vscode, and .local/share, this caters for the use case of nsf-mounting.
"

AUTO_CREATE_DIRS=(".config" ".vscode" ".local")
AUTO_CREATE_FILES=(".bashrc" ".vimrc" ".gitconfig" ".tmux.conf")
DEFAULT_IGNORES=(".git" "node_modules" ".DS_Store")
IGNORE_FILES=("$SCRIPT_NAME-ignore")
IGNORES=()
DRY_RUN=false
DOTFILES_ONLY=true
MIGRATE=false
SOURCE_DIR=""
TARGET_DIR="$HOME"
VERBOSE=false

show_help() {
    echo "$USAGE"
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

load_ignore_file() {
    local f="$1"
    if [[ -r "$f" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" && "$line" != \#* ]] && IGNORES+=("$line")
        done < "$f"
    fi
}

# --- Parse CLI arguments --- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help; exit 0 ;;
        --version)
            show_version; exit 0 ;;
        -n|--dry-run)
            DRY_RUN=true; shift ;;
        -v|--verbose)
            VERBOSE=true; shift ;;
        --target)
            [[ -z "${2:-}" || "$2" == -* ]] && {
                echo "Error: --target requires a directory argument."
                show_help; exit 1
            }
            TARGET_DIR="$(realpath "$2")"; shift 2 ;;
        --target=*)
            TARGET_DIR="$(realpath "${1#--target=}")"; shift ;;
        --ignore)
            [[ -z "${2:-}" || "$2" == -* ]] && {
                echo "Error: --ignore requires a pattern argument."
                show_help; exit 1
            }
            IGNORES+=("$2"); shift 2 ;;
        --ignore=*)
            IGNORES+=("${1#--ignore=}"); shift ;;
        --allow-non-dotfiles)
            DOTFILES_ONLY=false; shift ;;
        --migrate)
            MIGRATE=true; shift ;;
        -*)
            echo "Error: Unknown option '$1'"; show_help; exit 1 ;;
        *)
            if [[ -d "$1" ]]; then
                SOURCE_DIR="$(realpath "$1")"
                shift
            else
                echo "Error: Invalid directory '$1'"; show_help; exit 1
            fi
            ;;
    esac
done

if [[ -z "$SOURCE_DIR" ]]; then
 echo "Error: No source directory specified."
 show_help
 exit 1
fi

if ! [[ -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist or is not a directory."
    exit 1
fi

# --- Combine ignores --- #
IGNORES+=("${DEFAULT_IGNORES[@]}")

for dir in "$SOURCE_DIR" "$TARGET_DIR"; do
    for ignore_file in "${IGNORE_FILES[@]}"; do
        load_ignore_file "$dir/$ignore_file"
    done
done

if $VERBOSE; then
    echo "[V] Ignoring patterns: ${IGNORES[*]}"
fi

# --- Create necessary dirs/files in source --- #
echo "Preparing source directory: $SOURCE_DIR"
for dir in "${AUTO_CREATE_DIRS[@]}"; do
    [[ -d "$SOURCE_DIR/$dir" ]] && continue
    echo "[+] mkdir -p $SOURCE_DIR/$dir"
    if ! $DRY_RUN; then mkdir -p "$SOURCE_DIR/$dir"; fi
done

for file in "${AUTO_CREATE_FILES[@]}"; do
    [[ -e "$SOURCE_DIR/$file" ]] && continue
    echo "[+] touch $SOURCE_DIR/$file"
    if ! $DRY_RUN; then touch "$SOURCE_DIR/$file"; fi
done

# --- Migrate existing files from target to source if requested --- #
migrated_count=0
migrated_skipped=0

if $MIGRATE; then
    echo "Migrating existing files from target ($TARGET_DIR) to source ($SOURCE_DIR)..."
    for file in "$TARGET_DIR"/.* "$TARGET_DIR"/*; do
        # Only regular files (skip dirs, symlinks here)
        [[ -f "$file" ]] || continue
        filename="$(basename "$file")"
        target_link="$TARGET_DIR/$filename"
        source_path="$SOURCE_DIR/$filename"

        # Skip symlinks that point to source already
        if [[ -L "$target_link" ]]; then
            link_target="$(readlink "$target_link")"
            if [[ "$link_target" != /* ]]; then
                link_target="$(realpath -m "$TARGET_DIR/$link_target")"
            fi
            if [[ "$link_target" == "$SOURCE_DIR"* ]]; then
                $VERBOSE && echo "[!] Skipping $filename: symlink to source"
                ((migrated_skipped++))
                continue
            fi
        fi

        # Skip if file exists in source to avoid overwrite
        if [[ -e "$source_path" ]]; then
            $VERBOSE && echo "[!] Skipping $filename: already exists in source"
            ((migrated_skipped++))
            continue
        fi

        echo "[+] Migrating $filename from target to source"
        if ! $DRY_RUN; then
            cp "$target_link" "$source_path" || {
                echo "Error copying $filename, aborting"
                exit 1
            }
            rm "$target_link"
            ln -s "$source_path" "$target_link"
            ((migrated_count++))
        fi
    done
fi

# --- Collect files to symlink --- #
echo "Collecting top-level files from: $SOURCE_DIR"
FILES_TO_SYMLINK=()

shopt -s dotglob nullglob
for file in "$SOURCE_DIR"/* "$SOURCE_DIR"/.*; do
    [[ -f "$file" ]] || continue
    filename="$(basename "$file")"

    if $DOTFILES_ONLY && [[ "$filename" != .* ]]; then
        continue
    fi

    skip=false
    for pattern in "${IGNORES[@]}"; do
        [[ "$filename" == $pattern ]] && skip=true && break
    done
    if ! $skip; then
        FILES_TO_SYMLINK+=("$file")
    fi
done
shopt -u dotglob nullglob

# --- Create symlinks --- #
linked=0
skipped_existing=0
already_linked=0
broken_or_incorrect=0

echo "Creating symlinks in: $TARGET_DIR"
for file in "${FILES_TO_SYMLINK[@]}"; do
    filename="$(basename "$file")"
    link_path="$TARGET_DIR/$filename"

    if [[ -L "$link_path" ]]; then
        target="$(readlink "$link_path")"
        if [[ "$target" == "$file" && -e "$target" ]]; then
            echo "[=] $link_path <- $file (Already linked correctly)"
            ((already_linked++))
            continue
        else
            echo "[!] Link is broken or points elsewhere. Skipping."
            ((broken_or_incorrect++))
            continue
        fi
    elif [[ -e "$link_path" ]]; then
        echo "[!] File exists at destination. Skipping."
        ((skipped_existing++))
        continue
    fi

    if ! $DRY_RUN; then
        if ! ln -s "$file" "$link_path"; then
            echo "Error: Failed to create symlink for $filename"
            exit 1
        fi
    fi
    echo "[+] $link_path <- $file (Symlink created)"
    ((linked++))
done

echo ""
echo "Summary:"
if $MIGRATE; then
    echo "  Migrated files:           $migrated_count"
    echo "  Skipped during migration: $migrated_skipped"
fi
echo "  Symlinks created:         $linked"
echo "  Already linked correctly: $already_linked"
echo "  Skipped (file exists):    $skipped_existing"
echo "  Skipped (broken/wrong):   $broken_or_incorrect"
echo "  Dry run:                  $(if $DRY_RUN; then echo 'yes'; else echo 'no'; fi)"
