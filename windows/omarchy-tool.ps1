# Omarchy Tool: gives the disks Omarchy Tool shares on \\host.lan a fixed
# drive letter, their own name in This PC and a desktop shortcut, the same way Omarchy's Windows set up
# Z: and "Shared" for \\host.lan\Data at install time. Started from
# "Activar discos.cmd" or "Quitar discos.cmd" next to this file.
param([ValidateSet('activar', 'quitar')][string]$Accion = 'activar')

function T([string]$Spanish, [string]$English) {
  if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { $Spanish } else { $English }
}

$here = $PSScriptRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$tag = 'Omarchy Tool'
$active = Test-Path -LiteralPath (Join-Path $here '.plugin-activo')
$marker = Join-Path $here '.letras-puestas'
# Explorer shows a mapped share under the name stored here (what "Rename" on
# the drive in This PC writes), keyed by the share path with \ turned into #.
$labels = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'

# Drop every letter pointing at our shares and every shortcut we made, so a
# re-run with new letters or disks starts clean.
foreach ($l in [char[]]'DEFGHIJKLMNOPQRSTUVWXY') {
  $info = (net use "${l}:" 2>$null) -join "`n"
  if ($info -match '\\\\host\.lan\\Data[23]\b') { net use "${l}:" /delete /y *> $null }
}
Get-ChildItem -LiteralPath $desktop -Filter *.lnk -ErrorAction SilentlyContinue |
  Where-Object { $shell.CreateShortcut($_.FullName).Description -eq $tag } |
  Remove-Item -Force -ErrorAction SilentlyContinue
foreach ($n in 'Data2', 'Data3') {
  Remove-ItemProperty -LiteralPath "$labels\##host.lan#$n" -Name '_LabelFromReg' -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

if ($Accion -eq 'activar') {
  if (-not $active) {
    Write-Host (T 'Omarchy Tool no está compartiendo discos ahora mismo.' 'Omarchy Tool is not sharing any disks right now.')
    return
  }
  foreach ($line in Get-Content -LiteralPath (Join-Path $here 'discos.txt')) {
    $letter, $share, $name = $line -split '\|', 3
    if (-not $name) { continue }
    net use "${letter}:" $share /persistent:yes *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host (T "$name -> ${letter}: no se pudo (¿letra ocupada?)" "$name -> ${letter}: failed (drive letter already in use?)")
      continue
    }
    $key = Join-Path $labels ($share -replace '\\', '#')
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name '_LabelFromReg' -Value $name
    $link = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
    $link.TargetPath = "${letter}:\"
    $link.Description = $tag
    $link.Save()
    Write-Host "$name -> ${letter}:"
  }
  Set-Content -LiteralPath $marker -Value 'ok'
  Write-Host ''
  Write-Host (T 'Listo. Windows recordará estas letras cada vez que lo abras.' 'Done. Windows will remember these drive letters when you reopen it.')
} else {
  Write-Host (T 'Letras y accesos de Omarchy Tool quitados.' 'Omarchy Tool drive letters and shortcuts removed.')
  if (-not $active) {
    # The disks are off or the plugin is gone: leave nothing of this behind,
    # here or in Windows. Other features' files in this folder stay.
    Set-Location -LiteralPath $env:TEMP
    foreach ($f in 'omarchy-tool.ps1', 'Quitar discos.cmd', 'Activar discos.cmd', 'discos.txt') {
      Remove-Item -LiteralPath (Join-Path $here $f) -Force -ErrorAction SilentlyContinue
    }
    # Then this Discos folder, and Omarchy Tool above it, if nothing else is left.
    foreach ($dir in $here, (Split-Path -Parent $here)) {
      if (-not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
