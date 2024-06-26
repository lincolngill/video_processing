$DbFile = $(Join-Path -Path $PSScriptRoot -ChildPath "recode_m2ts.json")

Get-Content -Path $DbFile -Raw | ConvertFrom-Json | Group-Object -Property Status | ForEach-Object {
    [PSCustomObject]@{
      Status = $_.Name
      Cnt = ($_.Group | Measure-Object).Count
      M2tsMb = [int](($_.Group | Measure-Object -Sum M2tsSize).Sum/1024/1024)
      Mp4Mb = [int](($_.Group | Measure-Object -Sum Mp4Size).Sum/1024/1024)
    }
  }
