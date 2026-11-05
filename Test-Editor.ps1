# Drives an editor executable through Win32 messages, as the README describes:
# start it, choose the file in the file selector, find its EDIT window, type
# with WM_CHAR and WM_KEYDOWN, and wait for the save that follows a pause in
# changes, or close the window, which saves a change not saved yet.
# The file selector is a window of class #32770; the script fills in its
# file-name box (class Edit, control ID 1148 or 1001) with WM_SETTEXT and
# presses Open or Cancel with WM_COMMAND.
param(
    [string] $Exe = (Join-Path $PSScriptRoot 'smallest-editor--so-far.exe')
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr SendMessageA(IntPtr h, uint m, IntPtr w, string l);
    public static IntPtr FindChild(IntPtr parent, string className, int id) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (h, l) => {
            var name = new StringBuilder(64); GetClassNameA(h, name, 64);
            if (name.ToString() == className && GetDlgCtrlID(h) == id && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern int GetClassNameA(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern int GetWindowTextA(IntPtr h, StringBuilder s, int n);
    // A top-level caption, which GetWindowTextA reads across processes.
    public static string Title(IntPtr h) {
        var buffer = new StringBuilder(256); GetWindowTextA(h, buffer, 256);
        return buffer.ToString();
    }
    [DllImport("user32.dll")] public static extern bool PostMessageA(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageA(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern int SendMessageA(IntPtr h, uint m, IntPtr w, StringBuilder l);
    public static IntPtr Find(uint pid, string className) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner == pid) {
                var name = new StringBuilder(64); GetClassNameA(h, name, 64);
                if (name.ToString().ToUpperInvariant() == className) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // WM_GETTEXT: cross-process GetWindowTextA returns an empty string.
    public static string Text(IntPtr h) {
        int length = (int)SendMessageA(h, 0x000E, IntPtr.Zero, IntPtr.Zero);
        var buffer = new StringBuilder(length + 2);
        SendMessageA(h, 0x000D, (IntPtr)(length + 1), buffer);
        return buffer.ToString();
    }
    public static void Type(IntPtr h, string text) {
        foreach (char c in text) PostMessageA(h, 0x0102, (IntPtr)c, IntPtr.Zero);
    }
    // WM_KEYDOWN, posted so that the editor's TranslateMessage sees it.
    public static void Key(IntPtr h, int virtualKey) {
        PostMessageA(h, 0x0100, (IntPtr)virtualKey, (IntPtr)1);
    }
}
'@ -Language CSharp

$failures = 0
function Check([string] $name, [bool] $ok, [string] $detail = '') {
    if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:failures++ }
}

# The file selector is a window of class #32770 owned by the editor's process.
function Wait-FileSelector($process) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        $dialog = [W]::Find([uint32]$process.Id, '#32770')
        if ($dialog -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 700; return $dialog }
        if ($process.HasExited) { break }
    }
    return [IntPtr]::Zero
}

# The file-name box can appear more than 700 ms after the file selector
# (Windows 10 19045, 2026-11-02: 3 of 4 runs of the committed test), so the
# script looks for it for up to 5 seconds.
function Select-InFileSelector([IntPtr] $dialog, [string] $path) {
    $name = [IntPtr]::Zero
    for ($attempt = 0; $attempt -lt 50 -and $name -eq [IntPtr]::Zero; $attempt++) {
        $name = [W]::FindChild($dialog, 'Edit', 1148)
        if ($name -eq [IntPtr]::Zero) { $name = [W]::FindChild($dialog, 'Edit', 1001) }
        if ($name -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
    }
    if ($name -eq [IntPtr]::Zero) { throw 'the file selector has no file-name box' }
    [void][W]::SendMessageA($name, 0x000C, [IntPtr]::Zero, $path)        # WM_SETTEXT
    [void][W]::PostMessageA($dialog, 0x0111, [IntPtr]1, [IntPtr]::Zero)  # WM_COMMAND IDOK
}

function Cancel-FileSelector([IntPtr] $dialog) {
    [void][W]::PostMessageA($dialog, 0x0111, [IntPtr]2, [IntPtr]::Zero)  # WM_COMMAND IDCANCEL
}

# Starts the editor, chooses $path in the file selector, and returns the
# process and its EDIT window.
function Start-Editor([string] $path) {
    $process = Start-Process -FilePath $Exe -PassThru
    $dialog = Wait-FileSelector $process
    if ($dialog -eq [IntPtr]::Zero) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "no file selector at start (exited=$($process.HasExited))"
    }
    Select-InFileSelector $dialog $path
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        $handle = [W]::Find([uint32]$process.Id, 'EDIT')
        if ($handle -ne [IntPtr]::Zero) { return $process, $handle }
        if ($process.HasExited) { break }
    }
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    throw "no EDIT window (exited=$($process.HasExited))"
}

# Starts the editor and chooses $path in the file selector, without waiting for
# an EDIT window: for a file the editor refuses, the file selector opens again.
function Start-EditorNoWindow([string] $path) {
    $process = Start-Process -FilePath $Exe -PassThru
    $dialog = Wait-FileSelector $process
    if ($dialog -eq [IntPtr]::Zero) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id }
        throw "no file selector at start (exited=$($process.HasExited))"
    }
    Select-InFileSelector $dialog $path
    return $process
}

