#!/bin/bash

# Функция для создания резервной копии файла
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        sudo cp "$file" "${file}.bak.$(date +%F_%T)" && \
        echo "Резервная копия создана для $file" || \
        echo "Не удалось создать резервную копию для $file"
    else
        echo "Файл $file не найден, пропускаем резервное копирование."
    fi
}

# Функция для определения дистрибутива
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    else
        echo "Не удалось определить дистрибутив."
        exit 1
    fi
}

# Функция для безопасного редактирования sudoers с использованием visudo
safe_edit_sudoers() {
    local content="$1"
    echo "$content" | sudo EDITOR='tee -a' visudo >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Ошибка при редактировании sudoers."
    else
        echo "Успешно обновлён sudoers."
    fi
}

# Обнаружение дистрибутива
detect_distro

# Проверка прав пользователя
if [ "$EUID" -ne 0 ]; then
    echo "Скрипт должен быть запущен с правами суперпользователя (root)."
    exit 1
fi

echo "Начало выполнения скрипта по повышению безопасности..."

#############################
# 2.1 Настройка авторизации #
#############################

echo "Настройка раздела 2.1: Авторизация"

## 2.1.1 Запрет пустых паролей

echo "Отключение возможности использования пустых паролей..."

# Файлы PAM могут различаться в зависимости от дистрибутива
if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    PAM_AUTH_FILE="/etc/pam.d/common-auth"
elif [[ "$DISTRO" == "centos" ]]; then
    PAM_AUTH_FILE="/etc/pam.d/system-auth"
else
    echo "Неизвестный дистрибутив. Пропускаем настройку PAM."
    PAM_AUTH_FILE=""
fi

if [ -n "$PAM_AUTH_FILE" ]; then
    backup_file "$PAM_AUTH_FILE"
    sudo sed -i '/pam_unix.so/s/nullok//' "$PAM_AUTH_FILE" && \
    echo "Удалено 'nullok' из $PAM_AUTH_FILE" || \
    echo "Не удалось удалить 'nullok' из $PAM_AUTH_FILE"
fi

# Блокировка пользователей с пустыми паролями
echo "Блокировка пользователей с пустыми паролями..."
EMPTY_PASS_USERS=$(sudo awk -F: '($2 == "") {print $1}' /etc/shadow)
if [ -n "$EMPTY_PASS_USERS" ]; then
    echo "$EMPTY_PASS_USERS" | xargs -r sudo passwd -l && \
    echo "Пользователи с пустыми паролями заблокированы." || \
    echo "Не удалось заблокировать некоторых пользователей с пустыми паролями."
else
    echo "Пользователи с пустыми паролями не найдены."
fi

# Проверка наличия пользователей с пустыми паролями
echo "Проверка наличия пользователей с пустыми паролями..."
sudo awk -F: '($2 == "") {print "Пользователь " $1 " имеет пустой пароль!"}' /etc/shadow

## 2.1.2 Отключение входа root по SSH
apt install ssh
echo "Отключение входа суперпользователя через SSH..."

SSH_CONFIG_FILE="/etc/ssh/sshd_config"
backup_file "$SSH_CONFIG_FILE"

# Устанавливаем PermitRootLogin no, раскомментируя и изменяя значение
sudo sed -i 's/^#\?PermitRootLogin\s\+.*/PermitRootLogin no/' "$SSH_CONFIG_FILE" && \
echo "Обновлён параметр PermitRootLogin в $SSH_CONFIG_FILE" || \
echo "Не удалось обновить параметр PermitRootLogin в $SSH_CONFIG_FILE"

# Перезапуск SSH-сервиса
echo "Перезапуск SSH-сервиса..."
if [[ "$DISTRO" == "centos" ]]; then
    sudo systemctl restart sshd && \
    echo "Сервис sshd перезапущен." || \
    echo "Не удалось перезапустить сервис sshd."
