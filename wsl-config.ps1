# =============================================================================
#  setup-wsl-windows.ps1
#  Запускать на Windows (PowerShell от имени Администратора)
#
#  Что делает:
#    1. Определяет ресурсы машины и создаёт оптимальный .wslconfig
#    2. Создаёт задачу в Планировщике задач для автозапуска WSL + Docker
#    3. Проверяет что WSL2 установлен и настроен корректно
# =============================================================================
#Requires -RunAsAdministrator

param([string]$WslDistro = "Ubuntu", [int]$MemoryPercent = 50, [int]$CpuPercent = 50, [int]$SwapPercent = 25, [string]$DockerStartCmd = "service docker start", [string]$TaskName = "WSL2-Docker-Autostart")
$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = [System.Text.Encoding]::Unicode

# ── Цвета (работают в Windows Terminal / PowerShell 5+) ──────────────────────
function Write-Header {
    param($t) Write-Host "`n$('='*50)" -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host "$('='*50)`n" -ForegroundColor Cyan 
}
function Write-Step { param($t) Write-Host "  --> $t" -ForegroundColor Yellow }
function Write-Ok { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "  [!!] $t" -ForegroundColor Magenta }
function Write-Fail { param($t) Write-Host "  [XX] $t" -ForegroundColor Red }
function Write-Info { param($t) Write-Host "       $t" -ForegroundColor Gray }

# =============================================================================
#  ФУНКЦИИ
# =============================================================================

function Get-SystemResources {
    Write-Step "Считываем ресурсы системы..."

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor

    $totalRamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $cpuCores = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

    $wslRamGB = [math]::Max(1, [math]::Round($totalRamGB * $MemoryPercent / 100, 0))
    $wslCpus = [math]::Max(1, [math]::Round($cpuCores * $CpuPercent / 100, 0))
    $wslSwapGB = [math]::Max(1, [math]::Round($wslRamGB * $SwapPercent / 100, 0))

    Write-Ok "Физическая RAM:  ${totalRamGB} GB  →  WSL2 получит: ${wslRamGB} GB"
    Write-Ok "Логических CPU:  ${cpuCores}       →  WSL2 получит: ${wslCpus}"
    Write-Ok "Swap для WSL2:   ${wslSwapGB} GB"

    return @{
        RamGB  = $wslRamGB
        Cpus   = $wslCpus
        SwapGB = $wslSwapGB
    }
}

function Write-WslConfig {
    param([hashtable]$Resources)

    Write-Step "Создание .wslconfig..."

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"

    # Путь для swap-файла (на Windows диске, рядом с .wslconfig)
    $swapPath = "$env:USERPROFILE\wsl-swap.vhdx"
    # В .wslconfig путь нужен с обратными слэшами и без буквы диска — используем полный путь
    $swapPathEscaped = $swapPath -replace '\\', '\\'

    $config = @"
# .wslconfig — глобальные настройки WSL2
# Сгенерировано setup-wsl-windows.ps1
# Документация: https://learn.microsoft.com/en-us/windows/wsl/wsl-config

[wsl2]

# ── Ресурсы ──────────────────────────────────────────────────────────────────
# Максимальный объём RAM для всех WSL2 дистрибутивов
memory=$($Resources.RamGB)GB

# Количество виртуальных процессоров
processors=$($Resources.Cpus)

# Размер swap-файла
swap=$($Resources.SwapGB)GB

# Путь к swap-файлу (на Windows диске — не теряется при пересоздании WSL)
swapfile=$swapPathEscaped

# ── Сеть ─────────────────────────────────────────────────────────────────────
# Зеркальный сетевой стек: WSL2 видит те же интерфейсы что и Windows (вкл. VPN)
# Доступно начиная с WSL 2.0 (Windows 11 22H2+ или Win10 с обновлением)
networkingMode=mirrored

# Включить DNS Tunneling (решает проблемы с резолвингом внутри WSL через VPN)
dnsTunneling=true

# Firewall интеграция с Windows Defender Firewall
firewall=true

# ── Производительность ───────────────────────────────────────────────────────
# Вложенная виртуализация (нужна для некоторых контейнеров)
nestedVirtualization=true

# Автоматически освобождать память WSL2 обратно Windows при уменьшении нагрузки
# (работает в фоне, небольшой оверхед — можно отключить если не нужно)
pageReporting=true

# ── GUI / Прочее ─────────────────────────────────────────────────────────────
# Не запускать GUI-приложения из WSL (нам не нужно, только Docker)
guiApplications=false

# Не использовать sparse VHD (стабильнее для production)
sparseVhd=false
"@

    Set-Content -Path $wslConfigPath -Value $config -Encoding UTF8
    Write-Ok "Записан: $wslConfigPath"

    # Показываем итоговый файл
    Write-Info ""
    Write-Info "Содержимое .wslconfig:"
    Get-Content $wslConfigPath | ForEach-Object { Write-Info "  $_" }
}

