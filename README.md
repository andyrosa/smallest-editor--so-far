# smallest-editor--so-far

This repo is vibespired by Atto, the tiny (~48 KB) terminal-based text editor added to NetBSD on October 26, 2026.

The goal is the **smallest possible Windows text editor**, measured in bytes of the complete executable.

Current size: **1136 bytes**.

![Bart calls smallest-editor--so-far.exe the smallest Windows 11 editor. Homer replies: So far.](smallest-editor-so-far.jpeg)

## Requirements

- R1. Editor can load and save a text file below a defined size. User selects file name.
- R2. The user edits text in a window: typing inserts characters at the caret, and the arrow, Backspace, and Delete keys move the caret and remove characters.
- R3. The executable runs on a stock 64-bit Windows 11 installation without any other file installed first.


## Use

The editor has no menus, no keyboard shortcuts of its own, and no Save command. It loads one file at start and saves it automatically.

### Load

Run `smallest-editor--so-far.exe`. A file selector opens:

- Choosing an existing file loads its bytes into the window.
- Typing a name that does not exist opens an empty window. The editor creates the file at the first save, so a new name that is never edited leaves no file behind.
- Cancel ends the editor.

The title bar shows the full path chosen at startup. A file larger than 1,048,575 bytes is refused without changing the file: the file selector opens again with the title "Too large", where another file can be chosen, and Cancel ends the editor.

### Edit

The window is a standard Windows edit box. Typing inserts text at the caret; the arrow keys, Home, End, Page Up, and Page Down move the caret; Backspace and Delete remove characters. Ctrl+C, Ctrl+X, Ctrl+V, and Ctrl+Z copy, cut, paste, and undo, and a right-click opens the same commands in a menu. The text can grow to 1,048,575 bytes.

### Save automatically

The editor saves the whole text to the file 1 second after the last change. Continuous typing postpones the save until a 1-second pause. Opening a file and only reading or moving the caret never writes it.

Closing the window by any route (the title bar's close button, Alt+F4, the window menu, or the taskbar) first saves a change that the 1-second pause has not saved yet, then ends the editor.

### Save failure

When the file cannot be written, for example because it is read-only, the file selector opens again. Choosing a path saves the text there, and later saves go to that path. Cancel returns to editing without saving; the next change tries the save again.

## How it stays small

Windows supplies the editing through a single built-in `EDIT` control. The program adds file selection, loading, saving, and a message loop.

[`smallest-editor--so-far.s`](smallest-editor--so-far.s) defines the entire 32-bit executable in assembly, including its PE headers and import tables. The build assembles it and extracts the bytes directly from the object file. No linker or bundled runtime is needed.

## Build and test

Install clang from LLVM MinGW and make sure it is on `PATH`:

```powershell
winget install --id MartinStorsjo.LLVM-MinGW.UCRT
```

Then build and test from PowerShell:

```powershell
.\Build-Editor.ps1
.\Test-Editor.ps1
```

The build writes `smallest-editor--so-far.exe` and prints its byte count. The test script drives the editor with Win32 messages through 28 checks covering file selection, editing, saving after a pause and on close, failed-save recovery, process exit, a 1,000,000-byte file, and a 5,000,000-byte file that the editor refuses.