elif [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    sudo systemctl restart ssh && \
    echo "Сервис ssh перезапущен." || \
    echo "Не удалось перезапустить сервис ssh."
fi

# Проверка настройки
echo "Проверка настройки PermitRootLogin:"
sudo grep '^PermitRootLogin' "$SSH_CONFIG_FILE"

#########################################
# 2.2 Ограничение механизмов получения привилегий #
#########################################

echo "Настройка раздела 2.2: Ограничение привилегий"

## 2.2.1 Ограничение доступа к команде su

echo "Ограничение доступа к команде su..."

PAM_SU_FILE="/etc/pam.d/su"
backup_file "$PAM_SU_FILE"

# Добавляем строку auth required pam_wheel.so use_uid, если её нет
if ! grep -q 'auth\s\+required\s\+pam_wheel.so\s\+use_uid' "$PAM_SU_FILE"; then
    echo "auth required pam_wheel.so use_uid" | sudo tee -a "$PAM_SU_FILE" && \
    echo "Добавлена строка 'auth required pam_wheel.so use_uid' в $PAM_SU_FILE" || \
    echo "Не удалось добавить строку 'auth required pam_wheel.so use_uid' в $PAM_SU_FILE"
else
    echo "Строка 'auth required pam_wheel.so use_uid' уже присутствует в $PAM_SU_FILE"
fi

# Обновление группы wheel/sudo в /etc/group
GROUP_FILE="/etc/group"
backup_file "$GROUP_FILE"

# Определяем группу для sudo
if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    WHEEL_GROUP="sudo"
elif [[ "$DISTRO" == "centos" ]]; then
    WHEEL_GROUP="wheel"
else
    WHEEL_GROUP="wheel"
fi

# Создаём группу, если она не существует
if ! grep -q "^$WHEEL_GROUP:" "$GROUP_FILE"; then
    sudo groupadd "$WHEEL_GROUP" && \
    echo "Группа $WHEEL_GROUP создана." || \
    echo "Не удалось создать группу $WHEEL_GROUP."
else
    echo "Группа $WHEEL_GROUP уже существует."
fi

# Получение списка пользователей с UID >= 1000 и не являющихся nobody
USER_LIST=$(getent passwd | awk -F: '($3 >= 1000) && ($1 != "nobody") {print $1}')

# Добавление текущего пользователя в группу wheel/sudo
CURRENT_USER=$(logname)
if id -nG "$CURRENT_USER" | grep -qw "$WHEEL_GROUP"; then
    echo "Пользователь $CURRENT_USER уже находится в группе $WHEEL_GROUP."
else
    sudo usermod -aG "$WHEEL_GROUP" "$CURRENT_USER" && \
    echo "Пользователь $CURRENT_USER добавлен в группу $WHEEL_GROUP." || \
    echo "Не удалось добавить пользователя $CURRENT_USER в группу $WHEEL_GROUP."
fi

# Добавление всех пользователей с UID >=1000 в группу wheel/sudo
for user in $USER_LIST; do
    if ! id -nG "$user" | grep -qw "$WHEEL_GROUP"; then
        sudo usermod -aG "$WHEEL_GROUP" "$user" && \
        echo "Пользователь $user добавлен в группу $WHEEL_GROUP." || \
        echo "Не удалось добавить пользователя $user в группу $WHEEL_GROUP."
    else
        echo "Пользователь $user уже находится в группе $WHEEL_GROUP."
    fi
done

## 2.2.2 Ограничение использования sudo

echo "Ограничение списка пользователей и команд для sudo..."

SUDOERS_FILE="/etc/sudoers"
backup_file "$SUDOERS_FILE"

# Удаляем строки, предоставляющие sudo доступ напрямую другим группам или пользователям
sudo sed -i '/^%sudo\s\+ALL=(ALL:ALL)\s\+ALL/d' "$SUDOERS_FILE"
sudo sed -i '/^%wheel\s\+ALL=(ALL:ALL)\s\+ALL/d' "$SUDOERS_FILE"

# Добавляем строку для группы wheel/sudo
if [[ "$WHEEL_GROUP" == "wheel" ]]; then
    safe_edit_sudoers "%wheel ALL=(ALL:ALL) ALL"
elif [[ "$WHEEL_GROUP" == "sudo" ]]; then
    safe_edit_sudoers "%sudo ALL=(ALL:ALL) ALL"
fi

echo "Ограничен список пользователей и команд для sudo. Доступ только для группы $WHEEL_GROUP."

##############################################
# 2.3 Настройка прав доступа к файловой системе #
##############################################

echo "Настройка раздела 2.3: Права доступа к файловой системе"

## 2.3.1 Права на /etc/passwd, /etc/group, /etc/shadow

echo "Установка прав доступа к файлам /etc/passwd, /etc/group, /etc/shadow..."
sudo chmod 644 /etc/passwd && echo "Права для /etc/passwd установлены." || echo "Не удалось установить права для /etc/passwd."
sudo chmod 644 /etc/group && echo "Права для /etc/group установлены." || echo "Не удалось установить права для /etc/group."
sudo chmod go-rwx /etc/shadow && echo "Права для /etc/shadow установлены." || echo "Не удалось установить права для /etc/shadow."

## 2.3.2 Права на файлы запущенных процессов

echo "Установка прав доступа к исполняемым файлам запущенных процессов..."

EXECUTABLES=$(sudo lsof -F n | grep '^n' | cut -c2- | sort -u)

for file in $EXECUTABLES; do
    if [ -f "$file" ]; then
        sudo chmod go-w "$file" && \
        echo "Права на $file обновлены." || \
        echo "Не удалось обновить права на $file."
    fi
done

echo "Права на исполняемые файлы установлены."

# Проверка и установка прав на директории, содержащие исполняемые файлы
echo "Установка прав на директории содержащие исполняемые файлы..."
for file in $EXECUTABLES; do
    dir=$(dirname "$file")
    sudo chmod go-w "$dir" && \
    echo "Права на директорию $dir обновлены." || \
    echo "Не удалось обновить права на директорию $dir."
done
echo "Права на директории установлены."

## 2.3.3 Права на файлы cron-заданий

echo "Установка прав доступа к системным файлам cron..."

CRON_SYSTEM_DIRS=(
    /etc/crontab
    /etc/cron.d
    /etc/cron.hourly
    /etc/cron.daily
    /etc/cron.weekly
    /etc/cron.monthly
)

for path in "${CRON_SYSTEM_DIRS[@]}"; do
    if [ -d "$path" ]; then
        sudo find "$path" -type f -exec chmod go-wx {} \; && \
        sudo find "$path" -type d -exec chmod go-wx {} \; && \
        echo "Права для $path обновлены." || \
        echo "Не удалось обновить права для $path."
    elif [ -f "$path" ]; then
        sudo chmod go-wx "$path" && \
        echo "Права для $path обновлены." || \
        echo "Не удалось обновить права для $path."
    fi
done

echo "Права доступа к системным cron-заданиям установлены."

## 2.3.4 Права на файлы sudo

echo "Установка прав доступа к исполняемым файлам, доступным через sudo..."

# Исключаем /usr/bin/sudo из списка, чтобы предотвратить его повреждение
SUDO_FILES=$(sudo find / -perm -4000 -type f 2>/dev/null | grep -v "/usr/bin/sudo")

for file in $SUDO_FILES; do
    sudo chown root "$file" && \
    sudo chmod go-w "$file" && \
    echo "Права на $file установлены." || \
    echo "Не удалось установить права на $file."
done

echo "Права на SUID/SGID файлы установлены."

## 2.3.5 Права на стартовые скрипты системы

echo "Установка прав доступа к стартовым скриптам системы..."

STARTUP_DIRS=(
    /etc/rc*.d
    /etc/systemd/system
)

for dir in "${STARTUP_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        sudo find "$dir" -type f -exec chmod o-w {} \; && \
        echo "Права для $dir обновлены." || \
        echo "Не удалось обновить права для $dir."
    fi
done

echo "Права на стартовые скрипты установлены."

## 2.3.6 Права на системные cron-конфигурации

echo "Установка прав доступа к системным файлам cron-заданий..."

SYSTEM_CRON_FILES=(
    /etc/crontab
    /etc/cron.d
    /etc/cron.hourly
    /etc/cron.daily
    /etc/cron.weekly
    /etc/cron.monthly
)

for path in "${SYSTEM_CRON_FILES[@]}"; do
    if [ -d "$path" ]; then
        sudo find "$path" -type f -exec chmod go-wx {} \; && \
        sudo find "$path" -type d -exec chmod go-wx {} \; && \
        echo "Права для $path обновлены." || \
        echo "Не удалось обновить права для $path."
    elif [ -f "$path" ]; then
        sudo chmod go-wx "$path" && \
        echo "Права для $path обновлены." || \
        echo "Не удалось обновить права для $path."
    fi
done

echo "Права на системные cron-задания установлены."

## 2.3.7 Права на пользовательские cron-задания

echo "Установка прав доступа к пользовательским cron-заданиям..."

USER_CRON_FILES="/var/spool/cron/*"

if [ -d "/var/spool/cron" ]; then
    sudo chmod go-w /var/spool/cron/* && \
    echo "Права на пользовательские cron-задания установлены." || \
    echo "Не удалось установить права на некоторые пользовательские cron-задания."
else
    echo "/var/spool/cron не найден, пропускаем."
fi

## 2.3.8 Права на исполняемые файлы и библиотеки

echo "Установка прав доступа к исполняемым файлам и библиотекам..."

STANDARD_PATHS=(
    /bin
    /usr/bin
    /sbin
    /usr/sbin
    /lib
    /lib64
    /usr/lib
    /usr/lib64
)

for path in "${STANDARD_PATHS[@]}"; do
    if [ -d "$path" ]; then
        sudo find "$path" -type f -exec chmod go-w {} \; && \
        echo "Права для файлов в $path обновлены." || \
        echo "Не удалось обновить права для файлов в $path."
    fi
done

# Путь к модулям ядра
KERNEL_VERSION=$(uname -r)
MODULES_PATH="/lib/modules/$KERNEL_VERSION"

if [ -d "$MODULES_PATH" ]; then
    sudo find "$MODULES_PATH" -type f -exec chmod go-w {} \; && \
    echo "Права для файлов в $MODULES_PATH обновлены." || \
    echo "Не удалось обновить права для файлов в $MODULES_PATH."
fi

echo "Права на исполняемые файлы и библиотеки установлены."

## 2.3.9 Права на SUID/SGID-приложения

echo "Аудит SUID/SGID-приложений и установка прав доступа..."

# Исключаем /usr/bin/sudo из списка, чтобы предотвратить его повреждение
SUID_SGID_FILES=$(sudo find / -perm /6000 -type f 2>/dev/null | grep -v "/usr/bin/sudo")

# Опционально: определить "белый список" допустимых SUID/SGID файлов
# WHITE_LIST=("..." "..." )

for file in $SUID_SGID_FILES; do
    # Проверка на наличие в белом списке (если применимо)
    # if [[ " ${WHITE_LIST[@]} " =~ " $file " ]]; then
    #     continue
    # fi
    sudo chmod go-w "$file" && \
    echo "Права на $file обновлены." || \
    echo "Не удалось обновить права на $file."
done

echo "Права на SUID/SGID-приложения установлены."

## 2.3.10 Права на домашние файлы пользователей

echo "Установка прав доступа к домашним файлам пользователей..."

HOME_FILES=$(find /home/* -type f \( -name ".bash_history" -o -name ".bashrc" -o -name ".profile" -o -name ".rhosts" -o -name ".history" -o -name ".sh_history" \) 2>/dev/null)

for file in $HOME_FILES; do
    sudo chmod go-rwx "$file" && \
    echo "Права на $file установлены." || \
    echo "Не удалось установить права на $file."
done

echo "Права на домашние файлы пользователей установлены."

## 2.3.11 Права на домашние директории пользователей

echo "Установка прав доступа к домашним директориям пользователей..."

for dir in /home/*; do
    if [ -d "$dir" ]; then
        sudo chmod 700 "$dir" && \
        echo "Права на директорию $dir установлены." || \
        echo "Не удалось установить права на директорию $dir."
    fi
done

echo "Права на домашние директории установлены."

##############################################
# 2.4 Настройка механизмов защиты ядра Linux #
##############################################

echo "Настройка раздела 2.4: Защита ядра Linux"

# Функция для добавления/замены параметров в /etc/sysctl.conf
set_sysctl() {
    local key="$1"
    local value="$2"
    local file="/etc/sysctl.conf"

    if grep -q "^$key" "$file"; then
        sudo sed -i "s/^$key.*/$key = $value/" "$file" && \
        echo "Параметр $key обновлён в $file." || \
        echo "Не удалось обновить параметр $key в $file."
    else
        echo "$key = $value" | sudo tee -a "$file" && \
        echo "Параметр $key добавлен в $file." || \
        echo "Не удалось добавить параметр $key в $file."
    fi

    sudo sysctl -w "$key=$value" && \
    echo "Параметр $key установлен в runtime." || \
    echo "Не удалось установить параметр $key в runtime."
}

