#!/usr/bin/env bash
# Inspect the locally installed SIGMA Photo Pro UI automation surface.
set -euo pipefail

app="${SIGMA_PHOTO_PRO_APP:-/Applications/SIGMA_PhotoPro6.app}"
input="${1:-}"

if [ ! -d "$app" ]; then
    echo "SIGMA Photo Pro app not found: $app" >&2
    exit 1
fi

if [ -n "$input" ]; then
    /usr/bin/open -a "$app" "$input"
else
    /usr/bin/open -a "$app"
fi

/usr/bin/osascript <<'APPLESCRIPT'
set processName to "SIGMA_PhotoPro6"

tell application "System Events"
    if UI elements enabled is false then
        error "Accessibility is disabled. Enable it for this terminal/editor in System Settings > Privacy & Security > Accessibility."
    end if
    repeat 90 times
        if exists process processName then exit repeat
        delay 0.5
    end repeat
    if not (exists process processName) then error "SIGMA Photo Pro did not launch"

    tell process processName
        set frontmost to true
        delay 1

        set reportLines to {"process: " & processName}
        if exists menu bar 1 then
            set menuNames to name of menu bar items of menu bar 1
            set end of reportLines to "menus: " & menuNames
            if exists menu bar item "File" of menu bar 1 then
                tell menu bar item "File" of menu bar 1
                    click
                    delay 0.2
                    set fileItems to name of menu items of menu 1
                    set end of reportLines to "file menu: " & fileItems
                end tell
            end if
        end if

        set windowCount to count of windows
        set end of reportLines to "windows: " & windowCount
        repeat with windowIndex from 1 to windowCount
            set windowRef to window windowIndex
            set end of reportLines to "window " & windowIndex & ": " & (name of windowRef) & " / " & (class of windowRef as text)
            try
                set buttonNames to name of buttons of windowRef
                set end of reportLines to "  buttons: " & buttonNames
            end try
            try
                set staticNames to name of static texts of windowRef
                set end of reportLines to "  static texts: " & staticNames
            end try
        end repeat
    end tell
end tell

set AppleScript's text item delimiters to linefeed
return reportLines as text
APPLESCRIPT