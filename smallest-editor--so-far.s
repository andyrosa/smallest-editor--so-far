/* A Windows text editor built around one EDIT control.
 *
 * The EDIT control supplies typing, caret movement, Backspace, and Delete
 * (R2). This file adds the window and loading and saving the file (R1): the
 * file selector (GetOpenFileNameA) chooses the file at start, Ctrl+S saves it,
 * and a save that cannot happen opens the file selector again, and the save
 * repeats with the path chosen there; Cancel keeps the window open. Cancel at
 * start ends the editor.
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
 */

    IB      = 0x400000      /* ImageBase */
    STYLE   = 0x10FF00C4    /* WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_VSCROLL
                             * | WS_HSCROLL | ES_MULTILINE | ES_AUTOVSCROLL
                             * | ES_AUTOHSCROLL */
    DEFAULT = 0x80000000    /* CW_USEDEFAULT, and also GENERIC_READ */
    WRITE   = 0x40000000    /* GENERIC_WRITE */
    STACK   = 0x400000      /* stack reserve and commit: all of it committed,
                             * so the frame needs no stack probes */
    BUFSIZE = 0x300000      /* the text buffer, so the largest file */

    /* The frame, at edi. It lies 3 MB below the stack top, in pages that
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
    .long 0, 0, 0           /* TimeDateStamp, symbols */
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
    .balign 16
code:

_Entry:
    subl $FRAME,%esp
    movl %esp,%edi
    leal PATH(%edi),%ebx
    leal BUF(%edi),%esi
    movb $76,OFN(%edi)              /* lStructSize */
    movl %ebx,OFN+28(%edi)          /* lpstrFile */
    movb $1,OFN+33(%edi)            /* nMaxFile = 256 */
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

1:  xorl %eax,%eax
    movl $DEFAULT,%ecx
    pushl %eax                      /* lpParam */
    pushl %eax                      /* hInstance */
    pushl %eax                      /* hMenu */
    pushl %eax                      /* hWndParent */
    pushl %ecx                      /* nHeight */
    pushl %ecx                      /* nWidth */
    pushl %ecx                      /* y */
    pushl %ecx                      /* x */
    pushl $STYLE
    pushl %ebx                      /* title: the path chosen at startup */
    pushl $IB + edit - base
    pushl %eax                      /* dwExStyle */
    API CreateWindowExA
    movl %eax,%ebp
    movl %ebp,OFN+4(%edi)           /* hwndOwner for later file selectors */
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
    xorl %eax,%eax
    pushl %eax                      /* MB_OK */
    pushl %eax                      /* no caption: Windows shows "Error" */
    pushl $IB + msg - base
    pushl %eax                      /* no owner */
    API MessageBoxA
    jmp exit

loop:
    xorl %eax,%eax
    pushl %eax
    pushl %eax
    pushl %ebp                      /* -1 once the window is destroyed */
    pushl %edi
    API GetMessageA
    incl %eax                       /* nothing posts WM_QUIT, so 0 never comes */
    jz exit
    cmpl $0x102,4(%edi)             /* WM_CHAR, made by TranslateMessage */
    jne 2f
    cmpl $0x13,8(%edi)              /* Ctrl+S; the control never sees it */
    je save
2:  pushl %edi
    API TranslateMessage
    pushl %edi
    API DispatchMessageA
    jmp loop

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
    jnz loop                        /* saved */
ask:
    leal OFN(%edi),%eax
    pushl %eax
    API GetOpenFileNameA
    testl %eax,%eax
    jnz save                        /* save to the chosen path */
    jmp loop                        /* Cancel: the window stays open */

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
MessageBoxA:      .long h_MessageBoxA - base
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
h_MessageBoxA:      .short 0
    .asciz "MessageBoxA"
h_GetOpenFileNameA: .short 0
    .asciz "GetOpenFileNameA"
msg:    .asciz "File too large to open"
    .balign 16
image_end:
