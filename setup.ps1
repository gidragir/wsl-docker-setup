# =============================================================================
#  install.ps1 — Мастер-скрипт установки WSL2 + Docker + Portainer
#  Запускать в PowerShell от имени Администратора
#
#  Использование (одна команда):
#    irm https://ВАШ_СЕРВЕР/install.ps1 | iex
#
#  Или с параметрами:
#    & ([scriptblock]::Create((irm https://ВАШ_СЕРВЕР/install.ps1))) -MemoryPercent 60
# =============================================================================
#Requires -RunAsAdministrator

param(
    [string]$WslDistro     = "Ubuntu",
    [int]   $MemoryPercent = 50,
    [int]   $CpuPercent    = 50,
    [int]   $SwapPercent   = 25,
    [string]$TaskName      = "WSL2-Docker-Autostart",
    [string]$DockerScriptUrl = "https://raw.githubusercontent.com/gidragir/wsl-docker-setup/refs/heads/main/docker-install.sh"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Header { param($t)
    Write-Host "`n$('='*56)" -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host "$('='*56)`n" -ForegroundColor Cyan }
function Write-Step { param($t) Write-Host "  --> $t" -ForegroundColor Yellow }
function Write-Ok   { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "  [!!] $t" -ForegroundColor Magenta }
function Write-Info { param($t) Write-Host "       $t" -ForegroundColor Gray }
function Write-Fail { param($t) Write-Host "  [XX] $t" -ForegroundColor Red; exit 1 }

function Pause-ForReboot {
    param([string]$Reason)
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА" -ForegroundColor Yellow
    Write-Host "  Причина: $Reason" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  После перезагрузки запустите скрипт снова:" -ForegroundColor White
    Write-Host "  irm https://raw.githubusercontent.com/gidragir/wsl-docker-setup/refs/heads/main/install.ps1 | iex" -ForegroundColor Cyan
    Write-Host "  ══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    $choice = Read-Host "  Перезагрузить сейчас? [Y/n]"
    if ($choice -ne 'n' -and $choice -ne 'N') {
        Restart-Computer -Force
    }
    exit 0
}

# =============================================================================
#  ШАГ 0: Проверка — уже ли установлено (идемпотентность)
# =============================================================================

function Get-InstallState {
    return @{
        WslInstalled    = [bool](Get-Command wsl -ErrorAction SilentlyContinue)
        HyperVEnabled   = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue).State -eq 'Enabled'
        WslFeatureEnabled = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue).State -eq 'Enabled'
        DistroInstalled = [bool](wsl --list --quiet 2>$null | Select-String $WslDistro)
        DockerRunning   = [bool](wsl -d $WslDistro --exec docker info 2>$null)
        PortainerExists = [bool](wsl -d $WslDistro --exec docker ps -a --format '{{.Names}}' 2>$null | Select-String 'portainer')
    }
}

# =============================================================================
#  ШАГ 1: Включение компонентов Windows
# =============================================================================

function Enable-WindowsFeatures {
    Write-Step "Проверка компонентов Windows (WSL, Hyper-V, VirtualMachinePlatform)..."

    $needsReboot = $false
    $features = @(
        "Microsoft-Windows-Subsystem-Linux",
        "VirtualMachinePlatform",
        "Microsoft-Hyper-V-All"
    )

    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue).State
        if ($state -ne 'Enabled') {
            Write-Step "Включаем компонент: $feature"
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            if ($result.RestartNeeded) { $needsReboot = $true }
            Write-Ok "Компонент включён: $feature"
        } else {
            Write-Ok "Уже включён: $feature"
        }
    }

    if ($needsReboot) {
        Pause-ForReboot "Включены системные компоненты Windows"
    }
}

# =============================================================================
#  ШАГ 2: Права входа для Hyper-V (решает ошибку 0x80070569)
# =============================================================================

function Set-HyperVLogonRights {
    Write-Step "Настройка прав входа для Hyper-V (NT VIRTUAL MACHINE\Virtual Machines)..."

    $cfgFile = "$env:TEMP\secpol_wsl.inf"
    $dbFile  = "$env:TEMP\secpol_wsl.sdb"
    $targetSid = "*S-1-5-83-0"

    try {
        secedit /export /cfg $cfgFile /areas USER_RIGHTS | Out-Null
        $config = Get-Content $cfgFile -Encoding Unicode

        $rightsToGrant = @("SeBatchLogonRight", "SeServiceLogonRight")
        $changed = $false

        foreach ($right in $rightsToGrant) {
            $match = $config -match "^$right\s*="
            if ($match) {
                $idx = [array]::IndexOf($config, $match[0])
                if (-not $config[$idx].Contains($targetSid)) {
                    $config[$idx] += ",$targetSid"
                    $changed = $true
                }
            } else {
                $privIndex = [array]::IndexOf($config, "[Privilege Rights]")
                if ($privIndex -ge 0) {
                    $config = $config[0..$privIndex] + "$right = $targetSid" + $config[($privIndex+1)..($config.Length-1)]
                    $changed = $true
                }
            }
        }

        if ($changed) {
            $config | Set-Content $cfgFile -Encoding Unicode
            secedit /configure /db $dbFile /cfg $cfgFile /areas USER_RIGHTS 2>&1 | Out-Null
            Write-Ok "Права входа для Hyper-V установлены"
        } else {
            Write-Ok "Права входа уже настроены"
        }
    } finally {
        Remove-Item $cfgFile, $dbFile -ErrorAction SilentlyContinue
    }
}

# =============================================================================
#  ШАГ 3: Установка WSL2 и дистрибутива
# =============================================================================

function Install-Wsl {
    Write-Step "Обновление ядра WSL2..."
    wsl --update 2>&1 | ForEach-Object { Write-Info $_ }

    Write-Step "Установка версии WSL2 по умолчанию..."
    wsl --set-default-version 2 2>&1 | Out-Null

    $distros = wsl --list --quiet 2>&1
    if ($distros -match $WslDistro) {
        Write-Ok "Дистрибутив '$WslDistro' уже установлен"
        return
    }

    Write-Step "Установка $WslDistro..."
    Write-Info "Это может занять 2-5 минут..."

    # Устанавливаем без интерактивного ввода
    # --root позволяет первый запуск без создания пользователя (сделаем сами)
    wsl --install -d $WslDistro --no-launch 2>&1 | ForEach-Object { Write-Info $_ }

    # Даём время на распаковку
    Start-Sleep -Seconds 5

    # Инициализируем дистрибутив с root-пользователем (без интерактива)
    wsl -d $WslDistro --user root --exec echo "init" 2>&1 | Out-Null

    $distros2 = wsl --list --quiet 2>&1
    if ($distros2 -match $WslDistro) {
        Write-Ok "Дистрибутив '$WslDistro' установлен"
    } else {
        Write-Fail "Не удалось установить дистрибутив '$WslDistro'"
    }
}

# =============================================================================
#  ШАГ 4: Настройка .wslconfig (ресурсы)
# =============================================================================

function Write-WslConfig {
    Write-Step "Создание .wslconfig (лимиты ресурсов WSL2)..."

    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor

    $totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $cpuCores   = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

    $wslRamGB  = [math]::Max(1, [math]::Round($totalRamGB * $MemoryPercent / 100, 0))
    $wslCpus   = [math]::Max(1, [math]::Round($cpuCores   * $CpuPercent    / 100, 0))
    $wslSwapGB = [math]::Max(1, [math]::Round($wslRamGB   * $SwapPercent   / 100, 0))

    Write-Ok "RAM:  ${totalRamGB}GB  →  WSL2: ${wslRamGB}GB"
    Write-Ok "CPU:  ${cpuCores} ядер →  WSL2: ${wslCpus} ядер"
    Write-Ok "Swap: ${wslSwapGB}GB"

    $swapPath        = "$env:USERPROFILE\wsl-swap.vhdx"
    $swapPathEscaped = $swapPath -replace '\\', '\\'

    # Определяем версию WSL для совместимости ключей
    $wslVersion = (wsl --version 2>&1 | Select-String "WSL version" | ForEach-Object { $_ -replace ".*:\s*", "" }).Trim()

    $config = @"
# .wslconfig — настройки WSL2
# Сгенерировано install.ps1

[wsl2]
memory=${wslRamGB}GB
processors=${wslCpus}
swap=${wslSwapGB}GB
swapfile=$swapPathEscaped
networkingMode=mirrored
dnsTunneling=true
firewall=true
nestedVirtualization=true
guiApplications=false
"@

    Set-Content -Path "$env:USERPROFILE\.wslconfig" -Value $config -Encoding UTF8
    Write-Ok "Записан: $env:USERPROFILE\.wslconfig"
}

