<# 
.SYNOPSIS
  Быстрая очистка диска Windows: TEMP, SoftwareDistribution\Download, CBS\Logs, IIS-логи, $Recycle.Bin и т.п.
  Имеет режим предварительного просмотра (-Preview) и реальной очистки (-Clean). Подробно логирует действия.

.EXAMPLE
  .\Clear-DiskSpace.ps1 -Preview
  Покажет потенциальный выигрыш по категориям, ничего не удаляя.

.EXAMPLE
  .\Clear-DiskSpace.ps1 -Clean -EmptyRecycleBin
  Выполнит очистку, включая очистку корзины (нужно запускать от администратора).

.NOTES
  Требуются права администратора для большинства операций.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$false)]
  [ValidatePattern('^[A-Z]:$')]
  [string]$TargetDrive = 'C:',

  [switch]$Preview,
  [switch]$Clean,
  [switch]$EmptyRecycleBin,

  # Максимальный возраст логов IIS (дни), старше — удаляем (при -Clean)
  [int]$IISLogMaxAgeDays = 14,

  # Путь к файлу лога
  [string]$LogPath = "$env:SystemDrive\Logs\Clear-DiskSpace.log"
)

# --- Безопасность и подготовка ------------------------------------------------
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Warning "Запустите PowerShell 'От имени администратора'. Некоторые действия будут недоступны."
  }
}
Assert-Admin

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Start-Transcript -Path $LogPath -Append | Out-Null

# --- Утилиты ------------------------------------------------------------------
function Format-Bytes([long]$bytes) {
  switch ($bytes) {
    {$_ -ge 1PB} {"{0:N2} PB" -f ($bytes/1PB); break}
    {$_ -ge 1TB} {"{0:N2} TB" -f ($bytes/1TB); break}
    {$_ -ge 1GB} {"{0:N2} GB" -f ($bytes/1GB); break}
    {$_ -ge 1MB} {"{0:N2} MB" -f ($bytes/1MB); break}
    {$_ -ge 1KB} {"{0:N2} KB" -f ($bytes/1KB); break}
    default      {"{0} B"   -f $bytes}
  }
}

function Get-FolderSize([string]$Path) {
  if (-not (Test-Path $Path)) { return 0 }
  try {
    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if (-not $_.PSIsContainer) { $sum += $_.Length }
    }
    return $sum
  } catch {
    Write-Verbose "Не удалось посчитать размер: $Path ($_)" 
    return 0
  }
}

function Remove-PathSafe([string]$Path) {
  if (-not (Test-Path $Path)) { return 0 }
  $size = Get-FolderSize $Path
  try {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  } catch {
    # Иногда помогает повторная попытка (блокировки)
    Start-Sleep -Milliseconds 200
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
  return $size
}

# Очистка по маске в каталоге (например, старые логи)
function Remove-OldFiles([string]$Path,[string]$Filter,[int]$OlderThanDays) {
  if (-not (Test-Path $Path)) { return 0 }
  $limit = (Get-Date).AddDays(-$OlderThanDays)
  $bytes = 0L
  Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $limit } |
    ForEach-Object { $bytes += $_.Length; if ($Clean) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } }
  return $bytes
}

# --- Набор целей --------------------------------------------------------------
$Targets = @(
  @{ Name='Windows TEMP';        Path="$TargetDrive\Windows\Temp";                                 Type='folder' }
  @{ Name='User TEMP (all)';     Path="$TargetDrive\Users";                                        Type='usertemp' }
  @{ Name='WinSxS Temp Files';   Path="$TargetDrive\Windows\WinSxS\Temp";                          Type='folder' }
  @{ Name='WU Cache';            Path="$TargetDrive\Windows\SoftwareDistribution\Download";        Type='folder' }
  @{ Name='CBS Logs';            Path="$TargetDrive\Windows\Logs\CBS";                             Type='folder' }
  @{ Name='DISM Logs';           Path="$TargetDrive\Windows\Logs\DISM";                            Type='folder' }
  @{ Name='IIS Logs';            Path="$TargetDrive\inetpub\logs\LogFiles";                        Type='iislogs' }
  @{ Name='Crash Dumps';         Path="$TargetDrive\ProgramData\Microsoft\Windows\WER\ReportQueue";Type='folder' }
  @{ Name='Recycle Bin';         Path="$TargetDrive\$Recycle.Bin";                                 Type='recycle' }
)

