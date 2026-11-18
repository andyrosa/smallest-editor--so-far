# Example: .\Release-Editor.ps1 v0.2.0
param([Parameter(Mandatory)][string] $Tag)
$ErrorActionPreference = 'Stop'

$name = 'smallest-editor--so-far.exe'
$scratch = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid()))
Push-Location $PSScriptRoot
try {
    $commit = git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the current commit.' }
    $exe = Join-Path $scratch.FullName $name
    & .\Build-Editor.ps1 -Output $exe
    $expected = git rev-parse "${commit}:$name"
    if ($LASTEXITCODE -ne 0) { throw "Cannot find $name in $commit." }
    $actual = git hash-object -- $exe
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) {
        throw 'The rebuilt executable differs from the committed executable.'
    }

    git push origin "${commit}:refs/tags/$Tag"
    if ($LASTEXITCODE -ne 0) { throw "Could not publish tag $Tag." }
    $size = (Get-Item -LiteralPath $exe).Length
    gh release create $Tag $exe --repo andyrosa/smallest-editor--so-far --verify-tag --title "$Tag - $size-byte Windows editor" --generate-notes
    if ($LASTEXITCODE -ne 0) { throw "Could not create GitHub release $Tag." }
} finally {
    Pop-Location
    Get-ChildItem -LiteralPath $scratch.FullName -File | Remove-Item
    Remove-Item -LiteralPath $scratch.FullName
}