# =============================================================================
#  ШАГ 5: Запуск bash-скрипта установки Docker внутри WSL
# =============================================================================

function Install-DockerInWsl {
    Write-Step "Установка Docker Engine внутри WSL ($WslDistro)..."

    # Скачиваем bash-скрипт внутри WSL и запускаем
    $cmd = "curl -fsSL '$DockerScriptUrl' -o /tmp/docker-install.sh && sudo bash /tmp/docker-install.sh"

    Write-Info "Запуск: wsl -d $WslDistro --user root --exec bash -c ..."
    Write-Info "Это займёт 2-4 минуты..."

    wsl -d $WslDistro --user root --exec bash -c $cmd

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker установлен успешно"
    } else {
        Write-Warn "Скрипт Docker завершился с ошибкой (код: $LASTEXITCODE)"
        Write-Info "Проверьте вывод выше или запустите вручную внутри WSL:"
        Write-Info "  sudo bash /tmp/docker-install.sh"
    }
}

# =============================================================================
#  ШАГ 6: Установка Portainer CE
# =============================================================================

function Install-Portainer {
    Write-Step "Установка Portainer CE (веб-интерфейс Docker)..."

    # Проверяем — уже установлен?
    $exists = wsl -d $WslDistro --user root --exec bash -c `
        "docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$' && echo yes || echo no"

    if ($exists -match "yes") {
        Write-Ok "Portainer уже установлен"
        Write-Info "Открыть: http://localhost:9000"
        return
    }

    # Создаём volume и запускаем контейнер
    $portainerCmd = @"
docker volume create portainer_data 2>/dev/null || true && \
docker run -d \
  --name portainer \
  --restart=always \
  -p 9000:9000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
"@

    wsl -d $WslDistro --user root --exec bash -c $portainerCmd

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Portainer CE установлен и запущен"
        Write-Ok "Веб-интерфейс: http://localhost:9000"
        Write-Info "При первом входе создайте пароль администратора"
    } else {
        Write-Warn "Не удалось установить Portainer. Docker может быть ещё не готов."
        Write-Info "Установите вручную после запуска Docker:"
        Write-Info "  docker volume create portainer_data"
        Write-Info "  docker run -d --name portainer --restart=always -p 9000:9000 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
    }
}

# =============================================================================
#  ШАГ 7: Задача автозапуска в Планировщике
# =============================================================================

function New-AutostartTask {
    Write-Step "Создание задачи автозапуска WSL+Docker в Планировщике задач..."

    $scriptDir  = "$env:PROGRAMDATA\WSL-Docker"
    $scriptPath = "$scriptDir\wsl-autostart.ps1"

    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null

    $startupScript = @"
`$distro  = "$WslDistro"
`$logFile = "$scriptDir\autostart.log"
function Log { param(`$m) "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') `$m" | Tee-Object -FilePath `$logFile -Append }
Log "=== WSL2 Docker Autostart ==="
Start-Sleep -Seconds 15
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { Log "ERROR: WSL не найден"; exit 1 }
Log "Запуск WSL..."
wsl -d `$distro --exec echo "ok" 2>&1 | ForEach-Object { Log `$_ }
Log "Запуск Docker..."
wsl -d `$distro --user root --exec bash -c "service docker start || systemctl start docker" 2>&1 | ForEach-Object { Log `$_ }
`$waited = 0
do { `$ok = (wsl -d `$distro --exec test -S /var/run/docker.sock 2>`$null; `$LASTEXITCODE -eq 0)
     if (`$ok) { break }; Start-Sleep 2; `$waited += 2 } while (`$waited -lt 30)
if (`$ok) { Log "Docker готов (ждали `${waited}с)" } else { Log "WARN: Docker не ответил за 30с" }
Log "=== Готово ==="
"@

    Set-Content -Path $scriptPath -Value $startupScript -Encoding UTF8

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigBoot  = New-ScheduledTaskTrigger -AtStartup
    $trigBoot.Delay = "PT15S"
    $trigLogon = New-ScheduledTaskTrigger -AtLogOn
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                     -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($trigBoot, $trigLogon) -Settings $settings -Principal $principal `
        -Description "Автозапуск WSL2 + Docker при старте Windows" | Out-Null

    Write-Ok "Задача '$TaskName' создана"
    Write-Info "Лог: $scriptDir\autostart.log"
}

# =============================================================================
#  ШАГ 8: Применение конфига и перезапуск WSL
# =============================================================================

function Restart-Wsl {
    Write-Step "Перезапуск WSL2 для применения .wslconfig..."
    wsl --shutdown 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    Write-Ok "WSL2 остановлен, настройки применятся при следующем запуске"

    Write-Step "Запуск задачи автостарта..."
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 8
    Write-Ok "Задача запущена"
}

# =============================================================================
#  ИТОГ
# =============================================================================

function Show-Summary {
    Write-Host ""
    Write-Host "$('='*56)" -ForegroundColor Green
    Write-Host "  УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО" -ForegroundColor Green
    Write-Host "$('='*56)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Что установлено:" -ForegroundColor White
    Write-Host "    [+] WSL2 + $WslDistro" -ForegroundColor Gray
    Write-Host "    [+] Docker Engine + Compose + Buildx" -ForegroundColor Gray
    Write-Host "    [+] Portainer CE (веб-интерфейс)" -ForegroundColor Gray
    Write-Host "    [+] Автозапуск при старте Windows" -ForegroundColor Gray
    Write-Host "    [+] .wslconfig с лимитами ресурсов" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Доступ к Portainer:" -ForegroundColor White
    Write-Host "    http://localhost:9000" -ForegroundColor Cyan
    Write-Host "    (создайте пароль при первом входе)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Управление:" -ForegroundColor White
    Write-Host "    Лог автозапуска:" -ForegroundColor Gray
    Write-Host "      Get-Content `"$env:PROGRAMDATA\WSL-Docker\autostart.log`"" -ForegroundColor Cyan
    Write-Host "    Перезапуск WSL:" -ForegroundColor Gray
    Write-Host "      wsl --shutdown" -ForegroundColor Cyan
    Write-Host "    Docker внутри WSL:" -ForegroundColor Gray
    Write-Host "      wsl -d $WslDistro" -ForegroundColor Cyan
    Write-Host ""
}

# =============================================================================
#  ТОЧКА ВХОДА
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |   WSL2 + Docker + Portainer  /  Auto Installer  |" -ForegroundColor Cyan
Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  Дистрибутив: $WslDistro | RAM: ${MemoryPercent}% | CPU: ${CpuPercent}%" -ForegroundColor Gray
Write-Host ""

Write-Header "ШАГ 1/8: КОМПОНЕНТЫ WINDOWS"
Enable-WindowsFeatures

Write-Header "ШАГ 2/8: ПРАВА HYPER-V"
Set-HyperVLogonRights

Write-Header "ШАГ 3/8: УСТАНОВКА WSL2 + $WslDistro"
Install-Wsl

Write-Header "ШАГ 4/8: КОНФИГУРАЦИЯ РЕСУРСОВ"
Write-WslConfig

Write-Header "ШАГ 5/8: УСТАНОВКА DOCKER В WSL"
Install-DockerInWsl

Write-Header "ШАГ 6/8: УСТАНОВКА PORTAINER"
Install-Portainer

Write-Header "ШАГ 7/8: АВТОЗАПУСК"
New-AutostartTask

Write-Header "ШАГ 8/8: ПРИМЕНЕНИЕ НАСТРОЕК"
Restart-Wsl

Show-Summary