function New-WslAutostartTask {
    Write-Step "Создание задачи в Планировщике задач: '$TaskName'..."

    # Скрипт который будет запускаться при старте Windows
    # Он: 1) стартует WSL 2) внутри WSL запускает Docker 3) ждёт сокет
    $startupScript = @"
# Запуск WSL2 + Docker при старте Windows
# Файл: $env:PROGRAMDATA\WSL-Docker\wsl-autostart.ps1

`$distro  = "$WslDistro"
`$logFile = "`$env:PROGRAMDATA\WSL-Docker\autostart.log"

function Log { param(`$msg) "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') `$msg" | Tee-Object -FilePath `$logFile -Append }

Log "=== WSL2 Docker Autostart ==="

# Ждём загрузки сети (важно после перезагрузки)
Start-Sleep -Seconds 10

# Проверяем что WSL установлен
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Log "ERROR: WSL не найден"
    exit 1
}

# Запускаем WSL (первый запуск инициализирует дистрибутив)
Log "Запуск дистрибутива: `$distro"
wsl -d `$distro --exec echo "WSL started" 2>&1 | ForEach-Object { Log `$_ }

# Запускаем Docker внутри WSL
Log "Запуск Docker..."
wsl -d `$distro --exec sudo $DockerStartCmd 2>&1 | ForEach-Object { Log `$_ }

# Проверка что Docker сокет появился
`$maxWait = 30
`$waited  = 0
do {
    `$sockExists = wsl -d `$distro --exec test -S /var/run/docker.sock 2>`$null
    if (`$LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
    `$waited += 2
} while (`$waited -lt `$maxWait)

if (`$waited -lt `$maxWait) {
    Log "Docker запущен успешно (ждали `${waited}с)"
} else {
    Log "WARN: Docker сокет не появился за `${maxWait}с — возможна проблема"
}

Log "=== Готово ==="
"@

    # Создаём папку и скрипт
    $scriptDir = "$env:PROGRAMDATA\WSL-Docker"
    $scriptPath = "$scriptDir\wsl-autostart.ps1"
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    Set-Content -Path $scriptPath -Value $startupScript -Encoding UTF8
    Write-Ok "Скрипт автозапуска: $scriptPath"

    # Удаляем старую задачу если есть
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Info "Старая задача удалена"
    }

    # Action: запуск PowerShell скрипта скрытно
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""

    # Trigger: при входе любого пользователя в систему
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    # Trigger: при запуске системы (через 30 сек, ждём сеть)
    $triggerBoot = New-ScheduledTaskTrigger -AtStartup
    # Добавляем задержку к триггеру загрузки
    $triggerBoot.Delay = "PT30S"

    # Settings
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit    (New-TimeSpan -Minutes 5) `
        -RestartCount          3 `
        -RestartInterval       (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable    `
        -RunOnlyIfNetworkAvailable

    # Principal: запуск от имени SYSTEM (не требует входа пользователя)
    $principal = New-ScheduledTaskPrincipal `
        -UserId    "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    # Регистрируем задачу
    Register-ScheduledTask `
        -TaskName   $TaskName `
        -Action     $action `
        -Trigger    @($triggerBoot, $triggerLogon) `
        -Settings   $settings `
        -Principal  $principal `
        -Description "Автозапуск WSL2 и Docker Engine при старте Windows" `
    | Out-Null

    Write-Ok "Задача '$TaskName' создана в Планировщике задач"
    Write-Info "Триггеры: при загрузке системы (через 30с) + при входе пользователя"
    Write-Info "Лог автозапуска: $scriptDir\autostart.log"
}

function Test-WslInstallation {
    Write-Step "Проверка WSL2..."

    # Проверяем наличие WSL
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Warn "WSL не установлен! Установите командой (в PowerShell Admin):"
        Write-Info "  wsl --install -d Ubuntu"
        Write-Info "  После установки перезагрузите компьютер и запустите скрипт снова."
        return $false
    }

    # Проверяем версию WSL
    $wslStatus = wsl --status 2>&1
    Write-Ok "WSL доступен"

    # Проверяем что нужный дистрибутив установлен
    $distros = wsl --list --quiet 2>&1
    if ($distros -match $WslDistro) {
        Write-Ok "Дистрибутив '$WslDistro' найден"
    }
    else {
        Write-Warn "Дистрибутив '$WslDistro' не найден. Доступные:"
        wsl --list 2>&1 | ForEach-Object { Write-Info "  $_" }
        Write-Info "Установите: wsl --install -d $WslDistro"
        return $false
    }

    # Проверяем что дистрибутив работает как WSL2
    $wslVersion = wsl --list --verbose 2>&1 | Select-String $WslDistro
    if ($wslVersion -match "2") {
        Write-Ok "Дистрибутив работает в режиме WSL2"
    }
    else {
        Write-Warn "Дистрибутив может работать в WSL1. Конвертируйте:"
        Write-Info "  wsl --set-version $WslDistro 2"
    }

    return $true
}

function Invoke-WslShutdownAndRestart {
    Write-Step "Перезапуск WSL2 для применения .wslconfig..."
    wsl --shutdown 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    Write-Ok "WSL2 остановлен"

    # Запускаем задачу сразу (не ждать перезагрузки)
    Write-Step "Запуск задачи автостарта немедленно..."
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5

    $taskInfo = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    Write-Ok "Задача запущена. Последний результат: $($taskInfo.LastTaskResult)"
}

function Show-Summary {
    Write-Host ""
    Write-Host "$('='*50)" -ForegroundColor Green
    Write-Host "  Настройка завершена успешно!" -ForegroundColor Green
    Write-Host "$('='*50)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Что настроено:" -ForegroundColor White
    Write-Host "    [+] $env:USERPROFILE\.wslconfig — лимиты ресурсов WSL2" -ForegroundColor Gray
    Write-Host "    [+] Планировщик задач '$TaskName'" -ForegroundColor Gray
    Write-Host "    [+] Скрипт автозапуска в ProgramData\WSL-Docker\" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Управление:" -ForegroundColor White
    Write-Host "    Запустить WSL+Docker вручную:" -ForegroundColor Gray
    Write-Host "      Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
    Write-Host "    Посмотреть лог автозапуска:" -ForegroundColor Gray
    Write-Host "      Get-Content `"$env:PROGRAMDATA\WSL-Docker\autostart.log`"" -ForegroundColor Cyan
    Write-Host "    Остановить WSL полностью:" -ForegroundColor Gray
    Write-Host "      wsl --shutdown" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  После следующей перезагрузки Windows — Docker" -ForegroundColor Yellow
    Write-Host "  запустится автоматически через 30 секунд." -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
#  ТОЧКА ВХОДА
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "  ██╗    ██╗███████╗██╗     ██████╗      ██████╗ ██████╗ ███╗  ██╗███████╗" -ForegroundColor Cyan
Write-Host "  ██║    ██║██╔════╝██║     ╚════██╗    ██╔════╝██╔═══██╗████╗ ██║██╔════╝" -ForegroundColor Cyan
Write-Host "  ██║ █╗ ██║███████╗██║      █████╔╝    ██║     ██║   ██║██╔██╗██║█████╗  " -ForegroundColor Cyan
Write-Host "  ██║███╗██║╚════██║██║     ██╔═══╝     ██║     ██║   ██║██║╚████║██╔══╝  " -ForegroundColor Cyan
Write-Host "  ╚███╔███╔╝███████║███████╗███████╗    ╚██████╗╚██████╔╝██║ ╚███║██║     " -ForegroundColor Cyan
Write-Host "   ╚══╝╚══╝ ╚══════╝╚══════╝╚══════╝     ╚═════╝ ╚═════╝ ╚═╝  ╚══╝╚═╝     " -ForegroundColor Cyan
Write-Host ""
Write-Host "  WSL2 Resource Config + Docker Autostart Setup" -ForegroundColor White
Write-Host "  Дистрибутив: $WslDistro | RAM: ${MemoryPercent}% | CPU: ${CpuPercent}%" -ForegroundColor Gray
Write-Host ""

Write-Header "ШАГ 1: ПРОВЕРКА WSL2"
$wslOk = Test-WslInstallation
if (-not $wslOk) {
    Write-Warn "WSL2 не готов. Настройка .wslconfig и автозапуска будет выполнена,"
    Write-Warn "но Docker не запустится пока не установлен дистрибутив."
}

Write-Header "ШАГ 2: НАСТРОЙКА РЕСУРСОВ (.wslconfig)"
$resources = Get-SystemResources
Write-WslConfig -Resources $resources

Write-Header "ШАГ 3: АВТОЗАПУСК ЧЕРЕЗ ПЛАНИРОВЩИК ЗАДАЧ"
New-WslAutostartTask

Write-Header "ШАГ 4: ПРИМЕНЕНИЕ НАСТРОЕК"
if ($wslOk) {
    Invoke-WslShutdownAndRestart
}
else {
    Write-Info "Пропускаем перезапуск WSL (дистрибутив не установлен)"
}

Show-Summary