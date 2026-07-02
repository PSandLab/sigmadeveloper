#!/usr/bin/env bash
# Command-line bridge to SIGMA Photo Pro 6 development/export on macOS.
set -euo pipefail

die() {
    echo "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: spp_batch.sh [options] <x3f-file-or-folder> [out-folder]

Options:
    --format jpeg|tiff8|tiff16   output format to preselect in SPP (default: jpeg)
    --quality 1..10              JPEG quality to preselect in SPP (default: 10)
    --mode raw|auto|custom       adjustment mode; auto also sets auto WB (default: raw)
    --app PATH                   SIGMA Photo Pro app bundle (default: /Applications/SIGMA_PhotoPro6.app)
    --manual                     open the SPP save dialog but do not press Save/OK
    --dry-run                    show planned preference/UI actions without launching SPP
    -h, --help                   show this help

This uses SPP's own GUI via macOS Accessibility. It does not patch, inject into,
or bypass SIGMA Photo Pro.
EOF
    exit 2
}

abs_path() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd -P)
    else
        local dir base
        dir="$(dirname "$path")"
        base="$(basename "$path")"
        (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
    fi
}

display_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$PWD" "$1" ;;
    esac
}

check_accessibility() {
    local enabled
    enabled="$(osascript -e 'tell application "System Events" to UI elements enabled' 2>/dev/null || true)"
    [[ "$enabled" == "true" ]] || die "macOS Accessibility is not enabled for this terminal/editor. Enable it in System Settings > Privacy & Security > Accessibility, then rerun."
}

count_outputs() {
    find "$1" -maxdepth 1 -type f \( "${output_find[@]}" \) -print | wc -l | tr -d ' '
}