$report = [System.Collections.Generic.List[object]]::new()
$totalBefore = 0L
$totalGain   = 0L

# --- Сканирование и (по запросу) очистка -------------------------------------
foreach ($t in $Targets) {
  $name = $t.Name; $path = $t.Path; $type = $t.Type
  switch ($type) {
    'folder' {
      $size = Get-FolderSize $path
      $gain = if ($Clean -and $PSCmdlet.ShouldProcess($path, "Remove")) { Remove-PathSafe $path } else { $size }
      if ($Clean -and (Test-Path $path -PathType Container -ErrorAction SilentlyContinue -ea 0) -eq $false) {
        # Восстановим пустую папку для системных директорий, где это уместно
        $parent = Split-Path $path -Parent
        if (Test-Path $parent) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
      }
      $report.Add([pscustomobject]@{Категория=$name; Путь=$path; Размер=Format-Bytes $size; Освобождено=Format-Bytes $gain })
      $totalBefore += $size; if ($Clean) { $totalGain += $gain }
    }
    'usertemp' {
      if (-not (Test-Path $path)) { continue }
      Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $tmp = Join-Path $_.FullName 'AppData\Local\Temp'
        if (Test-Path $tmp) {
          $size = Get-FolderSize $tmp
          $gain = if ($Clean -and $PSCmdlet.ShouldProcess($tmp, "Remove")) { Remove-PathSafe $tmp } else { $size }
          if ($Clean) { New-Item -ItemType Directory -Force -Path $tmp | Out-Null }
          $report.Add([pscustomobject]@{Категория='User TEMP'; Путь=$tmp; Размер=Format-Bytes $size; Освобождено=Format-Bytes $gain })
          $totalBefore += $size; if ($Clean) { $totalGain += $gain }
        }
      }
    }
    'iislogs' {
      $pathRoot = $path
      if (Test-Path $pathRoot) {
        $sizeAll = Get-FolderSize $pathRoot
        $gain = Remove-OldFiles -Path $pathRoot -Filter '*.log' -OlderThanDays $IISLogMaxAgeDays
        $report.Add([pscustomobject]@{Категория="IIS Logs (<$IISLogMaxAgeDays d kept)"; Путь=$pathRoot; Размер=Format-Bytes $sizeAll; Освобождено=Format-Bytes ($Clean ? $gain : 0) })
        $totalBefore += $sizeAll; if ($Clean) { $totalGain += $gain }
      }
    }
    'recycle' {
      $size = Get-FolderSize $path
      $gain = 0L
      if ($Clean -and $EmptyRecycleBin) {
        try {
          # Используем Shell.Application для очистки корзины без запроса
          $shell = New-Object -ComObject Shell.Application
          $recycleBin = $shell.Namespace(10) # 10 = Recycle Bin
          if ($recycleBin) {
            # Нет прямого API для "Empty", но можно вызвать утилиту:
            Start-Process -FilePath "cmd.exe" -ArgumentList '/c','PowerShell -NoProfile -Command Clear-RecycleBin -Force' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
          }
        } catch { Write-Verbose "Не удалось очистить корзину: $_" }
        # Оценим выгоду как весь размер корзины
        $gain = $size
      }
      $report.Add([pscustomobject]@{Категория='Recycle Bin'; Путь=$path; Размер=Format-Bytes $size; Освобождено=Format-Bytes ($Clean -and $EmptyRecycleBin ? $gain : 0) })
      $totalBefore += $size; if ($Clean -and $EmptyRecycleBin) { $totalGain += $gain }
    }
  }
}

# --- Вывод отчёта -------------------------------------------------------------
""
"=== Отчёт по очистке диска $TargetDrive ==="
$report | Sort-Object Категория | Format-Table -AutoSize
""
"Потенциально занято: $(Format-Bytes $totalBefore)"
if ($Clean) { "Освобождено:        $(Format-Bytes $totalGain)" }

Stop-Transcript | Out-Null

if ($Preview -and -not $Clean) {
  Write-Host "`nРежим PREVIEW: ничего не удалено. Для очистки запустите с параметром -Clean (и при необходимости -EmptyRecycleBin)." -ForegroundColor Yellow
}
