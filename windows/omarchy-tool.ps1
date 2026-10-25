# Omarchy Tool: gives the disks Omarchy Tool shares on \\host.lan a fixed
# drive letter and a desktop shortcut, the same way Omarchy's Windows set up
# Z: and "Shared" for \\host.lan\Data at install time. Started from
# "Activar discos.cmd" or "Quitar discos.cmd" next to this file.
param([ValidateSet('activar', 'quitar')][string]$Accion = 'activar')

$here = $PSScriptRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$tag = 'Omarchy Tool'
$active = Test-Path -LiteralPath (Join-Path $here '.plugin-activo')
$marker = Join-Path $here '.letras-puestas'

# Drop every letter pointing at our shares and every shortcut we made, so a
# re-run with new letters or disks starts clean.
foreach ($l in [char[]]'DEFGHIJKLMNOPQRSTUVWXY') {
  $info = (net use "${l}:" 2>$null) -join "`n"
  if ($info -match '\\\\host\.lan\\Data[23]\b') { net use "${l}:" /delete /y *> $null }
}
Get-ChildItem -LiteralPath $desktop -Filter *.lnk -ErrorAction SilentlyContinue |
  Where-Object { $shell.CreateShortcut($_.FullName).Description -eq $tag } |
  Remove-Item -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

if ($Accion -eq 'activar') {
  if (-not $active) {
    Write-Host 'Omarchy Tool no está compartiendo discos ahora mismo.'
    return
  }
  foreach ($line in Get-Content -LiteralPath (Join-Path $here 'discos.txt')) {
    $letter, $share, $name = $line -split '\|', 3
    if (-not $name) { continue }
    net use "${letter}:" $share /persistent:yes *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "$name -> ${letter}: no se pudo (¿letra ocupada?)"
      continue
    }
    $link = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
    $link.TargetPath = "${letter}:\"
    $link.Description = $tag
    $link.Save()
    Write-Host "$name -> ${letter}:"
  }
  Set-Content -LiteralPath $marker -Value 'ok'
  Write-Host ''
  Write-Host 'Listo. Windows recordará estas letras cada vez que lo abras.'
} else {
  Write-Host 'Letras y accesos de Omarchy Tool quitados.'
  if (-not $active) {
    # The plugin is off or gone: leave nothing of it behind, here or in Windows.
    Set-Location -LiteralPath $env:TEMP
    Remove-Item -LiteralPath $here -Recurse -Force -ErrorAction SilentlyContinue
  }
}
