# Конфигурация виртуальной машины devops-vm

Целевой узел для практических работ № 5, 6, 7, 11 и 14.
Хостовая система: macOS (Apple Silicon), VirtualBox 7.2.
Гостевая система: Ubuntu Server 26.04.1 LTS (aarch64), OpenSSH 10.2p1.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Наименование ВМ | devops-vm |
| Тип и версия гостевой системы | Linux / Ubuntu (ARM 64-bit) |
| Объём оперативной памяти | 4096 МБ |
| Количество ядер процессора | 2 |
| Объём диска | 25 ГБ, динамически расширяемый (VDI) |
| Имя узла (FQDN) | devops-vm (devops-vm.devops.local) |

## 2. Сетевые интерфейсы

| Адаптер VirtualBox | Тип | Интерфейс в гостевой системе | Адрес | Назначение |
|---|---|---|---|---|
| Адаптер 1 | NAT | enp0s8 | 10.0.2.15/24 (DHCP) | доступ в Интернет, к репозиториям пакетов |
| Адаптер 2 | Host-only, сеть `HostNet` (192.168.56.0/24) | enp0s9 | 192.168.56.102/24 (DHCP) | прямой доступ с хостовой системы (веб-сервер в ПР № 6) |

Сеть Host-only на macOS создаётся командой (адрес 192.168.56.101 занимает интерфейс хоста `bridge100`):

```bash
VBoxManage hostonlynet add --name HostNet --netmask 255.255.255.0 \
  --lower-ip 192.168.56.101 --upper-ip 192.168.56.199 --enable
VBoxManage modifyvm devops-vm --nic2 hostonlynet --host-only-net2 HostNet
```

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | 2222 |

До усиления защиты SSH порт гостевой системы был равен 22. После перевода sshd на порт 2222 правило изменено:

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | UID | Группы | Способ аутентификации по SSH |
|---|---|---|---|
| student | 1000 | student, adm, cdrom, sudo, dip, plugdev, lxd, users | вход по SSH запрещён (`AllowUsers devops`), только локальная консоль |
| devops | 1001 | devops, sudo, users | только по ключу ed25519 (`~/.ssh/devops_vm` на хосте) |
| root | 0 | root | вход по SSH запрещён (`PermitRootLogin no`) |

Создание учётной записи и размещение ключа:

```bash
# на сервере (под student)
sudo adduser devops
sudo usermod -aG sudo devops

# на хосте
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

Права на ключевой материал на сервере: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600.

Файл `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    HostName devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется, эталонная копия — `/etc/ssh/sshd_config.backup`.
Изменения вынесены в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Дополнительно:

1. В файле `/etc/ssh/sshd_config.d/50-cloud-init.conf` закомментирована строка `PasswordAuthentication yes`
   (файл читается раньше `99-hardening.conf`, первое значение директивы побеждает):
   ```bash
   sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
   ```
2. Отключена активация по сокету, иначе sshd продолжает слушать порт 22 из `ssh.socket`:
   ```bash
   sudo systemctl disable --now ssh.socket
   sudo systemctl enable --now ssh.service
   sudo systemctl restart ssh
   ```
3. Проверка: `sudo sshd -t`, `sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"`,
   `sudo ss -tlnp | grep sshd` (ожидается `0.0.0.0:2222`).

## 6. Правила межсетевого экрана

Политики по умолчанию: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`. Журналирование: `medium`.

| № | Порт | Действие | Комментарий |
|---|---|---|---|
| 1 | 80/tcp | ALLOW IN | HTTP (ПР № 6) |
| 2 | 443/tcp | ALLOW IN | HTTPS (ПР № 6) |
| 3 | 2222/tcp | LIMIT IN | SSH rate-limited |

Правила продублированы для IPv6. Команды (разрешающее правило для SSH создаётся до `ufw enable`):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
```

## 7. Разрешение имён

На хостовой системе в `/etc/hosts`: `192.168.56.102   devops.local`.

На сервере:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
echo "preserve_hostname: true" | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
hostname -f   # devops-vm.devops.local
```

## 8. Веб-сервер

Пакет: `nginx` (1.28.3, репозиторий Ubuntu), служба `nginx.service` включена в автозагрузку.
Главный процесс работает от `root`, рабочие — от `www-data`.

```bash
sudo apt update && sudo apt install -y nginx
```

| Объект | Путь | Владелец | Права |
|---|---|---|---|
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site` (ссылка в `sites-enabled/`) | root:root | 644 |
| Стандартный ресурс | ссылка `/etc/nginx/sites-enabled/default` удалена, файл в `sites-available/` сохранён | — | — |
| Каталог ресурса | `/var/www/devops-site` | devops:devops | 755 (каталоги), 644 (файлы) |
| Сертификат | `/etc/ssl/certs/devops.crt` | root:root | 644 |
| Закрытый ключ | `/etc/ssl/private/devops.key` | root:root | 600 |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` | root:root | 644 |

Каталог ресурса:

```bash
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

Сертификат (самоподписанный, RSA 2048, срок действия 365 дней — до 2027-10-27):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

Конфигурация `/etc/nginx/sites-available/devops-site`:

```nginx
# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

# Блок 2: ресурс по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Активация (заголовок HSTS не добавляется):

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Доверие к сертификату на хосте: `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`, далее `curl --cacert ~/devops.crt`.
Содержимое доставляется из каталога `site/` репозитория сценарием `scripts/deploy.sh`
(rsync `--delete --chmod=D755,F644`; на macOS нужен GNU rsync: `brew install rsync`, системный openrsync не принимает `--chmod=D755,F644`).

## 9. Снимки состояния

| Наименование | Момент создания (UTC) | Состояние |
|---|---|---|
| 01-clean-install | 2026-10-20 08:39 | система установлена и обновлена, адаптеры NAT + Host-only |
| 02-keys-configured | 2026-10-20 08:40 | создана учётная запись devops, настроен вход по ключу |
| 03-ssh-hardened | 2026-10-20 08:42 | применён `99-hardening.conf`, sshd на порту 2222 |
| 04-nginx-https | 2026-10-27 08:13 | установлен Nginx, ресурс devops.local обслуживается по HTTPS |

## 10. Контроль конфигурации

```bash
scp scripts/audit.sh devops:~/ && ssh -t devops './audit.sh; echo "exit code: $?"'
```

Скрипт возвращает 0, если все проверки пройдены, и 1 в противном случае.