## 2.4.1 Ограничить доступ к журналу ядра

echo "Ограничение доступа к журналу ядра..."
set_sysctl kernel.dmesg_restrict 1

## 2.4.2 Заменить ядерные адреса на 0

echo "Замена ядерных адресов на 0..."
set_sysctl kernel.kptr_restrict 2

## 2.4.3 Инициализация динамической памяти нулями

echo "Настройка инициализации динамической памяти нулями при выделении..."

GRUB_FILE="/etc/default/grub"
backup_file "$GRUB_FILE"

# Добавляем или обновляем параметр init_on_alloc=1
if grep -q 'init_on_alloc=1' "$GRUB_FILE"; then
    echo "Параметр init_on_alloc=1 уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&init_on_alloc=1 /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр init_on_alloc=1 добавлен в GRUB." || \
    echo "Не удалось добавить параметр init_on_alloc=1 в GRUB."
fi

## 2.4.4 Запретить слияние кэшей аллокатора

echo "Запрет слияния кэшей аллокатора..."
if grep -q 'slab_nomerge' "$GRUB_FILE"; then
    echo "Параметр slab_nomerge уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&slab_nomerge /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр slab_nomerge добавлен в GRUB." || \
    echo "Не удалось добавить параметр slab_nomerge в GRUB."
