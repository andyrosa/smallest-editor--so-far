/* A Windows text editor built around one EDIT control.
 *
 * The EDIT control supplies typing, caret movement, Backspace, and Delete
 * (R2). This file adds the window and loading and saving the file (R1): the
 * file selector (GetOpenFileNameA) chooses the file at start, and the text is
 * saved once it has gone DELAY milliseconds without a change, and when the
 * window closes. A save that cannot happen opens the file selector again, and
 * the save repeats with the path chosen there; Cancel keeps the window open,
 * and the next change saves again. Cancel at start ends the editor.
 *
 * This file is the whole executable: clang assembles it, and the build script
 * copies the bytes of its .text section to smallest-editor--so-far.exe, with
 * no linker. The PE headers and the import tables below are written by bot-hand,
 * so they carry no padding and no import lookup table. The image has one
 * section, at 16-byte alignment, so every RVA is also a file offset. An
 * address in the code is written as IB + (label - base), which the assembler
 * resolves, so the object has no relocations.
 *
 * Registers in _Entry: edi = the frame on the stack; esi = the text buffer;
 * ebx = the path; ebp = the window. All hold their values across calls.
 * wndproc gets the frame from the variable frame and sets the others itself.
 */

    IB      = 0x400000      /* ImageBase */
    STYLE   = 0x10FF00C4    /* WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_VSCROLL
                             * | WS_HSCROLL | ES_MULTILINE | ES_AUTOVSCROLL
                             * | ES_AUTOHSCROLL */
    DEFAULT = 0x80000000    /* CW_USEDEFAULT, and also GENERIC_READ */
    WRITE   = 0x40000000    /* GENERIC_WRITE */
    STACK   = 0x400000      /* stack reserve and commit: all of it committed,
                             * so the frame needs no stack probes */
    BUFSIZE = 0x100000      /* the text buffer, so the largest file */
    DELAY   = 1000          /* milliseconds without a change before a save */

    /* The frame, at edi. It lies 1 MB below the stack top, in pages that
     * nothing touched before _Entry, so it starts as zeros: the OPENFILENAMEA
     * needs only three fields set, and the path starts empty. */
    OFN     = 28            /* after the MSG at 0: OPENFILENAMEA, 76 bytes */
    COUNT   = 104           /* the bytes read or written */
    PATH    = 108           /* the path, 256 bytes */
    BUF     = 364           /* the text */
    FRAME   = BUF + BUFSIZE

    .macro API name
    call *(IB + \name - base)
    .endm

    .text
base:
/* The DOS header: the loader reads only "MZ" and e_lfanew, so the bytes
 * between them hold strings. */
    .ascii "MZ"
n_k32:  .asciz "kernel32.dll"
n_u32:  .asciz "user32.dll"
n_cd32: .asciz "comdlg32.dll"
edit:   .asciz "EDIT"
h_ReadFile: .short 0
    .asciz "ReadFile"
    .org 0x3C
    .long pe - base         /* e_lfanew */
pe:
    .ascii "PE\0\0"
    .short 0x14C            /* Machine: i386 */
    .short 1                /* NumberOfSections */
/* TimeDateStamp and the symbol fields, which the loader ignores, hold the file
 * selector's title for a file too large to open. */
toolarge: .asciz "Too large"
    .byte 0, 0
    .short opt_end - opt    /* SizeOfOptionalHeader */
    .short 0x103            /* relocations stripped, executable, 32-bit */
