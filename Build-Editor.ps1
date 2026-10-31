# Builds smallest-editor--so-far.exe from smallest-editor--so-far.s with clang from LLVM MinGW
# (winget id MartinStorsjo.LLVM-MinGW.UCRT), then prints its size.
#
# smallest-editor--so-far.s holds the whole executable, PE headers and import tables included,
# in its .text section. clang assembles it into a COFF object, and this script
# copies the bytes of that section to smallest-editor--so-far.exe. No linker runs.
param(
    [string] $Output = (Join-Path $PSScriptRoot 'smallest-editor--so-far.exe')
)
$ErrorActionPreference = 'Stop'

$clang = Get-Command clang -ErrorAction SilentlyContinue
if ($null -eq $clang) {
    throw 'clang not found on PATH. Install with: winget install --id MartinStorsjo.LLVM-MinGW.UCRT'
}

$source = Join-Path $PSScriptRoot 'smallest-editor--so-far.s'
$object = [System.IO.Path]::ChangeExtension($Output, '.o')
& $clang.Source -target i686-w64-mingw32 -c $source -o $object
$clangExit = $LASTEXITCODE
if ($clangExit -ne 0) { throw "clang exited with code $clangExit" }

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
