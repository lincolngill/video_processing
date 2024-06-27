<#
.SYNOPSIS
  Bulk recode m2ts files to Chromecast cmpatible mp4 

.DESCRIPTION
  Bulk video recoding, driven from a json database file of candidate m2ts files.
  Generates the database file, if it does not exist, by scanning the BasePath for m2ts files.
  For each candiate file:
    Determines if the file has been recoded. If not:
      The original m2ts file is copied locally.
      The file is recoded as Chromecast compatible mp4 and stored in the original location, in a "mp4_recode" subdirectory.
      The DB file is updated for each completed recode file.
  The number of recoded files per execution is limited to the Limit.
  The original file is copied from a sFTP backup server.

.PARAMETER BasePath
  Specifies the location of the m2ts files.
  Used too create the driver DB file and to determine the location of the recoded files.

.PARAMETER SftpHost
  sFTP server hostname, where the m2ts files have been backed up.

.PARAMETER SshKeyFile
  Private key file for sFTP session.

.PARAMETER SrcBasePath
  Specifies the location of the backed up source files.

.PARAMETER RecodeSubDir
  Specifies the subdirectory where the recoded mp4 files will be output.
  The mp4 files are stored in the orginal location under this subdirectory.

.PARAMETER Limit
  Limit the number of file that are recoded in this execution.

.PARAMETER Unlimited
  Process all candidate files.

.EXAMPLE
  PS> .\recode_m2ts.ps1
#>

param(
  [ValidateUserDrive()]
  [ValidateNotNullOrEmpty()]
  [string]$BasePath = "${env:USERPROFILE}\OneDrive\Videos\Camera",
  [ValidateNotNullOrEmpty()]
  [string]$SftpHost = "vpnpi.local",
#  [string]$SftpUser = $Env:USERNAME,
  [string]$SftpUser = "links",
  [ValidateUserDrive()]
  [ValidateNotNullOrEmpty()]
  [string]$SshKeyFile = "${env:USERPROFILE}\.ssh\id_ed25519",
  [ValidateNotNullOrEmpty()]
  [string]$SrcBasePath = "/mnt/t7/onedrv_bkup/Videos/Camera",
  [string]$RecodeSubDir = "mp4_recode",
  [ValidateUserDrive()]
  [ValidateNotNullOrEmpty()]
  [string]$DbFile = $(Join-Path -Path $PSScriptRoot -ChildPath "recode_m2ts.json"),
  [ValidateNotNullOrEmpty()]
  [string]$TmpDir = $(Join-Path -Path $PSScriptRoot -ChildPath "tmp"),
  [switch]$Unlimited,
  [ValidateRange(0,1000)]
  [int]$Limit = 0,
  [switch]$DbRebuild
)
$ErrorActionPreference = 'Stop'

Write-Host "BasePath: $BasePath"
Write-Host "SftpHost: $SftpHost"
Write-Host "SftpUser: $SftpUser"
Write-Host "SshKeyFile: $SshKeyFile"
Write-Host "SrcBasePath: $SrcBasePath"
Write-Host "RecodeSubDir: $RecodeSubDir"
Write-Host "DbFile: $DbFile"
Write-Host "Limit: $(if ($Unlimited.IsPresent) { "Unlimited" } else { $Limit })"

if (!(Test-Path $TmpDir -PathType Container)) {
  Write-Host "Creating TmpDir: $TmpDir"
  $null = New-Item -ItemType Directory -Path $TmpDir
}

$rBasePath = '^'+[regex]::Escape($BasePath)

filter New-DbRec {
  [PSCustomObject]@{
      Path = $_.FullName
      Name = $_.Name
      Mp4Path = Join-Path -Path $_.DirectoryName -ChildPath $RecodeSubDir -AdditionalChildPath ($_.BaseName+".mp4")
      SrcPath = ($_.FullName -replace $rBasePath,$SrcBasePath) -replace '\\','/'
      Status = 0
      ConvertedDate = ""
      M2tsSize = $_.Length
      Mp4Size = 0
  }
}

function Get-DbContent {
  if (!(Test-Path -Path $DbFile -PathType Leaf) -or $DbRebuild.IsPresent) {
    Write-Host "Creating DB: $DbFile"
    # Don't add properties to the FileInfo object becuase it causes OneDrive to download the file.
    Get-ChildItem -Path $BasePath -File -Recurse  -Include *.m2ts | New-DbRec | ConvertTo-Json | Set-Content -Path $DbFile
  }
  Write-Host "Reading DB: $DbFile"
  return Get-Content -Path $DbFile -Raw | ConvertFrom-Json 
}

$db = Get-DbContent

$password = ConvertTo-SecureString "garbage" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($SftpUser,$password)
#$cred = Get-Credential -UserName $SftpUser -Message "Passphrase for $SshKeyFile"
$s = New-SFTPSession -ComputerName $SftpHost -Credential $cred -AcceptKey -KeyFile $SshKeyFile
$alldone = $true
try {
  $sid = $s.SessionId
  $done = 0
  foreach ($row in $db) {
    if ($row.Status -gt 0) {
      continue
    }
    if (${Limit} -le 0) {
      Write-Warning "Exitiing early. Limit reached."
      $alldone = $false
      break
    }
    --$Limit
    if (Test-Path -Path $row.Mp4Path -PathType Leaf) {
      Write-Error "Recoded mp4 already exists: $($row.Mp4Path)"
      $row.Status = 101
      continue
    }
    $row.Status = 1 # Download in progress
    $rf = $row.SrcPath
    $tf = Join-Path -Path $TmpDir -ChildPath $row.Name
    if (Test-Path -Path $tf -PathType Leaf) {
      Write-Error "Temp file already exists: $tf"
      $row.Status = 102
      continue
    }
    if (!(Test-SFTPPath -SessionId $sid -Path $rf)) {
      Write-Error "Remote file does not exist: $rf"
      $row.Status = 103
      continue
    }
    Write-Host "Getting ${done}: $rf ..."
    Get-SFTPItem -SessionId $sid -Path $rf -Destination $TmpDir
    try {
      $row.Status = 2 # Recode inprogress
      $h = Join-Path -Path (Split-Path -Path $row.Path -Parent) -ChildPath $RecodeSubDir
      if (!(Test-Path -Path $h -PathType Container)) {
        Write-Host "Creating: $h"
        New-Item -ItemType Directory -Path $h
      }
      #ffmpeg -i $tf -map 0:0 -map 0:1 -map 0:1 -vf scale=1920x1080 -c:v libx264 -profile:v high -level:v 4.1 -c:a:0 aac -ac 2 -c:a:1 copy $row.Mp4Path
      ffmpeg -i $tf -map 0:0 -map 0:1 -map 0:1 -vf scale=1920x1080 -c:v libx264 -crf 21 -preset slow -c:a:0 aac -ac 2 -c:a:1 copy $row.Mp4Path
      if ($LASTEXITCODE -ne 0) {
        $row.Status = 120 + $LASTEXITCODE
        continue
      }
      $row.Mp4Size = (Get-Item -Path $row.Mp4Path).Length
    } finally {
      Write-Host "Removing tmp file: $tf"
      Remove-Item -Path $tf
    }
    $row.Status = 50 # File Done
    $row.ConvertedDate = Get-Date -Format "dd/MM/yyyy HH:mm" | Out-String
    $done++
    $db | ConvertTo-Json | Set-Content -Path $DbFile
  }
} finally {
  Write-Host "Writing DB: $DbFile"
  $db | ConvertTo-Json | Set-Content -Path $DbFile
  Write-Host "Disconnecting sFTP: $SftpHost"
  $s.Disconnect()
  $null = Remove-SFTPSession -SessionId $sid
}

$db | Select-Object -First 20 | Format-Table

if ($alldone) {
  $h = Get-Item -Path $DbFile
  $newname = (Get-Item -Path $DbFile).BaseName+(Get-Date -Format '_ddMMyyyy_HHmm')+'.json'
  Write-Host "All Done. Renaming DB: $DbFile to $newname"
  Rename-Item -Path $DbFile -NewName $newname
}

Write-Host "Done: $done. AllDone: $alldone"