opt:
    .short 0x10B            /* PE32 */
    .byte 0, 0              /* linker version */
    .long 0, 0, 0           /* SizeOfCode, SizeOfInitializedData,
                             * SizeOfUninitializedData */
    .long _Entry - base     /* AddressOfEntryPoint */
    .long 0, 0              /* BaseOfCode, BaseOfData */
    .long IB
    .long 16, 16            /* SectionAlignment, FileAlignment */
    .short 6, 0, 0, 0, 6, 0 /* OS, image, and subsystem versions */
    .long 0                 /* Win32VersionValue */
    .long image_end - base  /* SizeOfImage */
    .long code - base       /* SizeOfHeaders */
    .long 0                 /* CheckSum */
    .short 2                /* Subsystem: Windows GUI */
    .short 0x8100           /* NX_COMPAT, TERMINAL_SERVER_AWARE */
    .long STACK, STACK      /* SizeOfStackReserve, SizeOfStackCommit */
    .long 0x100000, 0x1000  /* SizeOfHeapReserve, SizeOfHeapCommit */
    .long 0                 /* LoaderFlags */
    .long 2                 /* NumberOfRvaAndSizes: export and import */
    .long 0, 0
    .long imports - base, imports_end - imports
opt_end:
    .ascii ".text\0\0\0"
    .long image_end - code  /* VirtualSize */
    .long code - base       /* VirtualAddress */
    .long image_end - code  /* SizeOfRawData */
    .long code - base       /* PointerToRawData */
    .long 0, 0, 0
    .long 0xE0000060        /* code, data, execute, read, write */
    .balign 16, 0
code:

_Entry:
    subl $FRAME,%esp
    movl %esp,%edi
    leal PATH(%edi),%ebx
    leal BUF(%edi),%esi
    movb $76,OFN(%edi)              /* lStructSize */
    movl %ebx,OFN+28(%edi)          /* lpstrFile */
    movb $1,OFN+33(%edi)            /* nMaxFile = 256 */
open:
    leal OFN(%edi),%eax
    pushl %eax
    API GetOpenFileNameA
    testl %eax,%eax
    jz exit                         /* Cancel: nothing to edit */

    xorl %eax,%eax
    pushl %eax                      /* hTemplateFile */
    pushl %eax                      /* dwFlagsAndAttributes */
    pushl $3                        /* OPEN_EXISTING */
    pushl %eax                      /* lpSecurityAttributes */
    pushl $1                        /* FILE_SHARE_READ */
    pushl $DEFAULT                  /* GENERIC_READ */
    pushl %ebx
    API CreateFileA
    cmpl $-1,%eax                   /* INVALID_HANDLE_VALUE: a new file */
    je 1f
    pushl %eax                      /* for CloseHandle */
    pushl $0                        /* lpOverlapped */
    leal COUNT(%edi),%ecx
    pushl %ecx                      /* lpNumberOfBytesRead */
    pushl $BUFSIZE                  /* one byte past the text */
    pushl %esi
    pushl %eax
    API ReadFile
    API CloseHandle                 /* the file is free for saving */
    movl COUNT(%edi),%eax
    cmpl $BUFSIZE,%eax              /* a full buffer: the file is larger */
    je toobig
    movb $0,(%esi,%eax)             /* the text ends in 0 */

    /* The desktop as hWndParent: with 0 there, the control never scrolls
     * vertically. Page Down, EM_LINESCROLL, the wheel, and the scroll bar left
     * line 1 at the top; with the desktop window, Page Down scrolled 59 lines.
     * Windows 10 19045 and Windows 11 26200, 2026-11-02; evidence in
     * Test-EditScroll.ps1 of chat e6bbb292. Why 0 stops scrolling is unknown. */
1:  API GetDesktopWindow
    xorl %edx,%edx
    movl %edx,OFN+48(%edi)          /* lpstrTitle: the default for later
                                     * file selectors */
    movl $DEFAULT,%ecx
    pushl %edx                      /* lpParam */
    pushl %edx                      /* hInstance */
    pushl %edx                      /* hMenu */
    pushl %eax                      /* hWndParent: the desktop */
    pushl %ecx                      /* nHeight */
    pushl %ecx                      /* nWidth */
    pushl %ecx                      /* y */
    pushl %ecx                      /* x */
    pushl $STYLE
    pushl %ebx                      /* title: the path chosen at startup */
    pushl $IB + edit - base
    pushl %edx                      /* dwExStyle */
    API CreateWindowExA
    movl %eax,%ebp
    movl %ebp,OFN+4(%edi)           /* hwndOwner for later file selectors */
    movl %edi,IB + frame - base     /* for wndproc */
    pushl $IB + wndproc - base
    pushl $-4                       /* GWL_WNDPROC */
    pushl %ebp
    API SetWindowLongA
    movl %eax,IB + oldproc - base
    /* The control refuses typing past 30,000 characters until told otherwise
     * (Windows 10 19045, 2026-11-02); the limit stops at the buffer, so the
     * save never cuts the text short. */
    pushl $0
    pushl $BUFSIZE - 1
    pushl $0xC5                     /* EM_SETLIMITTEXT */
    pushl %ebp
    API SendMessageA
    /* Load the text separately, preserving the path in the title bar.
     * WM_SETTEXT, not the window name: CreateWindowExA created no window
     * for a 70,000-byte name (Windows 11 26200, 2026-10-30). */
    pushl %esi
    pushl $0
    pushl $12                       /* WM_SETTEXT */
    pushl %ebp
    API SendMessageA

    jmp loop                        /* the load falls in here */

exit:
    pushl $0                        /* exit code 0 */
    API ExitProcess                 /* a return would end only this thread,
                                     * and the file selector leaves other
                                     * threads running (8 seen on Windows 11
                                     * 26200, 2026-10-30) */

toobig:
    movl $IB + toolarge - base,OFN+48(%edi) /* lpstrTitle */
    jmp open                        /* choose again; Cancel ends */

loop:
    xorl %eax,%eax
    pushl %eax
    pushl %eax
    pushl %ebp                      /* -1 once the window is destroyed */
    pushl %edi
    API GetMessageA
    incl %eax                       /* nothing posts WM_QUIT, so 0 never comes */
    jz exit
    cmpl $0x113,4(%edi)             /* WM_TIMER */
    jne 2f
    cmpl %ebp,8(%edi)               /* the save timer, whose ID is the window */
    jne 2f
    call flush
    jmp loop
2:  pushl %edi
    API TranslateMessage
    pushl %edi
    API DispatchMessageA
    xorl %eax,%eax
    pushl %eax
    pushl %eax
    pushl $0xB8                     /* EM_GETMODIFY */
    pushl %ebp
    API SendMessageA
    testl %eax,%eax
    jz loop                         /* no change */
    xorl %eax,%eax
    pushl %eax                      /* the text is now unchanged */
    pushl %eax
    pushl $0xB9                     /* EM_SETMODIFY */
    pushl %ebp
    API SendMessageA
    pushl $0                        /* no TimerProc: WM_TIMER comes to loop */
    pushl $DELAY
    pushl %ebp                      /* the timer ID */
    pushl %ebp
    API SetTimer                    /* restarts the timer if it runs */
    jmp loop

/* The window procedure in front of the EDIT control's: WM_CLOSE saves first,
 * because closing from the title bar sends WM_CLOSE without loop seeing it.
 * Then it ends the process itself: the taskbar's "Close window" sends
 * WM_CLOSE from Explorer's thread, so it runs inside loop's GetMessageA,
 * which then waits forever for a window that no longer exists (the process
 * kept running with no windows, Windows 11 26200, 2026-11-02). */
wndproc:
    cmpl $0x10,8(%esp)              /* WM_CLOSE */
    jne 1f
    movl IB + frame - base,%edi
    leal PATH(%edi),%ebx
    leal BUF(%edi),%esi
    movl 4(%esp),%ebp               /* the window, past the return */
    call flush
    jmp exit
1:  popl %eax                       /* the return address */
    pushl IB + oldproc - base       /* CallWindowProcA's first argument */
    pushl %eax
    jmp *(IB + CallWindowProcA - base)

/* Saves if the timer runs, that is if a change is not saved yet. */
flush:
    pushl %ebp
    pushl %ebp
    API KillTimer
    testl %eax,%eax
    jz 9f                           /* no timer: nothing to save */
save:
    pushl %esi
    pushl $BUFSIZE
    pushl $13                       /* WM_GETTEXT */
    pushl %ebp
    API SendMessageA
    pushl %eax                      /* the text size */
    xorl %eax,%eax
    pushl %eax                      /* hTemplateFile */
    pushl %eax                      /* dwFlagsAndAttributes */
    pushl $2                        /* CREATE_ALWAYS */
    pushl %eax                      /* lpSecurityAttributes */
    pushl %eax                      /* no sharing */
    pushl $WRITE
    pushl %ebx
    API CreateFileA
    popl %ecx                       /* the text size */
    cmpl $-1,%eax                   /* INVALID_HANDLE_VALUE */
    je ask
    pushl %eax                      /* for CloseHandle */
    pushl $0                        /* lpOverlapped */
    leal COUNT(%edi),%edx
    pushl %edx                      /* lpNumberOfBytesWritten */
    pushl %ecx
    pushl %esi
    pushl %eax
    API WriteFile
    xchgl %eax,(%esp)               /* WriteFile's result for the handle */
    pushl %eax
    API CloseHandle
    popl %eax
    testl %eax,%eax
    jnz 9f                          /* saved */
ask:
    leal OFN(%edi),%eax
    pushl %eax
    API GetOpenFileNameA
    testl %eax,%eax
    jnz save                        /* save to the chosen path */
9:  ret                             /* saved, or Cancel: the window stays open */

/* The import directory. OriginalFirstThunk is 0, so the loader reads the
 * names from the IAT itself and then overwrites it with the addresses. */
imports:
    .long 0, 0, 0, n_k32 - base, iat_k32 - base
    .long 0, 0, 0, n_u32 - base, iat_u32 - base
    .long 0, 0, 0, n_cd32 - base, iat_cd32 - base
    .long 0, 0, 0, 0, 0
imports_end:
iat_k32:
CreateFileA:      .long h_CreateFileA - base
ReadFile:         .long h_ReadFile - base
WriteFile:        .long h_WriteFile - base
CloseHandle:      .long h_CloseHandle - base
ExitProcess:      .long h_ExitProcess - base
    .long 0
iat_u32:
CreateWindowExA:  .long h_CreateWindowExA - base
GetMessageA:      .long h_GetMessageA - base
TranslateMessage: .long h_TranslateMessage - base
DispatchMessageA: .long h_DispatchMessageA - base
SendMessageA:     .long h_SendMessageA - base
SetWindowLongA:   .long h_SetWindowLongA - base
CallWindowProcA:  .long h_CallWindowProcA - base
SetTimer:         .long h_SetTimer - base
KillTimer:        .long h_KillTimer - base
GetDesktopWindow: .long h_GetDesktopWindow - base
    .long 0
iat_cd32:
GetOpenFileNameA: .long h_GetOpenFileNameA - base
    .long 0
/* Hint/name entries: a hint of 0, then the name. */
h_CreateFileA:      .short 0
    .asciz "CreateFileA"
h_WriteFile:        .short 0
    .asciz "WriteFile"
h_CloseHandle:      .short 0
    .asciz "CloseHandle"
h_ExitProcess:      .short 0
    .asciz "ExitProcess"
h_CreateWindowExA:  .short 0
    .asciz "CreateWindowExA"
h_GetMessageA:      .short 0
    .asciz "GetMessageA"
h_TranslateMessage: .short 0
    .asciz "TranslateMessage"
h_DispatchMessageA: .short 0
    .asciz "DispatchMessageA"
h_SendMessageA:     .short 0
    .asciz "SendMessageA"
h_SetWindowLongA:   .short 0
    .asciz "SetWindowLongA"
h_CallWindowProcA:  .short 0
    .asciz "CallWindowProcA"
h_SetTimer:         .short 0
    .asciz "SetTimer"
h_KillTimer:        .short 0
    .asciz "KillTimer"
h_GetDesktopWindow: .short 0
    .asciz "GetDesktopWindow"
h_GetOpenFileNameA: .short 0
    .asciz "GetOpenFileNameA"
/* Variables for wndproc, written after the window is made. */
frame:   .long 0
oldproc: .long 0
    .balign 16, 0           /* zeros: clang and gcc fill code with different no-ops */
image_end:
