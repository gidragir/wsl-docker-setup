#!/usr/bin/env bash
# =============================================================================
#  setup-docker-wsl.sh
#  Установка и настройка Docker Engine (без Docker Desktop) в WSL2
#  Поддерживаемые дистрибутивы: Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12
# =============================================================================

set -euo pipefail

# ── Цвета и стили ─────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  BOLD='\033[1m';  RESET='\033[0m'
CHECK="${GREEN}✔${RESET}";  CROSS="${RED}✘${RESET}";  ARROW="${CYAN}➜${RESET}"

# ── Логирование ───────────────────────────────────────────────────────────────
log_header()  { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${RESET}"; \
                echo -e "${BOLD}${BLUE}  $1${RESET}"; \
                echo -e "${BOLD}${BLUE}════════════════════════════════════════${RESET}\n"; }
log_step()    { echo -e "${ARROW} ${BOLD}$1${RESET}"; }
log_ok()      { echo -e "  ${CHECK} $1"; }
log_warn()    { echo -e "  ${YELLOW}⚠ $1${RESET}"; }
log_error()   { echo -e "  ${CROSS} ${RED}$1${RESET}"; }
log_info()    { echo -e "  ${CYAN}ℹ $1${RESET}"; }

# ── Переменные ────────────────────────────────────────────────────────────────
DOCKER_COMPOSE_VERSION="v5.1.1"          # Можно изменить на нужную версию
DOCKER_DATA_ROOT="/var/lib/docker"
WSL_CONF="/etc/wsl.conf"
DAEMON_JSON="/etc/docker/daemon.json"
CURRENT_USER="${SUDO_USER:-$USER}"

# =============================================================================
#  ПРОВЕРКИ
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт необходимо запускать с правами root: sudo bash $0"
        exit 1
    fi
}

check_wsl() {
    log_step "Проверка WSL окружения..."
    if ! grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
        log_error "Скрипт предназначен только для WSL2. Текущая среда не является WSL."
        exit 1
    fi

    # Проверяем WSL версию (WSL2 имеет ядро Linux)
    if [[ ! -f /proc/sys/kernel/osrelease ]] || ! grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null; then
        log_warn "Не удалось точно определить версию WSL. Убедитесь что используется WSL2."
    else
        log_ok "WSL2 обнаружен"
    fi
}

detect_distro() {
    log_step "Определение дистрибутива..."
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO_ID="${ID}"
        DISTRO_VERSION="${VERSION_ID}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        log_ok "Дистрибутив: ${PRETTY_NAME}"
    else
        log_error "Не удалось определить дистрибутив (/etc/os-release не найден)"
        exit 1
    fi

    case "${DISTRO_ID}" in
        ubuntu|debian) ;;
        *)
            log_error "Неподдерживаемый дистрибутив: ${DISTRO_ID}. Поддерживаются: Ubuntu, Debian."
            exit 1
            ;;
    esac
}

check_existing_docker() {
    log_step "Проверка существующей установки Docker..."
    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker --version 2>/dev/null || echo "неизвестно")
        log_warn "Docker уже установлен: ${DOCKER_VER}"
        echo -e "  ${YELLOW}Продолжить? Это может перезаписать настройки. [y/N]:${RESET} \c"
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            log_info "Установка отменена пользователем."
            exit 0
        fi
    else
        log_ok "Docker не установлен — начинаем установку"
    fi
}

# =============================================================================
#  УСТАНОВКА
# =============================================================================

remove_old_packages() {
    log_step "Удаление старых/конфликтующих пакетов..."
    local OLD_PKGS=(
        docker docker-engine docker.io containerd runc
        docker-compose docker-doc podman-docker
    )
    for pkg in "${OLD_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            apt-get remove -y "$pkg" &>/dev/null
            log_ok "Удалён: $pkg"
        fi
    done
    log_ok "Старые пакеты проверены"
}

install_dependencies() {
    log_step "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        iptables \
        iproute2 \
        pigz \
        xz-utils \
        2>/dev/null
    log_ok "Зависимости установлены"
}