fi

## 2.4.5 Настройка IOMMU

echo "Настройка IOMMU..."

GRUB_CMDLINE_ADD="iommu=force iommu.strict=1 iommu.passthrough=0"

if grep -q 'iommu=force' "$GRUB_FILE"; then
    echo "Параметры IOMMU уже установлены в GRUB."
else
    sudo sed -i "s/GRUB_CMDLINE_LINUX=\"/&$GRUB_CMDLINE_ADD /" "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметры IOMMU добавлены в GRUB." || \
    echo "Не удалось добавить параметры IOMMU в GRUB."
fi

## 2.4.6 Рандомизация расположения ядерного стека

echo "Рандомизация расположения ядерного стека..."
if grep -q 'randomize_kstack_offset=1' "$GRUB_FILE"; then
    echo "Параметр randomize_kstack_offset=1 уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&randomize_kstack_offset=1 /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр randomize_kstack_offset=1 добавлен в GRUB." || \
    echo "Не удалось добавить параметр randomize_kstack_offset=1 в GRUB."
fi

## 2.4.7 Защита от аппаратных уязвимостей CPU

echo "Включение защиты от аппаратных уязвимостей CPU..."
if grep -q 'mitigations=auto,nosmt' "$GRUB_FILE"; then
    echo "Параметр mitigations=auto,nosmt уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&mitigations=auto,nosmt /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр mitigations=auto,nosmt добавлен в GRUB." || \
    echo "Не удалось добавить параметр mitigations=auto,nosmt в GRUB."