# Waits for a file selector with the title $title, so the closing file selector
# that chose the path is not returned as the new one.
function Wait-TitledFileSelector($process, [string] $title) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        $dialog = [W]::Find([uint32]$process.Id, '#32770')
        if ($dialog -ne [IntPtr]::Zero -and [W]::Title($dialog) -eq $title) { Start-Sleep -Milliseconds 700; return $dialog }
        if ($process.HasExited) { break }
    }
    return [IntPtr]::Zero
}

# The editor saves DELAY (1000) milliseconds after the last change.
$saveWaitMilliseconds = 1500
function Wait-Save {
    Start-Sleep -Milliseconds $saveWaitMilliseconds
}

# Closes the window and returns whether the process ended with exit code 0.
function Close-Editor($process, [IntPtr] $handle) {
    [void][W]::PostMessageA($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    $exited = $process.WaitForExit(2000)
    if (-not $exited) { Stop-Process -Id $process.Id }
    return ($exited -and $process.ExitCode -eq 0)
}

# Closes the window as the title bar's close button does: DefWindowProc sends
# WM_CLOSE to the window procedure, and the editor's message loop never sees it.
function Close-EditorFromSystemMenu($process, [IntPtr] $handle) {
    [void][W]::PostMessageA($handle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)   # WM_SYSCOMMAND SC_CLOSE
    $exited = $process.WaitForExit(2000)
    if (-not $exited) { Stop-Process -Id $process.Id }
    return ($exited -and $process.ExitCode -eq 0)
}

function Read-File([string] $path) {
    if (Test-Path $path) { return [System.IO.File]::ReadAllText($path) }
    return '<no file>'
}

$chosen = Join-Path $env:TEMP 'editor-chosen-test.txt'
$file = Join-Path $env:TEMP 'editor-test.txt'
$missing = Join-Path $env:TEMP 'editor-missing-test.txt'
$large = Join-Path $env:TEMP 'editor-large-test.txt'
$huge = Join-Path $env:TEMP 'editor-huge-test.txt'
foreach ($path in $chosen, $file, $missing, $large, $huge) { if (Test-Path $path) { Remove-Item $path } }

# Cancel in the file selector at start ends the process.
$process = Start-Process -FilePath $Exe -PassThru
$dialog = Wait-FileSelector $process
Check 'start opens file selector' ($dialog -ne [IntPtr]::Zero)
if ($dialog -ne [IntPtr]::Zero) { Cancel-FileSelector $dialog }
$exited = $process.WaitForExit(2000)
Check 'cancel at start ends process' ($exited -and $process.ExitCode -eq 0)
if (-not $exited) { Stop-Process -Id $process.Id }

# An existing file: load, wait without a change, edit at the end, and wait
# for the save.
[System.IO.File]::WriteAllText($file, "alpha`r`nbeta")
$loadedTime = (Get-Item $file).LastWriteTimeUtc
$process, $handle = Start-Editor $file
Check 'open loads bytes' (([W]::Text($handle)) -eq "alpha`r`nbeta") "[$([W]::Text($handle))]"
Wait-Save
Check 'open without a change does not save' ((Get-Item $file).LastWriteTimeUtc -eq $loadedTime)
$end = [IntPtr]([W]::Text($handle).Length)
[void][W]::SendMessageA($handle, 0x00B1, $end, $end)   # EM_SETSEL: caret to the end
[W]::Type($handle, "`rgamma")
Start-Sleep -Milliseconds 500
$expected = "alpha`r`nbeta`r`ngamma"
Check 'edit' (([W]::Text($handle)) -eq $expected) "[$([W]::Text($handle))]"
Check 'no save before the pause ends' ((Read-File $file) -ceq "alpha`r`nbeta") "[[$(Read-File $file)]]"
Wait-Save
Check 'pause writes bytes' ((Read-File $file) -ceq $expected) "[[$(Read-File $file)]]"
Check 'save leaves text unchanged' (([W]::Text($handle)) -eq $expected) "[$([W]::Text($handle))]"

# Left, Backspace, and Delete: "xyz" with the caret after "xy" after Left;
# Backspace removes "y" and Delete removes "z".
[void][W]::SendMessageA($handle, 0x00B1, [IntPtr]0, [IntPtr](-1))   # EM_SETSEL: all
[W]::Type($handle, 'xyz')
[W]::Key($handle, 0x25)   # VK_LEFT
[W]::Key($handle, 0x08)   # VK_BACK
[W]::Key($handle, 0x2E)   # VK_DELETE
Start-Sleep -Milliseconds 500
Check 'Left, Backspace, Delete' (([W]::Text($handle)) -eq 'x') "[$([W]::Text($handle))]"
# The pause has not ended, so only the close saves "x".
Check 'close ends process' (Close-EditorFromSystemMenu $process $handle)
Check 'close saves the pending change' ((Read-File $file) -ceq 'x') "[[$(Read-File $file)]]"
Remove-Item $file

# A path that does not exist: the window starts empty, the file appears only
# after a change, and holds only the typed text.
$process, $handle = Start-Editor $missing
Check 'missing path starts empty' (([W]::Text($handle)) -eq '') "[$([W]::Text($handle))]"
Wait-Save
Check 'missing path without a change creates no file' (-not (Test-Path $missing))
[W]::Type($handle, 'new')
Wait-Save
Check 'pause creates file' ((Read-File $missing) -ceq 'new') "[[$(Read-File $missing)]]"
Check 'close after create ends process' (Close-Editor $process $handle)
Remove-Item $missing

# A read-only file: CreateFileA fails, so the save after a change opens the
# file selector and writes nothing. Cancel keeps the window open with the
# text; the next change and a path chosen in the file selector write the text
# there.
[System.IO.File]::WriteAllText($file, 'locked')
Set-ItemProperty $file -Name IsReadOnly -Value $true
$process, $handle = Start-Editor $file
[W]::Type($handle, 'x')
$dialog = Wait-FileSelector $process
Check 'read-only save opens file selector' ($dialog -ne [IntPtr]::Zero)
Check 'read-only file unchanged' ((Read-File $file) -ceq 'locked') "[[$(Read-File $file)]]"
if ($dialog -ne [IntPtr]::Zero) { Cancel-FileSelector $dialog }
Start-Sleep -Milliseconds 800
Check 'cancel keeps window and text' ((-not $process.HasExited) -and ([W]::Find([uint32]$process.Id, '#32770') -eq [IntPtr]::Zero) -and ([W]::Text($handle)) -eq 'xlocked') "[$([W]::Text($handle))]"
[W]::Type($handle, 'y')
$dialog = Wait-FileSelector $process
if ($dialog -ne [IntPtr]::Zero) { Select-InFileSelector $dialog $chosen }
Start-Sleep -Milliseconds 800
Check 'file selector save writes bytes' ((Read-File $chosen) -ceq 'xylocked') "[[$(Read-File $chosen)]]"
Check 'close after file selector ends process' (Close-Editor $process $handle)
Set-ItemProperty $file -Name IsReadOnly -Value $false
Remove-Item $file
if (Test-Path $chosen) { Remove-Item $chosen }

# A 1,000,000-byte file loads whole, and a change at its start saves it whole.
$content = ('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' + "`r`n") * 13514
$content = $content.Substring(0, 1000000)
[System.IO.File]::WriteAllText($large, $content)
$process, $handle = Start-Editor $large
Check 'large file loads whole' ([W]::Text($handle).Length -eq 1000000) "[$([W]::Text($handle).Length)]"
[System.IO.File]::WriteAllText($large, '')
[void][W]::SendMessageA($handle, 0x00B1, [IntPtr]0, [IntPtr]0)   # EM_SETSEL: caret to the start
[W]::Type($handle, 'Z')
Wait-Save
Check 'large file saves whole' ((Read-File $large) -ceq ('Z' + $content)) "[$((Read-File $large).Length)]"
Check 'close after large file ends process' (Close-Editor $process $handle)
Remove-Item $large

# A 5,000,000-byte file is larger than the 1,048,575-byte text buffer, so the
# editor opens the file selector again, titled "Too large", without opening
# it; the file is left byte for byte as it was. Another file chosen there
# opens, and Cancel there ends the process.
$bytes = New-Object byte[] 5000000
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 65 + ($i % 26) }
[System.IO.File]::WriteAllBytes($huge, $bytes)
$before = (Get-FileHash $huge -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText($file, 'small')
$process = Start-EditorNoWindow $huge
$dialog = Wait-TitledFileSelector $process 'Too large'
Check 'oversized file reopens file selector titled Too large' ($dialog -ne [IntPtr]::Zero)
if ($dialog -ne [IntPtr]::Zero) { Select-InFileSelector $dialog $file }
$handle = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 50 -and $handle -eq [IntPtr]::Zero; $attempt++) {
    Start-Sleep -Milliseconds 100
    $handle = [W]::Find([uint32]$process.Id, 'EDIT')
}
Check 'file chosen after oversized file opens' ($handle -ne [IntPtr]::Zero -and ([W]::Text($handle)) -eq 'small') "[$(if ($handle -ne [IntPtr]::Zero) { [W]::Text($handle) })]"
if ($handle -ne [IntPtr]::Zero) { Check 'close after oversized file ends process' (Close-Editor $process $handle) }
if (-not $process.HasExited) { Stop-Process -Id $process.Id }
$process = Start-EditorNoWindow $huge
$dialog = Wait-TitledFileSelector $process 'Too large'
if ($dialog -ne [IntPtr]::Zero) { Cancel-FileSelector $dialog }
Check 'cancel after oversized file ends process' ($process.WaitForExit(2000) -and $process.ExitCode -eq 0)
if (-not $process.HasExited) { Stop-Process -Id $process.Id }
Check 'oversized file unchanged' ((Get-FileHash $huge -Algorithm SHA256).Hash -eq $before)
Remove-Item $huge
Remove-Item $file

if ($failures -ne 0) { throw "$failures check(s) failed" }
