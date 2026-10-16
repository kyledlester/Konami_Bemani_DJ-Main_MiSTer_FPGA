# SPDX-License-Identifier: GPL-3.0-or-later
#
# Converts the DJ Main games' hard disk CHDs to the raw .hdd images the core
# mounts, with MAME's chdman.
#
#   powershell -ExecutionPolicy Bypass -File scripts\convert_chds.ps1 `
#       -MameDir C:\Users\me\Downloads\mame -OutDir E:\games\DJMain
#
# -MameDir  the MAME folder: chdman.exe there, the CHDs in roms\<set>\
# -OutDir   where the .hdd files go (a folder per set). The images are large:
#           1.4 GB (beatmania) to 10 GB (THE FINAL), about 65 GB for all; the
#           MiSTer SD card must be exFAT for those over 4 GB.
# -Sets     only these sets (default: every one found)
#
# An image already there with the right size is skipped.

param(
    [Parameter(Mandatory = $true)] [string] $MameDir,
    [Parameter(Mandatory = $true)] [string] $OutDir,
    [string[]] $Sets = @()
)

# "-Sets a,b" through -File arrives as one string: split it
$Sets = @($Sets | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$chdman = Join-Path $MameDir "chdman.exe"
if (-not (Test-Path $chdman)) { Write-Error "no chdman.exe in $MameDir"; exit 1 }

# set -> the disk MAME names for it (konami/djmain.cpp)
$disks = [ordered]@{
    bm1stmix = "753jaa11";    bm2ndmix = "853jaa11";   bm3rdmix = "825jab11";   bmcompmx = "858jaa11"
    bmcmxaac = "858aac11";    bm4thmix = "847jaa11";   bm5thmix = "981jaa11";   bmcompm2 = "988jaa11"
    bmclubmx = "993hdda01";   bmdct    = "995jaa11";   bmcorerm = "a05jaa11";   bm6thmix = "a21jaa11"
    bm7thmix = "b07jaa11";    bmfinal  = "c01jaa11";   popn1    = "803_ta_hdd"; popn2    = "831jhdda01"
    popn3    = "980hdda01";   popnstex = "970jba11"
}

foreach ($s in $Sets) {
    if (-not $disks.Contains($s)) { Write-Warning "$s : not a DJ Main set (known: $($disks.Keys -join ', '))" }
}

$found = 0
foreach ($set in $disks.Keys) {
    if ($Sets.Count -gt 0 -and $Sets -notcontains $set) { continue }
    $chd = Join-Path $MameDir ("roms\{0}\{1}.chd" -f $set, $disks[$set])
    if (-not (Test-Path $chd)) {
        if ($Sets.Count -gt 0) { Write-Warning "$set : no CHD at $chd" }
        continue
    }
    $found++
    $dir = Join-Path $OutDir $set
    New-Item -ItemType Directory -Force $dir | Out-Null
    $hdd = Join-Path $dir ($disks[$set] + ".hdd")
    $info = & $chdman info -i $chd
    $size = [int64](($info | Select-String "Logical size:\s*([\d,]+)").Matches[0].Groups[1].Value -replace ",", "")
    if ((Test-Path $hdd) -and (Get-Item $hdd).Length -eq $size) {
        Write-Host "$set : $hdd already there"
        continue
    }
    Write-Host ("{0} : {1} -> {2} ({3:N1} GB)" -f $set, $chd, $hdd, ($size / 1GB))
    & $chdman extracthd -i $chd -o $hdd -f
    if ($LASTEXITCODE -ne 0) { Write-Error "$set : chdman failed"; exit 1 }
}

if ($found -eq 0) { Write-Warning "no CHDs found under $(Join-Path $MameDir 'roms')" }