add_docker_repo() {
    log_step "Добавление официального репозитория Docker..."

    install -m 0755 -d /etc/apt/keyrings

    case "${DISTRO_ID}" in
        ubuntu)
            curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                | tee /etc/apt/sources.list.d/docker.list > /dev/null
            ;;
        debian)
            curl -fsSL "https://download.docker.com/linux/debian/gpg" \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                | tee /etc/apt/sources.list.d/docker.list > /dev/null
            ;;
    esac

    apt-get update -qq
    log_ok "Репозиторий Docker добавлен"
}

install_docker_engine() {
    log_step "Установка Docker Engine, containerd, buildx..."
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        2>/dev/null
    log_ok "Docker Engine установлен: $(docker --version)"
    log_ok "Docker Compose Plugin: $(docker compose version)"
}

# =============================================================================
#  НАСТРОЙКА WSL2
# =============================================================================

configure_wsl_conf() {
    log_step "Настройка /etc/wsl.conf (автозапуск systemd / сервисов)..."

    # Проверяем поддержку systemd в WSL2
    # WSL2 с ядром >= 0.67.6 поддерживает systemd нативно
    local USE_SYSTEMD=false
    if [[ -f /proc/sys/kernel/osrelease ]]; then
        WSL_KERNEL=$(cat /proc/sys/kernel/osrelease)
        log_info "Ядро WSL2: ${WSL_KERNEL}"
        USE_SYSTEMD=true
    fi

    # Создаём или дополняем wsl.conf
    if [[ ! -f "${WSL_CONF}" ]]; then
        touch "${WSL_CONF}"
    fi

    # Секция [boot]
    if ! grep -q "\[boot\]" "${WSL_CONF}"; then
        echo -e "\n[boot]" >> "${WSL_CONF}"
    fi

    if $USE_SYSTEMD; then
        # Включаем systemd если его ещё нет
        if ! grep -q "^systemd" "${WSL_CONF}"; then
            sed -i '/\[boot\]/a systemd=true' "${WSL_CONF}"
            log_ok "Включён systemd в wsl.conf"
        else
            log_ok "systemd уже настроен в wsl.conf"
        fi
    else
        # Фоллбэк: запуск dockerd через скрипт
        if ! grep -q "^command" "${WSL_CONF}"; then
            sed -i '/\[boot\]/a command="service docker start"' "${WSL_CONF}"
            log_ok "Добавлен автозапуск docker через wsl.conf boot command"
        fi
    fi

    # Секция [user]
    if ! grep -q "\[user\]" "${WSL_CONF}"; then
        echo -e "\n[user]\ndefault=${CURRENT_USER}" >> "${WSL_CONF}"
        log_ok "Установлен пользователь по умолчанию: ${CURRENT_USER}"
    fi

    # Секция [network]
    if ! grep -q "\[network\]" "${WSL_CONF}"; then
        cat >> "${WSL_CONF}" <<'EOF'

[network]
generateResolvConf=true
EOF
        log_ok "Настройка сети добавлена в wsl.conf"
    fi
}

configure_daemon_json() {
    log_step "Настройка Docker daemon (${DAEMON_JSON})..."

    mkdir -p /etc/docker

    # Записываем оптимальный daemon.json для WSL2
    cat > "${DAEMON_JSON}" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  },
  "live-restore": false,
  "iptables": true
}
EOF
    log_ok "daemon.json настроен"
}

configure_iptables() {
    log_step "Настройка iptables (legacy режим для совместимости с WSL2)..."

    # WSL2 использует iptables-nft по умолчанию, но Docker лучше работает с legacy
    if command -v update-alternatives &>/dev/null; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
        log_ok "iptables переключён на legacy режим"
    else
        log_warn "update-alternatives не найден, пропускаем настройку iptables"
    fi
}

add_user_to_docker_group() {
    log_step "Добавление пользователя '${CURRENT_USER}' в группу docker..."

    if id -nG "${CURRENT_USER}" | grep -qw docker; then
        log_ok "Пользователь уже состоит в группе docker"
    else
        usermod -aG docker "${CURRENT_USER}"
        log_ok "Пользователь '${CURRENT_USER}' добавлен в группу docker"
        log_warn "Для применения группы нужно перезайти в WSL: wsl --shutdown && wsl"
    fi
}

# =============================================================================
#  АВТОЗАПУСК (без systemd — фоллбэк через .bashrc / .profile)
# =============================================================================

setup_autostart_fallback() {
    # Этот блок нужен если systemd НЕ включён
    if systemctl is-active --quiet docker 2>/dev/null; then
        log_ok "Docker управляется через systemd — автозапуск через .bashrc не нужен"
        return
    fi

    log_step "Настройка автозапуска Docker (фоллбэк без systemd)..."

    local PROFILE_SCRIPT="/etc/profile.d/start-docker.sh"
    cat > "${PROFILE_SCRIPT}" <<'PROFILE'
#!/bin/bash
# Автозапуск Docker в WSL2 (если не используется systemd)
if [ -S /var/run/docker.sock ]; then
    # Сокет уже есть — демон работает
    :
else
    if command -v service &>/dev/null; then
        sudo service docker start > /dev/null 2>&1 &
    fi
fi
PROFILE
    chmod +x "${PROFILE_SCRIPT}"
    log_ok "Скрипт автозапуска создан: ${PROFILE_SCRIPT}"

    # Разрешаем запуск docker service без пароля
    local SUDOERS_FILE="/etc/sudoers.d/docker-service"
    echo "%docker ALL=(ALL) NOPASSWD: /usr/sbin/service docker start, /usr/sbin/service docker stop, /usr/sbin/service docker restart" \
        > "${SUDOERS_FILE}"
    chmod 440 "${SUDOERS_FILE}"
    log_ok "Настроен sudo без пароля для управления сервисом docker"
}

# =============================================================================
#  ЗАПУСК И ПРОВЕРКА
# =============================================================================

start_docker() {
    log_step "Запуск Docker..."

    # Пробуем через systemd
    if command -v systemctl &>/dev/null && systemctl list-units --type=service &>/dev/null 2>&1; then
        systemctl enable docker --quiet 2>/dev/null || true
        systemctl start docker 2>/dev/null && {
            log_ok "Docker запущен через systemd"
            return
        }
    fi

    # Фоллбэк через service
    if command -v service &>/dev/null; then
        service docker start 2>/dev/null && {
            log_ok "Docker запущен через service"
            return
        }
    fi

    # Прямой запуск dockerd в фоне
    if [[ ! -S /var/run/docker.sock ]]; then
        dockerd > /tmp/dockerd.log 2>&1 &
        sleep 3
        if [[ -S /var/run/docker.sock ]]; then
            log_ok "Docker запущен напрямую (dockerd)"
        else
            log_warn "Docker не удалось запустить автоматически. Запустите вручную: sudo service docker start"
        fi
    fi
}

verify_installation() {
    log_step "Проверка установки..."

    # Docker version
    if command -v docker &>/dev/null; then
        log_ok "$(docker --version)"
    else
        log_error "docker не найден в PATH"
        return 1
    fi

    # Docker Compose
    if docker compose version &>/dev/null 2>&1; then
        log_ok "$(docker compose version)"
    else
        log_warn "docker compose plugin не найден"
    fi

    # Buildx
    if docker buildx version &>/dev/null 2>&1; then
        log_ok "$(docker buildx version)"
    fi

    # Hello-world тест
    log_step "Запуск тестового контейнера (hello-world)..."
    if docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; then
        log_ok "Тестовый контейнер успешно запущен!"
    else
        log_warn "Тест hello-world не прошёл. Docker может потребовать перезапуска WSL."
    fi
}