update_spp_preferences() {
    local prefs="$1" input_dir="$2" out_dir="$3" format_code="$4" quality="$5" mode_code="$6" auto_wb_preset="$7"
    [[ -f "$prefs" ]] || die "missing SPP preference file: $prefs (launch SIGMA Photo Pro once, then rerun)"
    cp "$prefs" "$prefs.sppcli-backup"
    /usr/bin/python3 - "$prefs" "$input_dir" "$out_dir" "$format_code" "$quality" "$mode_code" "$auto_wb_preset" <<'PY'
import sys
import xml.etree.ElementTree as ET

prefs, input_dir, out_dir, format_code, quality, mode_code, auto_wb_preset = sys.argv[1:]
tree = ET.parse(prefs)
root = tree.getroot()

def child(parent, name):
    found = parent.find(name)
    if found is None:
        found = ET.SubElement(parent, name)
    return found

def set_path(path, value):
    node = root
    for part in path.split('/'):
        node = child(node, part)
    node.text = value

set_path('Thumb/ThumbDir', input_dir)
set_path('SaveDlg/SettingRB', mode_code)
set_path('SaveDlg/ChkX3F', '0')
set_path('SaveDlg/OutputImagesize', '0')
set_path('SaveDlg/ColorSpace', '0')
set_path('SaveDlg/FileFormat', format_code)
set_path('SaveDlg/JPEG', quality)
set_path('SaveDlg/LastDirPath', out_dir)
if mode_code == '1':
    set_path('Filter/X3F_WhiteBalancePreset', auto_wb_preset)
    set_path('Filter/X3F_WhiteBalanceTemp', '0')
set_path('Preference/SavePlace', '1')
set_path('Warning/FileOverWriteAlert', '0')

try:
    ET.indent(tree, space='\t')
except AttributeError:
    pass
tree.write(prefs, encoding='utf-8', xml_declaration=True)
PY
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${SIGMA_PHOTO_PRO_APP:-/Applications/SIGMA_PhotoPro6.app}"
format="jpeg"
quality="10"
mode="raw"
confirm="1"
dry_run="0"
positional=()

while (($# > 0)); do
    case "$1" in
        --format)
            (($# >= 2)) || die "--format requires a value"
            format="$2"
            shift 2
            ;;
        --quality)
            (($# >= 2)) || die "--quality requires a value"
            quality="$2"
            shift 2
            ;;
        --mode)
            (($# >= 2)) || die "--mode requires a value"
            mode="$2"
            shift 2
            ;;
        --app)
            (($# >= 2)) || die "--app requires a path"
            app="$2"
            shift 2
            ;;
        --manual)
            confirm="0"
            shift
            ;;
        --dry-run)
            dry_run="1"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            while (($# > 0)); do positional+=("$1"); shift; done
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

((${#positional[@]} >= 1)) || usage
((${#positional[@]} <= 2)) || die "too many positional arguments"

case "$format" in
    jpeg) format_code="0"; output_find=(-iname '*.jpg' -o -iname '*.jpeg') ;;
    tiff8) format_code="1"; output_find=(-iname '*.tif' -o -iname '*.tiff') ;;
    tiff16) format_code="2"; output_find=(-iname '*.tif' -o -iname '*.tiff') ;;
    *) die "unsupported --format: $format" ;;
esac

case "$quality" in
    ''|*[!0-9]*) die "--quality must be an integer from 1 to 10" ;;
esac
((10#$quality >= 1 && 10#$quality <= 10)) || die "--quality must be an integer from 1 to 10"

case "$mode" in
    [Rr][Aa][Ww]) mode="raw"; mode_code="0"; force_auto_wb="0" ;;
    [Aa][Uu][Tt][Oo]) mode="auto"; mode_code="1"; force_auto_wb="1" ;;
    [Cc][Uu][Ss][Tt][Oo][Mm]) mode="custom"; mode_code="2"; force_auto_wb="0" ;;
    *) die "unsupported --mode: $mode" ;;
esac

spp_auto_wb_preset="${SPP_AUTO_WB_PRESET:-11}"
case "$spp_auto_wb_preset" in
    ''|*[!0-9]*) die "SPP_AUTO_WB_PRESET must be a non-negative integer" ;;
esac
[[ -d "$app" ]] || die "SIGMA Photo Pro app not found: $app"

input="$(abs_path "${positional[0]}")"
[[ -e "$input" ]] || die "input does not exist: $input"

if [[ -d "$input" ]]; then
    input_dir="$input"
    launch_input="$input"
    select_all="1"
    x3f_count="$(find "$input" -maxdepth 1 -type f -iname '*.x3f' | wc -l | tr -d ' ')"
    ((x3f_count > 0)) || die "no .X3F files found in $input"
else
    case "$input" in
        *.[Xx]3[Ff]) ;;
        *) die "input file is not an X3F: $input" ;;
    esac
    input_dir="$(dirname "$input")"
    launch_input="$input"
    select_all="0"
    x3f_count="1"
fi

if ((${#positional[@]} == 2)); then
    out_dir_arg="${positional[1]}"
else
    out_dir_arg="$input_dir/spp-output"
fi

if [[ "$dry_run" == "1" ]]; then
    out_dir="$(display_path "$out_dir_arg")"
else
    mkdir -p "$out_dir_arg"
    out_dir="$(abs_path "$out_dir_arg")"
fi

prefs="${SPP_PREFS:-$HOME/Library/Preferences/SPhotoPro.xml}"

{
    printf 'SPP batch bridge\n'
    printf '  app:       %s\n' "$app"
    printf '  input:     %s\n' "$launch_input"
    printf '  x3f files: %s\n' "$x3f_count"
    printf '  output:    %s\n' "$out_dir"
    printf '  format:    %s\n' "$format"
    printf '  quality:   %s\n' "$quality"
    printf '  mode:      %s (SaveDlg/SettingRB=%s)\n' "$mode" "$mode_code"
    printf '  auto wb:   %s (X3F_WhiteBalancePreset=%s)\n' "$force_auto_wb" "$spp_auto_wb_preset"
    printf '  confirm:   %s\n' "$confirm"
} >&2

if [[ "$dry_run" == "1" ]]; then
    echo "dry run: would update $prefs, open SPP, select files, and invoke Save Images As" >&2
    exit 0
fi

check_accessibility
update_spp_preferences "$prefs" "$input_dir" "$out_dir" "$format_code" "$quality" "$mode_code" "$spp_auto_wb_preset"

before_count="$(count_outputs "$out_dir")"
/usr/bin/osascript "$here/spp_ui_export.applescript" "$app" "$launch_input" "$select_all" "$confirm"

if [[ "$confirm" == "0" ]]; then
    echo "SPP save dialog opened. Complete the dialog in SIGMA Photo Pro." >&2
    exit 0
fi

echo "SPP export was started. Watching $out_dir for output files..." >&2
deadline=$((SECONDS + 1800))
while ((SECONDS < deadline)); do
    after_count="$(count_outputs "$out_dir")"
    if ((after_count - before_count >= x3f_count)); then
        echo "done: $out_dir" >&2
        exit 0
    fi
    sleep 2
done

die "timed out waiting for $x3f_count exported $format file(s) in $out_dir"