fi

## 2.4.8 Защита подсистемы eBPF JIT

echo "Включение защиты подсистемы eBPF JIT..."
set_sysctl net.core.bpf_jit_harden 2

##############################################
# 2.5 Уменьшение периметра атаки ядра Linux  #
##############################################

echo "Настройка раздела 2.5: Уменьшение периметра атаки ядра Linux"

## 2.5.1 Отключить vsyscall

echo "Отключение устаревшего интерфейса vsyscall..."
GRUB_FILE="/etc/default/grub"
backup_file "$GRUB_FILE"

if grep -q 'vsyscall=none' "$GRUB_FILE"; then
    echo "Параметр vsyscall=none уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&vsyscall=none /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр vsyscall=none добавлен в GRUB." || \
    echo "Не удалось добавить параметр vsyscall=none в GRUB."
fi

## 2.5.2 Ограничить доступ к событиям производительности

echo "Ограничение доступа к событиям производительности..."
set_sysctl kernel.perf_event_paranoid 3

## 2.5.3 Отключить монтирование debugfs

echo "Отключение монтирования debugfs..."
GRUB_FILE="/etc/default/grub"
backup_file "$GRUB_FILE"

if grep -q 'debugfs=no-mount' "$GRUB_FILE"; then
    echo "Параметр debugfs=no-mount уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&debugfs=no-mount /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр debugfs=no-mount добавлен в GRUB." || \
    echo "Не удалось добавить параметр debugfs=no-mount в GRUB."
