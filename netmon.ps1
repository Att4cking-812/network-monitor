param(
    [int]$Rounds = 30,
    [int]$Timeout = 1200
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

# --- цели ---
$gateway = $null
try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($route) { $gateway = $route.NextHop }
} catch {}

$targets = New-Object System.Collections.ArrayList
if ($gateway) { [void]$targets.Add([pscustomobject]@{ Name = 'Роутер'; Host = $gateway }) }
foreach ($h in @(
    @{ Name = 'Cloudflare'; Host = '1.1.1.1' },
    @{ Name = 'Google';     Host = '8.8.8.8' },
    @{ Name = 'Яндекс';     Host = 'ya.ru' },
    @{ Name = 'Discord';    Host = 'discord.com' }
)) { [void]$targets.Add([pscustomobject]$h) }

$stats = @{}
foreach ($t in $targets) {
    $stats[$t.Host] = [pscustomobject]@{
        Sent = 0; Lost = 0; Min = [double]::MaxValue; Max = 0; Sum = 0; Got = 0; Last = $null; LastOk = $false; History = @()
    }
}

$ping = New-Object System.Net.NetworkInformation.Ping
$startTime = Get-Date
$log = New-Object System.Collections.Generic.List[string]
$log.Add("time,host,latency_ms,status")

function Bar([double]$ms) {
    if ($ms -lt 0) { return ('-' * 12) }
    $n = [int][Math]::Min(12, [Math]::Ceiling($ms / 15))
    return ('█' * $n).PadRight(12, '·')
}

try {
    for ($round = 1; $round -le $Rounds; $round++) {
        Clear-Host
        Write-Host ''
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host ("   МОНИТОРИНГ СЕТИ   —   раунд {0}/{1}   ({2})" -f $round, $Rounds, (Get-Date).ToString('HH:mm:ss')) -ForegroundColor Cyan
        Write-Host '  ==============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '   Цель          Сейчас   График           Мин    Ср    Макс   Потери' -ForegroundColor DarkGray
        Write-Host '   --------------------------------------------------------------'

        foreach ($t in $targets) {
            $st = $stats[$t.Host]
            $ms = -1; $ok = $false
            try {
                $reply = $ping.Send($t.Host, $Timeout)
                if ($reply.Status -eq 'Success') {
                    $ms = [math]::Round($reply.RoundtripTime, 1)
                    $ok = $true
                }
            } catch { }

            $st.Sent++
            $st.Last = $ms
            $st.LastOk = $ok
            if ($ok) {
                $st.Got++
                $st.Sum += $ms
                if ($ms -lt $st.Min) { $st.Min = $ms }
                if ($ms -gt $st.Max) { $st.Max = $ms }
                $st.History += $ms
            } else {
                $st.Lost++
            }

            $lossPct = if ($st.Sent -gt 0) { [math]::Round(100 * $st.Lost / $st.Sent, 0) } else { 0 }
            $avg = if ($st.Got -gt 0) { [math]::Round($st.Sum / $st.Got, 1) } else { 0 }
            $minv = if ($st.Got -gt 0) { $st.Min } else { 0 }

            $color = if (-not $ok) { 'Red' } elseif ($ms -lt 40) { 'Green' } elseif ($ms -lt 90) { 'Yellow' } else { 'DarkYellow' }
            $nowText = if ($ok) { ('{0,5:N0} мс' -f $ms) } else { '   потеря' }
            $line = "   {0,-12}  {1}  {2}  {3,4:N0}   {4,4:N0}  {5,5:N0}   {6,3}%" -f `
                $t.Name, $nowText, (Bar $ms), $minv, $avg, $st.Max, $lossPct
            Write-Host $line -ForegroundColor $color

            $log.Add(("{0},{1},{2},{3}" -f (Get-Date).ToString('HH:mm:ss'), $t.Host, $(if ($ok) { $ms } else { '' }), $(if ($ok) { 'ok' } else { 'loss' })))
        }

        Write-Host ''
        Write-Host '   Ctrl+C — остановить досрочно' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
} catch [System.Management.Automation.Host.ControlCAbortedException] {
}

# --- итог ---
Clear-Host
Write-Host ''
Write-Host '  ==============================================================' -ForegroundColor Cyan
Write-Host '                    ИТОГИ МОНИТОРИНГА' -ForegroundColor Cyan
Write-Host '  ==============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '   Цель          Отправлено  Потеряно  Потери   Мин    Ср    Макс   Джиттер' -ForegroundColor DarkGray
Write-Host '   ------------------------------------------------------------------------'
foreach ($t in $targets) {
    $st = $stats[$t.Host]
    $lossPct = if ($st.Sent -gt 0) { [math]::Round(100 * $st.Lost / $st.Sent, 1) } else { 0 }
    $avg = if ($st.Got -gt 0) { [math]::Round($st.Sum / $st.Got, 1) } else { 0 }
    $minv = if ($st.Got -gt 0) { $st.Min } else { 0 }
    $jit = 0
    if ($st.History.Count -gt 1) {
        $diffs = @()
        for ($i = 1; $i -lt $st.History.Count; $i++) { $diffs += [Math]::Abs($st.History[$i] - $st.History[$i - 1]) }
        $jit = [math]::Round(($diffs | Measure-Object -Average).Average, 1)
    }
    $color = if ($lossPct -gt 5) { 'Red' } elseif ($lossPct -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ("   {0,-12}  {1,10}  {2,8}  {3,5:N1}%  {4,4:N0}  {5,4:N0}  {6,5:N0}   {7,5:N1}" -f `
        $t.Name, $st.Sent, $st.Lost, $lossPct, $minv, $avg, $st.Max, $jit) -ForegroundColor $color
}
Write-Host ''
Write-Host ("   Длительность: {0:N0} сек" -f ((Get-Date) - $startTime).TotalSeconds) -ForegroundColor DarkGray

$logDir = Join-Path $env:USERPROFILE 'Desktop\Мониторинг сети'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("ping_{0}.csv" -f (Get-Date).ToString('yyyy-MM-dd_HH-mm'))
$log | Set-Content -LiteralPath $logFile -Encoding UTF8
Write-Host ("   Лог: {0}" -f $logFile) -ForegroundColor DarkGray
Write-Host ''
Read-Host '   Нажми Enter, чтобы закрыть'
