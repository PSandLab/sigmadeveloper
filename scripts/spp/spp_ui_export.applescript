on run argv
    if (count of argv) is less than 4 then
        error "usage: spp_ui_export.applescript <app-path> <input-path> <select-all:0|1> <confirm:0|1>"
    end if

    set appPath to item 1 of argv
    set inputPath to item 2 of argv
    set shouldSelectAll to (item 3 of argv is "1")
    set shouldConfirm to (item 4 of argv is "1")
    set processName to "SIGMA_PhotoPro6"
    set ellipsis to character id 8230
    set saveMenuNames to {"Save Images As" & ellipsis, "Save Images As...", "Save Image As" & ellipsis, "Save Image As..."}

    do shell script "/usr/bin/open -a " & quoted form of appPath & " " & quoted form of inputPath
    my waitForProcess(processName, 45)

    tell application "System Events"
        tell process processName
            set frontmost to true
            my waitForWindow(processName, 45)
            delay 1
            if shouldSelectAll then
                keystroke "a" using {command down}
                delay 0.5
            end if
        end tell
    end tell

    set clickedName to my clickFirstFileMenuItem(processName, saveMenuNames)

    if shouldConfirm then
        delay 1
        my confirmFrontDialog(processName)
    end if

    return "clicked File > " & clickedName
end run

on waitForProcess(processName, timeoutSeconds)
    set startTime to current date
    repeat
        tell application "System Events"
            if exists process processName then return
        end tell
        if ((current date) - startTime) > timeoutSeconds then error "Timed out waiting for process " & processName
        delay 0.5
    end repeat
end waitForProcess

on waitForWindow(processName, timeoutSeconds)
    set startTime to current date
    repeat
        tell application "System Events"
            tell process processName
                if exists window 1 then return
            end tell
        end tell
        if ((current date) - startTime) > timeoutSeconds then error "Timed out waiting for a SIGMA Photo Pro window"
        delay 0.5
    end repeat
end waitForWindow

on clickFirstFileMenuItem(processName, itemNames)
    tell application "System Events"
        tell process processName
            if not (exists menu bar 1) then error "SIGMA Photo Pro menu bar is not accessible"
            if not (exists menu bar item "File" of menu bar 1) then error "SIGMA Photo Pro File menu is not accessible"
            tell menu bar item "File" of menu bar 1
                click
                delay 0.2
                repeat with itemName in itemNames
                    if exists menu item (contents of itemName) of menu 1 then
                        click menu item (contents of itemName) of menu 1
                        return contents of itemName
                    end if
                end repeat
                set availableItems to name of menu items of menu 1
                error "No save command found in File menu. Available items: " & availableItems
            end tell
        end tell
    end tell
end clickFirstFileMenuItem

on confirmFrontDialog(processName)
    tell application "System Events"
        tell process processName
            if not (exists window 1) then return
            set frontmost to true
            tell window 1
                if exists button "Save" then
                    click button "Save"
                    return
                end if
                if exists button "OK" then
                    click button "OK"
                    return
                end if
                if exists button "Convert" then
                    click button "Convert"
                    return
                end if
            end tell
            key code 36
        end tell
    end tell
end confirmFrontDialog