fi

# Отключение debugfs немонтированным
if mount | grep -q '/sys/kernel/debug'; then
    sudo umount /sys/kernel/debug && \
    echo "Файловая система debugfs отмонтирована." || \
    echo "Не удалось отмонтировать файловую систему debugfs."
else
    echo "Файловая система debugfs не смонтирована."
fi

## 2.5.4 Отключить системный вызов kexec_load

echo "Отключение системного вызова kexec_load..."
set_sysctl kernel.kexec_load_disabled 1

## 2.5.5 Ограничить использование user namespaces

echo "Ограничение использования user namespaces..."
set_sysctl user.max_user_namespaces 0

## 2.5.6 Запретить системный вызов bpf

echo "Запрет системного вызова bpf для непривилегированных пользователей..."
set_sysctl kernel.unprivileged_bpf_disabled 1

## 2.5.7 Запретить системный вызов userfaultfd

echo "Запрет системного вызова userfaultfd для непривилегированных пользователей..."
set_sysctl vm.unprivileged_userfaultfd 0

## 2.5.8 Запрет автоматической загрузки модулей tty

echo "Запрет автоматической загрузки модулей tty..."
set_sysctl dev.tty.ldisc_autoload 0

## 2.5.9 Отключить технологию TSX

echo "Отключение технологии TSX..."
GRUB_FILE="/etc/default/grub"
backup_file "$GRUB_FILE"

if grep -q 'tsx=off' "$GRUB_FILE"; then
    echo "Параметр tsx=off уже установлен в GRUB."
else
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/&tsx=off /' "$GRUB_FILE" && \
    sudo update-grub && \
    echo "Параметр tsx=off добавлен в GRUB." || \
    echo "Не удалось добавить параметр tsx=off в GRUB."
fi

## 2.5.10 Минимальный виртуальный адрес для mmap

echo "Установка минимального виртуального адреса для mmap..."
set_sysctl vm.mmap_min_addr 4096

## 2.5.11 Рандомизация адресного пространства

echo "Рандомизация адресного пространства..."
set_sysctl kernel.randomize_va_space 2

##############################################
# 2.6 Защита пользовательского пространства ядром #
##############################################

echo "Настройка раздела 2.6: Защита пользовательского пространства ядром Linux"

## 2.6.1 Запрет ptrace

echo "Запрет подключения к другим процессам через ptrace..."
set_sysctl kernel.yama.ptrace_scope 3

## 2.6.2 Ограничить небезопасные символические ссылки

echo "Ограничение небезопасных символических ссылок..."
set_sysctl fs.protected_symlinks 1

## 2.6.3 Ограничить небезопасные жесткие ссылки

echo "Ограничение небезопасных жестких ссылок..."
set_sysctl fs.protected_hardlinks 1

## 2.6.4 Защита от непреднамеренной записи в FIFO

echo "Включение защиты от непреднамеренной записи в FIFO-объекты..."
set_sysctl fs.protected_fifos 2

## 2.6.5 Защита от непреднамеренной записи в файлы

echo "Включение защиты от непреднамеренной записи в файлы..."
set_sysctl fs.protected_regular 2

## 2.6.6 Запрет создания core dumps для SUID-приложений

echo "Запрет создания core dumps для SUID-приложений..."
set_sysctl fs.suid_dumpable 0

######################################
# Завершение и перезагрузка системы #
######################################

echo "Применение всех настроек..."
sudo sysctl -p && \
echo "Настройки sysctl применены." || \
echo "Не удалось применить некоторые настройки sysctl."

echo "Все настройки безопасности применены успешно."

# Предупреждение о перезагрузке
read -p "Хотите перезагрузить систему сейчас? [y/N]: " REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    echo "Перезагрузка системы..."
    sudo reboot
else
    echo "Перезагрузка отменена. Пожалуйста, перезагрузите систему вручную, чтобы применить изменения GRUB."
fi