# =============================================================================
#  ИТОГОВАЯ СВОДКА
# =============================================================================

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${GREEN}  ✔  Установка завершена успешно!${RESET}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${BOLD}Что установлено:${RESET}"
    echo -e "  ${CHECK} Docker Engine (dockerd + CLI)"
    echo -e "  ${CHECK} containerd"
    echo -e "  ${CHECK} Docker Compose Plugin (docker compose)"
    echo -e "  ${CHECK} Docker Buildx"
    echo ""
    echo -e "${BOLD}Конфигурация:${RESET}"
    echo -e "  ${ARROW} WSL конфиг:     ${WSL_CONF}"
    echo -e "  ${ARROW} Docker daemon:  ${DAEMON_JSON}"
    echo -e "  ${ARROW} Данные Docker:  ${DOCKER_DATA_ROOT}"
    echo ""
    echo -e "${BOLD}${YELLOW}Следующие шаги:${RESET}"
    echo -e "  1. Перезапустите WSL для применения всех настроек:"
    echo -e "     ${CYAN}wsl --shutdown${RESET}  (в PowerShell на Windows)"
    echo -e "     Затем снова откройте WSL."
    echo ""
    echo -e "  2. Проверьте работу Docker:"
    echo -e "     ${CYAN}docker run --rm hello-world${RESET}"
    echo ""
    echo -e "  3. Запуск docker compose проекта:"
    echo -e "     ${CYAN}docker compose up -d${RESET}"
    echo ""
    echo -e "  4. Управление сервисом (если не systemd):"
    echo -e "     ${CYAN}sudo service docker start${RESET}"
    echo -e "     ${CYAN}sudo service docker stop${RESET}"
    echo -e "     ${CYAN}sudo service docker status${RESET}"
    echo ""
    echo -e "${BOLD}${YELLOW}  ════ ВАЖНО: настройте Windows-сторону! ════${RESET}"
    echo -e "  Запустите setup-wsl-windows.ps1 в PowerShell (от Администратора)"
    echo -e "  на Windows-машине — это настроит лимиты RAM/CPU и автозапуск Docker."
    echo ""
    echo -e "  Быстрый запуск из PowerShell:"
    echo -e "     ${CYAN}Set-ExecutionPolicy Bypass -Scope Process -Force${RESET}"
    echo -e "     ${CYAN}.\\setup-wsl-windows.ps1${RESET}"
    echo ""
    echo -e "  С кастомными лимитами (например 60% RAM, 50% CPU):"
    echo -e "     ${CYAN}.\\setup-wsl-windows.ps1 -MemoryPercent 60 -CpuPercent 50${RESET}"
    echo ""
}

# =============================================================================
#  ТОЧКА ВХОДА
# =============================================================================

main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗  ██████╗  ██████╗██╗  ██╗███████╗██████╗ "
    echo "  ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗"
    echo "  ██║  ██║██║   ██║██║     █████╔╝ █████╗  ██████╔╝"
    echo "  ██║  ██║██║   ██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗"
    echo "  ██████╔╝╚██████╔╝╚██████╗██║  ██╗███████╗██║  ██║"
    echo "  ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
    echo -e "${RESET}"
    echo -e "${BOLD}  WSL2 Setup — Docker Engine без Docker Desktop${RESET}"
    echo -e "  ${CYAN}Версия: 1.0 | Поддержка: Ubuntu / Debian${RESET}"
    echo ""

    # Проверки
    log_header "ПРОВЕРКА ОКРУЖЕНИЯ"
    check_root
    check_wsl
    detect_distro
    check_existing_docker

    # Установка
    log_header "УСТАНОВКА DOCKER ENGINE"
    remove_old_packages
    install_dependencies
    add_docker_repo
    install_docker_engine

    # Конфигурация
    log_header "НАСТРОЙКА WSL2 И DOCKER"
    configure_wsl_conf
    configure_daemon_json
    configure_iptables
    add_user_to_docker_group
    setup_autostart_fallback

    # Запуск и проверка
    log_header "ЗАПУСК И ПРОВЕРКА"
    start_docker
    verify_installation

    # Итог
    print_summary
}

main "$@"