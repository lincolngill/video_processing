$src = "${env:USERPROFILE}\OneDrive\Pictures"
$dst = "${env:USERPROFILE}\OneDrive\Videos\Camera"
$rsrc = '^'+[regex]::Escape($src)

$ErrorActionPreference = 'Stop'

filter Add-NewPath {
    [PSCustomObject]@{
        File = $_
        NewPath = $_.FullName -replace $rsrc,$dst
    }
}

Write-Host "dst=$dst"
Write-Host "Scanning $src ..."

# Don't add properties to the FileInfo object becuase it causes OneDrive to download the file.
$files = Get-ChildItem -Path $src -File -Recurse  -Include *.m2ts,*.mpg,*.mp4 | Add-NewPath

$files | Select-Object -First 20

$limit = 500
foreach ($file in $files) {
    $NewDir = Split-Path -Parent $file.NewPath
    Write-Host "Moving: $($file.File.FullName)   $NewDir"
    if (!(Test-Path $NewDir -PathType Container)) {
        Write-Host "Creating: $NewDir"
        New-Item -ItemType Directory -Path $NewDir
    }
    $file.File.MoveTo($file.NewPath)
    if (--$limit -eq 0 ) {
        Write-Warning "Exitiing early. Limit reached."
        break
    }
}

Write-Host "Done."
