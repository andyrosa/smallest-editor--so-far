# Builds smallest-editor--so-far.exe from smallest-editor--so-far.s, then prints its size.
# -Compiler clang uses clang from LLVM MinGW (winget id MartinStorsjo.LLVM-MinGW.UCRT);
# -Compiler gcc uses MinGW-w64 GCC, such as WinLibs (winget id
# BrechtSanders.WinLibs.POSIX.UCRT), whose 64-bit gcc assembles 32-bit code with -m32.
#
# smallest-editor--so-far.s holds the whole executable, PE headers and import tables included,
# in its .text section. The compiler assembles it into a COFF object, and this
# script copies the bytes of that section to smallest-editor--so-far.exe. No linker runs.
param(
    [ValidateSet('clang', 'gcc')]
    [string] $Compiler = 'clang',
    [string] $Output = (Join-Path $PSScriptRoot 'smallest-editor--so-far.exe')
)
$ErrorActionPreference = 'Stop'

$installHints = @{
    clang = 'winget install --id MartinStorsjo.LLVM-MinGW.UCRT'
    gcc   = 'winget install --id BrechtSanders.WinLibs.POSIX.UCRT'
}
$targetArguments = @{
    clang = @('-target', 'i686-w64-mingw32')
    gcc   = @('-m32')
}
$command = Get-Command $Compiler -ErrorAction SilentlyContinue
if ($null -eq $command) {
    throw "$Compiler not found on PATH. Install with: $($installHints[$Compiler])"
}

$source = Join-Path $PSScriptRoot 'smallest-editor--so-far.s'
$object = [System.IO.Path]::ChangeExtension($Output, '.o')
$compilerArguments = $targetArguments[$Compiler]
& $command.Source @compilerArguments -c $source -o $object
$compilerExit = $LASTEXITCODE
if ($compilerExit -ne 0) { throw "$Compiler exited with code $compilerExit" }

# The COFF object: a 20-byte file header, then one 40-byte header per section.
# A relocation would mean an address the assembler left for a linker, so the
# script refuses one, and it refuses any section other than .text that holds
# bytes, because those bytes would be missing from smallest-editor--so-far.exe.
$bytes = [System.IO.File]::ReadAllBytes($object)
Remove-Item $object
$sectionCount = [BitConverter]::ToUInt16($bytes, 2)
$table = 20 + [BitConverter]::ToUInt16($bytes, 16)
$image = $null
for ($index = 0; $index -lt $sectionCount; $index++) {
    $header = $table + 40 * $index
    $name = [System.Text.Encoding]::ASCII.GetString($bytes, $header, 8).TrimEnd([char]0)
    $size = [BitConverter]::ToUInt32($bytes, $header + 16)
    $relocationCount = [BitConverter]::ToUInt16($bytes, $header + 32)
    if ($relocationCount -ne 0) { throw "section $name has $relocationCount relocations" }
    if ($name -eq '.text') {
        $image = New-Object byte[] $size
        [Array]::Copy($bytes, [BitConverter]::ToUInt32($bytes, $header + 20), $image, 0, $size)
    } elseif ($size -ne 0) {
        throw "section $name holds $size bytes outside .text"
    }
}
if ($null -eq $image) { throw 'the object has no .text section' }
[System.IO.File]::WriteAllBytes($Output, $image)

$size = (Get-Item $Output).Length
Write-Output "$Output = $size bytes"
