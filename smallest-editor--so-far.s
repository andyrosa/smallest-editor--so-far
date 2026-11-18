/* A Windows text editor built around one EDIT control.
 *
 * The EDIT control supplies typing, caret movement, Backspace, and Delete
 * (R2). This file adds the window and loading and saving the file (R1): the
 * file selector chooses the path. Closing an edited file prompts to save
 * or discard changes. If saving fails, choose another path or cancel to
 * keep editing.
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
 * ebx = the address of the SendMessageA import slot; ebp = the window. All hold their values across calls.
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
    MAXFILE = 0x100000      /* accept up to and including 1 MiB */
    BUFSIZE = MAXFILE + 1   /* terminating NUL, or first excess byte on read */

    /* The frame, at edi. It lies 1 MB below the stack top, in pages that
     * nothing touched before _Entry, so it starts as zeros: the OPENFILENAMEA
     * needs only three fields set, and the path starts empty. */
    OFN     = 28            /* after the MSG at 0: OPENFILENAMEA, 76 bytes */
    COUNT   = 104           /* the bytes read or written */
    PATH    = 108           /* the path, 256 bytes */
    BUF     = 364           /* the text */
    FRAME   = BUF + ((BUFSIZE + 15) & -16)

    /* Center calls on the most frequent import. Other slots fit in disp8. */
    .macro API name
    call *(\name\()_index - SendMessageA_index)(%ebx)
    .endm

    .text
base:
/* The DOS header: the loader reads only "MZ" and e_lfanew, so the bytes
 * between them hold strings. */
    .ascii "MZ"
h_ReadFile: .short 0
    .asciz "ReadFile"
n_k32:  .asciz "kernel32.dll"
n_u32:  .asciz "user32.dll"
n_cd32: .asciz "comdlg32.dll"
toolarge: .asciz "Too large"
    .org 0x3C
    .long pe - base         /* e_lfanew */
pe:
    .ascii "PE\0\0"
    .short 0x14C            /* Machine: i386 */
    .short 1                /* NumberOfSections */
/* WriteFile and its hint fit in the twelve bytes of the COFF timestamp
 * and symbol-table fields previously used for the dialog title. */
h_WriteFile:        .short 0
    .asciz "WriteFile"
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
edit: .ascii "EDIT\0\0\0\0"
    .long image_end - code  /* VirtualSize */
    .long code - base       /* VirtualAddress */
    .long image_end - code  /* SizeOfRawData */
    .long code - base       /* PointerToRawData */
    .long 0, 0, 0
    .long 0xE0000060        /* code, data, execute, read, write */
    .balign 16, 0
code:

    /* Give each slot an assembly-time byte offset so clang can select
     * the short x86 encoding. An unnamed slot terminates a DLL table. */
    .macro slot name
    .ifnb \name
\name: .long h_\name - base
\name\()_index = slot_offset
    .else
    .long 0
    .endif
    slot_offset = slot_offset + 4
    .endm
    slot_offset = 0
/* Writable state followed by the three import address tables. */
frame:   .long 0
oldproc: .long 0
iat_k32:
    slot CreateFileA
    slot ReadFile
    slot WriteFile
    slot CloseHandle
    slot ExitProcess
    slot
iat_u32:
    slot CreateWindowExA
    slot GetMessageA
    slot TranslateMessage
    slot DispatchMessageA
    slot SendMessageA
    slot SetWindowLongA
    slot CallWindowProcA
    slot MessageBoxA
    slot GetDesktopWindow
    slot
iat_cd32:
    slot GetOpenFileNameA
    slot

    frame_offset = -8 - SendMessageA_index
    oldproc_offset = -4 - SendMessageA_index

_Entry:
    subl $FRAME,%esp
    movl %esp,%edi
    movl $IB + SendMessageA - base,%ebx
    leal BUF(%edi),%esi
    movb $76,OFN(%edi)              /* lStructSize */
    leal PATH(%edi),%eax
    movl %eax,OFN+28(%edi)          /* lpstrFile */
    movb $1,OFN+33(%edi)            /* nMaxFile = 256 */
open:
    leal OFN(%edi),%eax
    pushl %eax
    API GetOpenFileNameA
    testl %eax,%eax
    jnz opened

exit:
    pushl $0                        /* exit code 0 */
    API ExitProcess                 /* a return would end only this thread,
                                     * and the file selector leaves other
                                     * threads running (8 seen on Windows 11
                                     * 26200, 2026-10-30) */

toobig:
    movl $IB + toolarge - base,OFN+48(%edi) /* lpstrTitle */
    jmp open                        /* choose again; Cancel ends */

opened:
    xorl %eax,%eax
    movb %al,(%esi)                 /* new path after an oversized read */
    pushl %eax                      /* hTemplateFile */
    pushl %eax                      /* dwFlagsAndAttributes */
    pushl $3                        /* OPEN_EXISTING */
    pushl %eax                      /* lpSecurityAttributes */
    pushl $1                        /* FILE_SHARE_READ */
    pushl $DEFAULT                  /* GENERIC_READ */
    pushl OFN+28(%edi)
    API CreateFileA
    incl %eax
    jz 1f
    decl %eax
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
    pushl OFN+28(%edi)                      /* title: the path chosen at startup */
    pushl $IB + edit - base
    pushl %edx                      /* dwExStyle */
    API CreateWindowExA
    xchgl %eax,%ebp
    movl %ebp,OFN+4(%edi)           /* hwndOwner for later file selectors */
    movl %edi,frame_offset(%ebx)     /* for wndproc */
    pushl $IB + wndproc - base
    pushl $-4                       /* GWL_WNDPROC */
    pushl %ebp
    API SetWindowLongA
    movl %eax,oldproc_offset(%ebx)
    /* The control refuses typing past 30,000 characters until told otherwise
     * (Windows 10 19045, 2026-11-02); the limit stops at the buffer, so the
     * save never cuts the text short. */
    pushl $0
    pushl $MAXFILE
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


loop:
    xorl %eax,%eax
    pushl %eax
    pushl %eax
    pushl %ebp                      /* -1 once the window is destroyed */
    pushl %edi
    API GetMessageA
    incl %eax                       /* nothing posts WM_QUIT, so 0 never comes */
    jz exit
    pushl %edi
    API TranslateMessage
    pushl %edi
    API DispatchMessageA
    jmp loop

/* The window procedure in front of the EDIT control's: WM_CLOSE saves first,
 * because closing from the title bar sends WM_CLOSE without loop seeing it.
 * Then it ends the process itself: the taskbar's "Close window" sends
 * WM_CLOSE from Explorer's thread, so it runs inside loop's GetMessageA,
 * which then waits forever for a window that no longer exists (the process
 * kept running with no windows, Windows 11 26200, 2026-11-02). */
wndproc:
    cmpl $0x10,8(%esp)              /* WM_CLOSE */
    je closing
    popl %eax                       /* the return address */
    pushl IB + oldproc - base       /* CallWindowProcA's first argument */
    pushl %eax
    jmp *(IB + CallWindowProcA - base)
closing:
    pushal
    movl $IB + SendMessageA - base,%ebx
    movl frame_offset(%ebx),%edi
    movl OFN+4(%edi),%ebp
    leal BUF(%edi),%esi
    xorl %eax,%eax
    pushl %eax
    pushl %eax
    movb $0xB8,%al
    pushl %eax
    pushl %ebp
    API SendMessageA
    testl %eax,%eax
    jz exit                         /* unchanged */
    pushl $4                        /* MB_YESNO */
    pushl OFN+28(%edi)              /* caption: the file path */
    pushl $IB + save_question - base
    pushl %ebp
    API MessageBoxA
    cmpl $7,%eax                    /* IDNO: discard */
    je exit
    cmpl $6,%eax                    /* IDYES: save */
    jne keep_editing
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
    pushl OFN+28(%edi)
    API CreateFileA
    popl %ecx                       /* the text size */
    incl %eax
    jz ask
    decl %eax
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
    jnz exit
ask:
    leal OFN(%edi),%eax
    pushl %eax
    API GetOpenFileNameA
    testl %eax,%eax
    jnz save                        /* save to the chosen path */
keep_editing:
    popal
    xorl %eax,%eax
    ret $16


/* The import directory. OriginalFirstThunk is 0, so the loader reads the
 * names from the IAT itself and then overwrites it with the addresses. */
imports:
    .long 0, 0, 0, n_k32 - base, iat_k32 - base
    .long 0, 0, 0, n_u32 - base, iat_u32 - base
    .long 0, 0, 0, n_cd32 - base, iat_cd32 - base
    .long 0, 0, 0, 0, 0
imports_end:
/* Each aligned function name borrows its hint from the preceding two
 * bytes. The first borrows zeros from the import directory terminator.
 * The loader compares the candidate with the full name on every lookup. */
    .macro import_name name
    .balign 2, 0
h_\name = . - 2
    .asciz "\name"
    .endm
    import_name CreateFileA
    import_name CloseHandle
    import_name ExitProcess
    import_name CreateWindowExA
    import_name GetMessageA
    import_name TranslateMessage
    import_name DispatchMessageA
    import_name SendMessageA
    import_name SetWindowLongA
    import_name CallWindowProcA
    import_name MessageBoxA
    import_name GetDesktopWindow
    import_name GetOpenFileNameA
save_question: .asciz "Save changes?"
    .balign 16, 0           /* zeros: clang and gcc fill code with different no-ops */
image_end:
