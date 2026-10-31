# Drives an editor executable through Win32 messages, as the README describes:
# start it, choose the file in the file selector, find its EDIT window, type
# with WM_CHAR and WM_KEYDOWN, and save with WM_CHAR 0x13 (Ctrl+S).
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

function Select-InFileSelector([IntPtr] $dialog, [string] $path) {
    $name = [W]::FindChild($dialog, 'Edit', 1148)
    if ($name -eq [IntPtr]::Zero) { $name = [W]::FindChild($dialog, 'Edit', 1001) }
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
# an EDIT window: for a file the editor refuses, a message box comes instead.
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

# The file selector and error message box both use class #32770. Wait for
# the error caption so a closing file selector is not returned as the box.
function Wait-MessageBox($process) {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        $box = [W]::Find([uint32]$process.Id, '#32770')
        if ($box -ne [IntPtr]::Zero -and [W]::Title($box) -eq 'Error') { return $box }
        if ($process.HasExited) { break }
    }
    return [IntPtr]::Zero
}

function Save-Editor([IntPtr] $handle) {
    [W]::Type($handle, [string][char]0x13)
    Start-Sleep -Milliseconds 500
}

# Closes the window and returns whether the process ended with exit code 0.
function Close-Editor($process, [IntPtr] $handle) {
    [void][W]::PostMessageA($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
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

# An existing file: load, edit at the end, and save with Ctrl+S.
[System.IO.File]::WriteAllText($file, "alpha`r`nbeta")
$process, $handle = Start-Editor $file
Check 'open loads bytes' (([W]::Text($handle)) -eq "alpha`r`nbeta") "[$([W]::Text($handle))]"
$end = [IntPtr]([W]::Text($handle).Length)
[void][W]::SendMessageA($handle, 0x00B1, $end, $end)   # EM_SETSEL: caret to the end
[W]::Type($handle, "`rgamma")
Start-Sleep -Milliseconds 500
$expected = "alpha`r`nbeta`r`ngamma"
Check 'edit' (([W]::Text($handle)) -eq $expected) "[$([W]::Text($handle))]"
Save-Editor $handle
Check 'Ctrl+S writes bytes' ((Read-File $file) -ceq $expected) "[[$(Read-File $file)]]"
Check 'Ctrl+S leaves text unchanged' (([W]::Text($handle)) -eq $expected) "[$([W]::Text($handle))]"

# Left, Backspace, and Delete: "xyz" with the caret after "xy" after Left;
# Backspace removes "y" and Delete removes "z".
[void][W]::SendMessageA($handle, 0x00B1, [IntPtr]0, [IntPtr](-1))   # EM_SETSEL: all
[W]::Type($handle, 'xyz')
[W]::Key($handle, 0x25)   # VK_LEFT
[W]::Key($handle, 0x08)   # VK_BACK
[W]::Key($handle, 0x2E)   # VK_DELETE
Start-Sleep -Milliseconds 500
Check 'Left, Backspace, Delete' (([W]::Text($handle)) -eq 'x') "[$([W]::Text($handle))]"
Check 'close ends process' (Close-Editor $process $handle)
Remove-Item $file

# A path that does not exist: the window starts empty, and Ctrl+S creates the
# file with only the typed text.
$process, $handle = Start-Editor $missing
Check 'missing path starts empty' (([W]::Text($handle)) -eq '') "[$([W]::Text($handle))]"
[W]::Type($handle, 'new')
Start-Sleep -Milliseconds 300
Save-Editor $handle
Check 'Ctrl+S creates file' ((Read-File $missing) -ceq 'new') "[[$(Read-File $missing)]]"
Check 'close after create ends process' (Close-Editor $process $handle)
Remove-Item $missing

# A read-only file: CreateFileA fails, so Ctrl+S opens the file selector and
# writes nothing. Cancel keeps the window open with the text; a second Ctrl+S
# and a path chosen in the file selector write the text there.
[System.IO.File]::WriteAllText($file, 'locked')
Set-ItemProperty $file -Name IsReadOnly -Value $true
$process, $handle = Start-Editor $file
[W]::Type($handle, 'x')
Start-Sleep -Milliseconds 300
[W]::Type($handle, [string][char]0x13)
$dialog = Wait-FileSelector $process
Check 'read-only Ctrl+S opens file selector' ($dialog -ne [IntPtr]::Zero)
Check 'read-only file unchanged' ((Read-File $file) -ceq 'locked') "[[$(Read-File $file)]]"
if ($dialog -ne [IntPtr]::Zero) { Cancel-FileSelector $dialog }
Start-Sleep -Milliseconds 800
Check 'cancel keeps window and text' ((-not $process.HasExited) -and ([W]::Find([uint32]$process.Id, '#32770') -eq [IntPtr]::Zero) -and ([W]::Text($handle)) -eq 'xlocked') "[$([W]::Text($handle))]"
[W]::Type($handle, [string][char]0x13)
$dialog = Wait-FileSelector $process
if ($dialog -ne [IntPtr]::Zero) { Select-InFileSelector $dialog $chosen }
Start-Sleep -Milliseconds 800
Check 'file selector save writes bytes' ((Read-File $chosen) -ceq 'xlocked') "[[$(Read-File $chosen)]]"
Check 'close after file selector ends process' (Close-Editor $process $handle)
Set-ItemProperty $file -Name IsReadOnly -Value $false
Remove-Item $file
if (Test-Path $chosen) { Remove-Item $chosen }

# A 1,000,000-byte file loads whole and saves back unchanged.
$content = ('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' + "`r`n") * 13514
$content = $content.Substring(0, 1000000)
[System.IO.File]::WriteAllText($large, $content)
$process, $handle = Start-Editor $large
Check 'large file loads whole' ([W]::Text($handle).Length -eq 1000000) "[$([W]::Text($handle).Length)]"
[System.IO.File]::WriteAllText($large, '')
Save-Editor $handle
Check 'large file saves whole' ((Read-File $large) -ceq $content) "[$((Read-File $large).Length)]"
Check 'close after large file ends process' (Close-Editor $process $handle)
Remove-Item $large

# A 5,000,000-byte file is larger than the 3,145,727-byte text buffer, so the
# editor shows a message box and ends without opening it; the file is left
# byte for byte as it was.
$bytes = New-Object byte[] 5000000
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 65 + ($i % 26) }
[System.IO.File]::WriteAllBytes($huge, $bytes)
$before = (Get-FileHash $huge -Algorithm SHA256).Hash
$process = Start-EditorNoWindow $huge
$box = Wait-MessageBox $process
Check 'oversized file shows message box' ($box -ne [IntPtr]::Zero)
if ($box -ne [IntPtr]::Zero) {
    Check 'oversized message caption' (([W]::Title($box)) -eq 'Error') "[$([W]::Title($box))]"
    $ok = [W]::FindChild($box, 'Button', 2)   # IDOK in a message box
    if ($ok -ne [IntPtr]::Zero) { [void][W]::PostMessageA($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }   # BM_CLICK
}
Check 'oversized file ends process' ($process.WaitForExit(2000) -and $process.ExitCode -eq 0)
if (-not $process.HasExited) { Stop-Process -Id $process.Id }
Check 'oversized file unchanged' ((Get-FileHash $huge -Algorithm SHA256).Hash -eq $before)
Remove-Item $huge

if ($failures -ne 0) { throw "$failures check(s) failed" }
