#!/usr/bin/env bash
# =============================================================================
#  IDDigital Hosting v1.8.0 — instalador (MiniPainel)
#  Painel de alojamento mínimo: nginx + PHP-FPM (várias versões) + MariaDB + phpMyAdmin,
#  gestor de ficheiros e estatísticas de recursos
#  Os sites são servidos por porta: http://IP:PORTA ou http://localhost:PORTA
#  Suporta: Debian 12/13, Ubuntu 22.04/24.04, AlmaLinux/Rocky 9/10
#
#  Uso:
#    bash minipainel-install-v1.8.0.sh [--php "7.4 8.1 8.2 8.3 8.4"] [--panel-port 2443] [--force]
#
#  Pode ser executado novamente (atualiza a partir da v1.0.0 ou acrescenta
#  versões de PHP com --php); sites, bases de dados, extensões e password do
#  painel são preservados. Sem --php, numa atualização mantêm-se as versões
#  de PHP já instaladas.
# =============================================================================
set -Eeuo pipefail

MP_VERSION="1.8.0"
PHP_VERSIONS="7.4 8.1 8.2 8.3 8.4"
PANEL_PORT=2443
PANEL_PORT_ARG=0
PHP_ARG=0
FORCE=0

trap 'echo -e "\n\033[31m[ERRO]\033[0m Falha na linha $LINENO: $BASH_COMMAND" >&2' ERR

say(){  echo -e "\033[36m==>\033[0m $*"; }
ok(){   echo -e "\033[32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[33m[AVISO]\033[0m $*" >&2; }
die(){  echo -e "\033[31m[ERRO]\033[0m $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --php)        PHP_VERSIONS="${2:-}"; PHP_ARG=1; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; PANEL_PORT_ARG=1; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *)            die "Opção desconhecida: $1" ;;
  esac
done

# ----------------------------------------------------------------------------
# Verificações iniciais
# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Executa como root."
[ -r /etc/os-release ] || die "Não foi possível identificar a distribuição (/etc/os-release)."
[[ "$PANEL_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PANEL_PORT" -ge 1 ] && [ "$PANEL_PORT" -le 65535 ] || die "Porta do painel inválida: $PANEL_PORT"
for v in $PHP_VERSIONS; do [[ "$v" =~ ^[5-8]\.[0-9]{1,2}$ ]] || die "Versão PHP inválida: $v"; done
[ -n "$PHP_VERSIONS" ] || die "Indica pelo menos uma versão de PHP."

# shellcheck source=/dev/null
. /etc/os-release
OS_ID="${ID:-}"
OS_VER="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"
EL_MAJOR=""

case "$OS_ID" in
  debian)
    OS_FAMILY=debian
    case "${OS_VER%%.*}" in 12|13) ;; *) warn "Debian $OS_VER não foi testado." ;; esac ;;
  ubuntu)
    OS_FAMILY=debian
    case "$OS_VER" in 22.04|24.04) ;; *) warn "Ubuntu $OS_VER não foi testado." ;; esac ;;
  almalinux|rocky|rhel|centos|ol)
    OS_FAMILY=rhel
    EL_MAJOR="${OS_VER%%.*}"
    [[ "$EL_MAJOR" =~ ^[0-9]+$ ]] && [ "$EL_MAJOR" -ge 9 ] || die "Requer versão 9 ou superior (detetado: $OS_VER)." ;;
  *)
    die "Distribuição não suportada: $OS_ID" ;;
esac
[ "$OS_FAMILY" = debian ] && [ -z "$OS_CODENAME" ] && die "Não foi possível obter o codename da distribuição."

if [ "$OS_FAMILY" = debian ]; then WEB_USER=www-data; WEB_GROUP=www-data; else WEB_USER=nginx; WEB_GROUP=nginx; fi
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"

UPGRADE=0
[ -f /etc/minipainel/minipainel.conf ] && UPGRADE=1
conf_get(){ grep -m1 "^$1=" /etc/minipainel/minipainel.conf 2>/dev/null | cut -d= -f2- || true; }

if [ "$UPGRADE" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  for p in /usr/local/mgr5 /usr/local/hestia /usr/local/vesta /usr/local/cpanel /usr/local/psa /usr/local/directadmin /usr/local/CyberCP /home/clp; do
    [ -e "$p" ] && die "Foi detetado outro painel ($p). Usa um servidor limpo ou --force."
  done
  extra=()
  shopt -s nullglob
  for f in /etc/nginx/conf.d/*.conf; do extra+=("$f"); done
  for f in /etc/nginx/sites-enabled/*; do [ "$(basename "$f")" = default ] || extra+=("$f"); done
  shopt -u nullglob
  if [ ${#extra[@]} -gt 0 ]; then
    die "O nginx já tem configurações (${extra[*]}). O IDDigital Hosting substitui o nginx.conf; usa --force para continuar."
  fi
  if [ -n "$(ss -Hltn "sport = :$PANEL_PORT" 2>/dev/null)" ]; then
    die "A porta $PANEL_PORT já está em uso. Escolhe outra com --panel-port."
  fi
fi

# ----------------------------------------------------------------------------
# Funções auxiliares PHP (iguais às do CLI)
# ----------------------------------------------------------------------------
php_vv(){ echo "${1/./}"; }
php_pool_dir(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/pool.d"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.d"; fi; }
php_service(){  if [ "$OS_FAMILY" = debian ]; then echo "php$1-fpm"; else echo "php$(php_vv "$1")-php-fpm"; fi; }
php_fpm_bin(){  if [ "$OS_FAMILY" = debian ]; then echo "/usr/sbin/php-fpm$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/sbin/php-fpm"; fi; }
php_fpm_conf(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/php-fpm.conf"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.conf"; fi; }
php_cli(){      if [ "$OS_FAMILY" = debian ]; then echo "/usr/bin/php$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/bin/php"; fi; }
php_run_dir(){  if [ "$OS_FAMILY" = debian ]; then echo "/run/php"; else echo "/var/opt/remi/php$(php_vv "$1")/run/php-fpm"; fi; }
php_www_sock(){ if [ "$OS_FAMILY" = debian ]; then echo "/run/php/php$1-fpm.sock"; else echo "$(php_run_dir "$1")/www.sock"; fi; }
php_installed(){
  local d v
  if [ "$OS_FAMILY" = debian ]; then
    for d in /etc/php/*/fpm/pool.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/php/}"; v="${v%%/*}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  else
    for d in /etc/opt/remi/php*/php-fpm.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/opt/remi/php}"; v="${v%%/*}"; v="${v:0:1}.${v:1}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  fi | sort -V
}

export DEBIAN_FRONTEND=noninteractive
pkg_install(){
  if [ "$OS_FAMILY" = debian ]; then apt-get install -y -q --no-install-recommends "$@"
  else dnf install -y -q "$@"; fi
}
pkg_install_soft(){
  # Instala a lista; se falhar em bloco tenta pacote a pacote (ignora os inexistentes)
  if pkg_install "$@" >/dev/null 2>&1; then return 0; fi
  local p
  for p in "$@"; do
    if ! pkg_install "$p" >/dev/null 2>&1; then warn "Pacote indisponível/ignorado: $p"; fi
  done
  return 0
}
selinux_on(){ command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; }

# ----------------------------------------------------------------------------
# 1. Pacotes base e repositórios PHP
# ----------------------------------------------------------------------------
say "A instalar pacotes base ($OS_ID $OS_VER)..."
if [ "$OS_FAMILY" = debian ]; then
  apt-get update -q
  pkg_install ca-certificates curl gnupg jq openssl iproute2 procps logrotate nftables cron pigz rclone nginx mariadb-server mariadb-client
  if [ "$OS_ID" = ubuntu ]; then
    pkg_install software-properties-common
    add-apt-repository -y ppa:ondrej/php
  else
    curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i /tmp/debsuryorg-archive-keyring.deb >/dev/null
    rm -f /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
      > /etc/apt/sources.list.d/php-sury.list
  fi
  apt-get update -q
else
  dnf install -y -q epel-release || dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm"
  dnf install -y -q dnf-plugins-core || true
  dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
  rpm -q remi-release >/dev/null 2>&1 || dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${EL_MAJOR}.rpm"
  pkg_install nginx mariadb-server mariadb jq openssl curl iproute procps-ng logrotate nftables cronie pigz policycoreutils-python-utils
  pkg_install_soft rclone
fi
ok "Pacotes base instalados."

if [ "$UPGRADE" -eq 1 ] && [ "$PHP_ARG" -eq 0 ]; then
  CUR_PHP="$(php_installed | tr '\n' ' ')"
  [ -n "${CUR_PHP// /}" ] && PHP_VERSIONS="$CUR_PHP"
fi
say "A instalar versões de PHP: $PHP_VERSIONS"
for v in $PHP_VERSIONS; do
  pkgs=()
  if [ "$OS_FAMILY" = debian ]; then
    for e in fpm cli common mysql curl gd mbstring xml zip intl bcmath opcache soap sqlite3 readline; do pkgs+=("php$v-$e"); done
  else
    vv="$(php_vv "$v")"
    for e in php-fpm php-cli php-common php-mysqlnd php-gd php-mbstring php-xml php-pecl-zip php-intl php-bcmath php-opcache php-soap php-pdo php-process; do pkgs+=("php$vv-$e"); done
  fi
  pkg_install_soft "${pkgs[@]}"
  if [ -x "$(php_fpm_bin "$v")" ]; then ok "PHP $v instalado."; else warn "PHP $v não ficou instalado (indisponível nesta distribuição?)."; fi
done

ALL_PHP="$(php_installed | tr '\n' ' ')"
[ -n "${ALL_PHP// /}" ] || die "Nenhuma versão de PHP ficou instalada."
HIGHEST_PHP="$(php_installed | tail -n1)"

# ----------------------------------------------------------------------------
# 2. Configuração do MiniPainel
# ----------------------------------------------------------------------------
PANEL_USER="admin"
DEFAULT_PHP="$HIGHEST_PHP"
if [ "$UPGRADE" -eq 1 ]; then
  old="$(conf_get PANEL_USER)"; [ -n "$old" ] && PANEL_USER="$old"
  old="$(conf_get DEFAULT_PHP)"
  if [ -n "$old" ] && [ -x "$(php_fpm_bin "$old")" ]; then DEFAULT_PHP="$old"; fi
  if [ "$PANEL_PORT_ARG" -eq 0 ]; then old="$(conf_get PANEL_PORT)"; [ -n "$old" ] && PANEL_PORT="$old"; fi
fi
PANEL_PHP="$HIGHEST_PHP"

IPV6=0
if [ -f /proc/net/if_inet6 ] && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then IPV6=1; fi

say "A criar utilizador e pastas do painel..."
id minipainel >/dev/null 2>&1 || useradd -r -U -M -d /var/lib/minipainel -s "$NOLOGIN" -c "MiniPainel" minipainel
install -d -m 755 /srv/www /etc/minipainel /opt/minipainel /opt/minipainel/public
install -d -m 700 /etc/minipainel/sites /etc/minipainel/ssl
install -d -m 755 /etc/nginx/minipainel /etc/nginx/minipainel/sites
install -d -o root -g minipainel -m 750 /var/lib/minipainel
install -d -o minipainel -g minipainel -m 700 /var/lib/minipainel/queue /var/lib/minipainel/tmp \
  /var/lib/minipainel/sessions /var/lib/minipainel/ratelimit /var/lib/minipainel/logs
install -d -o root -g minipainel -m 2770 /var/lib/minipainel/results
id minipainel-pma >/dev/null 2>&1 || useradd -r -U -M -d /var/lib/minipainel-pma -s "$NOLOGIN" -c "MiniPainel phpMyAdmin" minipainel-pma
install -d -o root -g minipainel-pma -m 750 /var/lib/minipainel-pma
install -d -o minipainel-pma -g minipainel-pma -m 700 /var/lib/minipainel-pma/tmp /var/lib/minipainel-pma/sessions /var/lib/minipainel-pma/logs

cat > /etc/minipainel/minipainel.conf <<EOF
# MiniPainel — gerado pelo instalador v$MP_VERSION (não editar sem necessidade)
MP_INSTALLED_VERSION=$MP_VERSION
OS_FAMILY=$OS_FAMILY
WEB_USER=$WEB_USER
WEB_GROUP=$WEB_GROUP
NOLOGIN=$NOLOGIN
PANEL_PORT=$PANEL_PORT
PANEL_USER=$PANEL_USER
PANEL_SYSUSER=minipainel
PANEL_PHP=$PANEL_PHP
DEFAULT_PHP=$DEFAULT_PHP
SITE_PORT_START=8001
IPV6=$IPV6
EOF
chmod 644 /etc/minipainel/minipainel.conf

# ----------------------------------------------------------------------------
# 3. MariaDB
# ----------------------------------------------------------------------------
say "A configurar MariaDB..."
if [ "$OS_FAMILY" = debian ]; then MYCNF_DIR=/etc/mysql/mariadb.conf.d; else MYCNF_DIR=/etc/my.cnf.d; fi
mkdir -p "$MYCNF_DIR"
if [ ! -f "$MYCNF_DIR/99-minipainel.cnf" ]; then
  cat > "$MYCNF_DIR/99-minipainel.cnf" <<'EOF'
# MiniPainel — MariaDB apenas acessível localmente
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
fi
systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb
if [ "$UPGRADE" -eq 0 ]; then
  mysql -uroot -e "DROP USER IF EXISTS ''@'localhost'; DROP USER IF EXISTS ''@'$(hostname)'; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" \
    || warn "Não foi possível aplicar a limpeza inicial do MariaDB."
fi
ok "MariaDB ativo (apenas 127.0.0.1)."

# ----------------------------------------------------------------------------
# 4. nginx
# ----------------------------------------------------------------------------
say "A configurar nginx..."
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.minipainel-orig ]; then
  cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.minipainel-orig
fi
if [ "$OS_FAMILY" = debian ]; then NGX_MODULES="include /etc/nginx/modules-enabled/*.conf;"; else NGX_MODULES="include /usr/share/nginx/modules/*.conf;"; fi

cat > /etc/nginx/nginx.conf <<EOF
# Gerado pelo MiniPainel v$MP_VERSION (original em nginx.conf.minipainel-orig)
user $WEB_USER;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
$NGX_MODULES

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    tcp_nopush    on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    server_tokens off;
    client_max_body_size 128M;
    access_log /var/log/nginx/access.log;

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css text/xml application/javascript application/json application/xml image/svg+xml;

    include /etc/nginx/minipainel/panel.conf;
    include /etc/nginx/minipainel/sites/*.conf;
}
EOF

PANEL_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel.sock"
PMA_SOCK="$(php_run_dir "$PANEL_PHP")/minipainel-pma.sock"
PANEL_RUN="$(php_run_dir "$PANEL_PHP")"
L6=""
[ "$IPV6" = 1 ] && L6="    listen [::]:$PANEL_PORT ssl;"
cat > /etc/nginx/minipainel/panel.conf <<EOF
# MiniPainel — painel de administração
server {
    listen $PANEL_PORT ssl;
$L6
    server_name _;

    ssl_certificate     /etc/minipainel/ssl/panel.crt;
    ssl_certificate_key /etc/minipainel/ssl/panel.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:MPSSL:1m;
    error_page 497 =301 https://\$host:\$server_port\$request_uri;

    root /opt/minipainel/public;
    access_log /var/log/nginx/minipainel.access.log;
    error_log  /var/log/nginx/minipainel.error.log;

    location = /favicon.ico { access_log off; log_not_found off; return 204; }

    # Verificação de sessão do painel (usada para proteger o phpMyAdmin)
    location = /_mp_auth {
        internal;
        client_max_body_size 0;
        fastcgi_pass_request_body off;
        fastcgi_param SCRIPT_FILENAME /opt/minipainel/public/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_param REQUEST_METHOD GET;
        fastcgi_param REQUEST_URI /_mp_auth;
        fastcgi_param QUERY_STRING "";
        fastcgi_param CONTENT_LENGTH "";
        fastcgi_param CONTENT_TYPE "";
        fastcgi_param REMOTE_ADDR \$remote_addr;
        fastcgi_param SERVER_NAME \$server_name;
        fastcgi_param HTTPS on;
        fastcgi_param MP_AUTH_CHECK 1;
        fastcgi_pass unix:$PANEL_SOCK;
    }

    # phpMyAdmin — só acessível com sessão iniciada no painel
    location = /phpmyadmin { return 301 /phpmyadmin/; }
    location ^~ /phpmyadmin/ {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        alias /opt/minipainel/phpmyadmin/;
        index index.php;
        client_max_body_size 512M;
        location ~ ^/phpmyadmin/(setup|libraries|templates|vendor|sql|locale|src)(/|\$) { deny all; }
        location ~ /\. { deny all; }
        location ~ ^/phpmyadmin/.+\.php\$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            fastcgi_param HTTPS on;
            fastcgi_pass unix:$PMA_SOCK;
            fastcgi_read_timeout 900s;
            fastcgi_buffer_size 32k;
            fastcgi_buffers 16 16k;
        }
    }
    location @mp_login { return 302 /?p=resumo; }

    # Gestor de ficheiros — pool PHP-FPM de cada site (corre como o utilizador do site)
    location ~ "^/ficheiros/(?<fmsite>[a-z][a-z0-9-]{0,23})/\$" {
        auth_request /_mp_auth;
        error_page 401 = @mp_login;
        client_max_body_size 72M;
        fastcgi_buffering off;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /opt/minipainel/files/index.php;
        fastcgi_param SCRIPT_NAME /ficheiros/\$fmsite/;
        fastcgi_param MP_FM_SITE \$fmsite;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:$PANEL_RUN/mp-fm-\$fmsite.sock;
        fastcgi_read_timeout 900s;
        fastcgi_send_timeout 900s;
    }

    location / {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
        fastcgi_pass unix:$PANEL_SOCK;
        fastcgi_read_timeout 900s;
    }
}
EOF

if [ ! -s /etc/minipainel/ssl/panel.crt ] || [ ! -s /etc/minipainel/ssl/panel.key ]; then
  say "A gerar certificado autoassinado para o painel..."
  SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SAN="DNS:localhost,IP:127.0.0.1"
  [ -n "$SRV_IP" ] && SAN="$SAN,IP:$SRV_IP"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/minipainel/ssl/panel.key -out /etc/minipainel/ssl/panel.crt \
    -subj "/CN=MiniPainel" -addext "subjectAltName=$SAN" >/dev/null 2>&1
  chmod 600 /etc/minipainel/ssl/panel.key
  chmod 644 /etc/minipainel/ssl/panel.crt
fi

# ----------------------------------------------------------------------------
# 5. PHP-FPM: pool mínimo por versão + pool do painel
# ----------------------------------------------------------------------------
say "A configurar PHP-FPM..."
for v in $ALL_PHP; do
  pd="$(php_pool_dir "$v")"
  if [ -f "$pd/www.conf" ] && [ ! -f "$pd/www.conf.minipainel-orig" ]; then cp -a "$pd/www.conf" "$pd/www.conf.minipainel-orig"; fi
  cat > "$pd/www.conf" <<EOF
; MiniPainel — pool mínimo (necessário para o serviço arrancar; não serve sites)
[www]
user = $WEB_USER
group = $WEB_GROUP
listen = $(php_www_sock "$v")
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
EOF
  rm -f "$pd/minipainel.conf" "$pd/minipainel-pma.conf"
done

cat > "$(php_pool_dir "$PANEL_PHP")/minipainel.conf" <<EOF
; MiniPainel — pool do painel de administração
[minipainel]
user = minipainel
group = minipainel
listen = $PANEL_SOCK
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = /opt/minipainel/:/var/lib/minipainel/:/var/backups/minipainel/
php_admin_value[session.save_path] = /var/lib/minipainel/sessions
php_admin_value[upload_tmp_dir] = /var/lib/minipainel/tmp
php_admin_value[sys_temp_dir] = /var/lib/minipainel/tmp
php_admin_value[error_log] = /var/lib/minipainel/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_value[max_execution_time] = 870
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_flag[session.cookie_secure] = on
php_admin_flag[session.cookie_httponly] = on
php_admin_flag[session.use_strict_mode] = on
php_admin_value[session.cookie_samesite] = Strict
EOF

cat > "$(php_pool_dir "$PANEL_PHP")/minipainel-pma.conf" <<EOF
; MiniPainel — pool do phpMyAdmin
[minipainel-pma]
user = minipainel-pma
group = minipainel-pma
listen = $PMA_SOCK
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 6
pm.process_idle_timeout = 30s
request_terminate_timeout = 900s
php_admin_value[open_basedir] = /opt/minipainel/phpmyadmin/:/var/lib/minipainel-pma/
php_admin_value[session.save_path] = /var/lib/minipainel-pma/sessions
php_admin_value[upload_tmp_dir] = /var/lib/minipainel-pma/tmp
php_admin_value[sys_temp_dir] = /var/lib/minipainel-pma/tmp
php_admin_value[error_log] = /var/lib/minipainel-pma/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 600
php_admin_value[max_input_time] = 600
php_admin_value[max_input_vars] = 10000
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[session.gc_maxlifetime] = 7200
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF

# ----------------------------------------------------------------------------
# 6. Painel web
# ----------------------------------------------------------------------------
say "A instalar o painel web..."
cat > /opt/minipainel/public/index.php <<'MPPANEL'
<?php
/**
 * IDDigital Hosting v1.8.0 — painel web (MiniPainel)
 * O painel não executa comandos: lê o estado (state.json) e coloca tarefas
 * numa fila, processadas como root pelo worker (mpanel worker).
 * As tarefas são assíncronas: o painel acompanha-as sem ficar bloqueado,
 * o que permite reiniciar serviços (incluindo o PHP do próprio painel).
 */
declare(strict_types=1);

const MP_VERSION = '1.8.0';
const MP_DATA    = '/var/lib/minipainel';
const MP_QUEUE   = MP_DATA . '/queue';
const MP_RESULTS = MP_DATA . '/results';
const MP_TMP     = MP_DATA . '/tmp';
const MP_RL      = MP_DATA . '/ratelimit';
const MP_STATE   = MP_DATA . '/state.json';
const MP_AUTH    = MP_DATA . '/auth.json';
const MP_IDLE    = 7200;
const MP_STATS   = MP_DATA . '/stats';
const MP_BK      = '/var/backups/minipainel';
const RX_SITE    = '/^[a-z][a-z0-9-]{0,23}$/';
const RX_DB      = '/^[a-z][a-z0-9_]{0,31}$/';
const RX_PASS    = '/^[A-Za-z0-9._@%+=:,!#*-]{8,64}$/';
const RX_PHP     = '/^[5-8]\.[0-9]{1,2}$/';
const RX_EXT     = '/^[a-z0-9_]{2,20}$/';
const RX_SVC     = '/^(nginx|mariadb|php-[5-8]\.[0-9]{1,2})$/';

/* chave => [rótulo, mínimo, máximo, unidade, opção do CLI, diretiva] */
const LIMITS = [
    'memory'     => ['Memória', 32, 8192, 'MB', '--memory', 'memory_limit'],
    'upload'     => ['Upload máximo', 1, 8192, 'MB', '--upload', 'upload_max_filesize e post_max_size'],
    'exec'       => ['Tempo de execução', 5, 3600, 's', '--exec', 'max_execution_time'],
    'input_time' => ['Tempo de receção de dados', 5, 3600, 's', '--input-time', 'max_input_time'],
    'input_vars' => ['Máximo de variáveis', 100, 100000, '', '--input-vars', 'max_input_vars'],
];
const LIMIT_DEFAULTS = ['memory' => 256, 'upload' => 128, 'exec' => 120, 'input_time' => 120, 'input_vars' => 5000];

/* Pedido interno do nginx (auth_request) para proteger o phpMyAdmin.
   Não bloqueia a sessão, para não atrasar os pedidos paralelos do phpMyAdmin. */
if ((string)($_SERVER['MP_AUTH_CHECK'] ?? '') === '1') {
    $authOk = false;
    session_name('MPSESS');
    if (isset($_COOKIE['MPSESS']) && is_string($_COOKIE['MPSESS']) && preg_match('/^[A-Za-z0-9,-]{20,128}$/', $_COOKIE['MPSESS'])) {
        session_start(['read_and_close' => true]);
        $seen = (int)($_SESSION['seen'] ?? 0);
        $authOk = !empty($_SESSION['user']) && time() - $seen <= MP_IDLE;
        if ($authOk && time() - $seen > 60) { session_start(); $_SESSION['seen'] = time(); session_write_close(); }
    }
    http_response_code($authOk ? 204 : 401);
    exit;
}

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

session_name('MPSESS');
session_start();

/* ---------- utilitários ---------- */
function h($v): string { return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function post(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? trim($v) : ''; }
function post_raw(string $k): string { $v = $_POST[$k] ?? ''; return is_string($v) ? $v : ''; }
function qget(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }
function jload(string $f): ?array {
    $d = @file_get_contents($f);
    if ($d === false) return null;
    $j = json_decode($d, true);
    return is_array($j) ? $j : null;
}
function csrf(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));
    return $_SESSION['csrf'];
}
function csrf_ok(): bool {
    $t = $_POST['csrf'] ?? '';
    return is_string($t) && $t !== '' && hash_equals((string)($_SESSION['csrf'] ?? ''), $t);
}
function csrf_field(): string { return '<input type="hidden" name="csrf" value="' . h(csrf()) . '">'; }
function act_fields(string $a, array $extra = []): string {
    $o = csrf_field() . '<input type="hidden" name="a" value="' . h($a) . '">';
    foreach ($extra as $k => $v) $o .= '<input type="hidden" name="' . h($k) . '" value="' . h($v) . '">';
    return $o;
}
function flash(bool $ok, string $m, bool $sticky = false): void { $_SESSION['flash'][] = [$ok, $m, $sticky || !$ok]; }
function go(string $p, array $q = []): void {
    header('Location: ?' . http_build_query(['p' => $p] + $q));
    exit;
}
function valid_net(string $s): bool {
    $ip = $s; $bits = null;
    if (strpos($s, '/') !== false) { [$ip, $bits] = explode('/', $s, 2); if (!ctype_digit($bits)) return false; }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return $bits === null || ((int)$bits >= 8 && (int)$bits <= 32);
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) return $bits === null || ((int)$bits >= 32 && (int)$bits <= 128);
    return false;
}
/* Descrição em português de uma expressão cron (casos comuns; o resto fica "personalizada") */
function cron_human(string $w): string {
    $w = trim(preg_replace('/\s+/', ' ', $w));
    $macros = ['@hourly' => 'De hora a hora', '@daily' => 'Todos os dias à meia-noite', '@weekly' => 'Aos domingos à meia-noite', '@monthly' => 'No dia 1 de cada mês à meia-noite', '@yearly' => 'Uma vez por ano (1 de janeiro)', '@annually' => 'Uma vez por ano (1 de janeiro)'];
    if (isset($macros[$w])) return $macros[$w];
    $p = explode(' ', $w);
    if (count($p) !== 5) return 'Expressão inválida';
    [$mi, $ho, $dm, $mo, $dw] = $p;
    $days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
    $hm = function ($h, $m) { return sprintf('%02d:%02d', (int)$h, (int)$m); };
    $n = '/^\d+$/';
    if ($dm === '*' && $mo === '*' && $dw === '*') {
        if ($mi === '*' && $ho === '*') return 'A cada minuto';
        if (preg_match('/^\*\/(\d+)$/', $mi, $m) && $ho === '*') return 'A cada ' . $m[1] . ' minutos';
        if (preg_match($n, $mi) && $ho === '*') return 'De hora a hora, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match('/^\*\/(\d+)$/', $ho, $m)) return 'A cada ' . $m[1] . ' horas, ao minuto ' . (int)$mi;
        if (preg_match($n, $mi) && preg_match($n, $ho)) return 'Todos os dias às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && $dm === '*' && $mo === '*') {
        if (preg_match('/^[0-7]$/', $dw)) return 'À ' . $days[(int)$dw] . ' às ' . $hm($ho, $mi);
        if ($dw === '1-5') return 'Dias úteis às ' . $hm($ho, $mi);
    }
    if (preg_match($n, $mi) && preg_match($n, $ho) && preg_match($n, $dm) && $mo === '*' && $dw === '*') return 'No dia ' . (int)$dm . ' de cada mês às ' . $hm($ho, $mi);
    return 'Expressão personalizada';
}
function ago(int $t, int $now): string {
    $d = $now - $t;
    if ($d < 60) return 'há instantes';
    if ($d < 3600) return 'há ' . intdiv($d, 60) . ' min';
    if ($d < 86400) return 'há ' . intdiv($d, 3600) . ' h';
    return 'há ' . intdiv($d, 86400) . ' d';
}
function fw_secs_php(string $d): int {
    if (!preg_match('/^(\d+)([smhd]?)$/', $d, $m)) return 0;
    return (int)$m[1] * ['' => 1, 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86400][$m[2]];
}
function valid_site(string $s): bool { return (bool)preg_match(RX_SITE, $s) && substr($s, -1) !== '-'; }
function site_limits(array $s): array {
    $l = is_array($s['limits'] ?? null) ? $s['limits'] : [];
    $o = [];
    foreach (LIMIT_DEFAULTS as $k => $d) $o[$k] = (int)($l[$k] ?? $d);
    $o['display_errors'] = !empty($l['display_errors']);
    return $o;
}
function host_only(): string {
    $h = (string)($_SERVER['HTTP_HOST'] ?? '');
    if ($h === '') $h = (string)($_SERVER['SERVER_ADDR'] ?? 'localhost');
    if ($h !== '' && $h[0] === '[') { $p = strpos($h, ']'); return $p === false ? $h : substr($h, 0, $p + 1); }
    return (string)preg_replace('/:\d+$/', '', $h);
}
function site_url(string $host, int $port): string { return 'http://' . $host . ($port === 80 ? '' : ':' . $port) . '/'; }
function fmt_uptime(int $s): string {
    if ($s >= 86400) { $d = intdiv($s, 86400); return $d . ($d === 1 ? ' dia' : ' dias'); }
    if ($s >= 3600) return intdiv($s, 3600) . ' h';
    return max(1, intdiv($s, 60)) . ' min';
}
function tone(string $name): string {
    $t = ['t-acc', 't-blue', 't-vio', 't-warn'];
    return $t[abs(crc32($name)) % 4];
}

/* ---------- ícones (SVG em linha, sem recursos externos) ---------- */
const ICONS = [
    'dash'   => '<rect x="4" y="4" width="6" height="8" rx="1.5"/><rect x="14" y="4" width="6" height="5" rx="1.5"/><rect x="4" y="16" width="6" height="4" rx="1.5"/><rect x="14" y="13" width="6" height="7" rx="1.5"/>',
    'world'  => '<circle cx="12" cy="12" r="9"/><path d="M3.6 9h16.8M3.6 15h16.8M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    'db'     => '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
    'code'   => '<path d="M7 8l-4 4 4 4M17 8l4 4-4 4M14 4l-4 16"/>',
    'pulse'  => '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
    'user'   => '<circle cx="12" cy="8" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/>',
    'plus'   => '<path d="M12 5v14M5 12h14"/>',
    'dots'   => '<circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/>',
    'reload' => '<path d="M20 11A8 8 0 0 0 5.3 7.5M4 4v4h4M4 13a8 8 0 0 0 14.7 3.5M20 20v-4h-4"/>',
    'power'  => '<path d="M7 6a7.8 7.8 0 1 0 10 0M12 4v8"/>',
    'play'   => '<path d="M7 4v16l13-8z"/>',
    'stop'   => '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    'moon'   => '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>',
    'sun'    => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'out'    => '<path d="M14 8V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2M9 12h12M18 9l3 3-3 3"/>',
    'menu'   => '<path d="M4 6h16M4 12h16M4 18h16"/>',
    'x'      => '<path d="M18 6L6 18M6 6l12 12"/>',
    'ext'    => '<path d="M12 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6M11 13l9-9M15 4h5v5"/>',
    'server' => '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    'cpu'    => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M10 10h4v4h-4zM3 10h3M3 14h3M18 10h3M18 14h3M10 3v3M14 3v3M10 18v3M14 18v3"/>',
    'sliders'=> '<path d="M4 6h8M16 6h4M4 12h2M10 12h10M4 18h11M19 18h1"/><circle cx="14" cy="6" r="2"/><circle cx="8" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
    'trash'  => '<path d="M4 7h16M10 11v6M14 11v6M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>',
    'key'    => '<circle cx="8" cy="15" r="4"/><path d="M10.8 12.2L20 3M16 7l3 3M14 9l2 2"/>',
    'lock'   => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    'toggle' => '<rect x="2" y="7" width="20" height="10" rx="5"/><circle cx="8" cy="12" r="2.5"/>',
    'check'  => '<path d="M5 12l5 5L20 7"/>',
    'alert'  => '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>',
    'table'  => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 10v10M15 10v10"/>',
    'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
    'folder' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    'folderplus' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 10.5v5M9.5 13h5"/>',
    'file'   => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    'zip'    => '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M10 5h1M10 8h1M10 11h1M10 14h1v3h-1z"/>',
    'upload' => '<path d="M12 16V4M7 9l5-5 5 5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'download' => '<path d="M12 4v12M7 11l5 5 5-5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    'home'   => '<path d="M4 11l8-7 8 7M6 9.5V20h12V9.5"/>',
    'edit'   => '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
    'move'   => '<path d="M5 12h14M15 8l4 4-4 4M5 5v14"/>',
    'up'     => '<path d="M12 19V5M6 11l6-6 6 6"/>',
    'chev'   => '<path d="M6 9l6 6 6-6"/>',
    'ban'    => '<circle cx="12" cy="12" r="9"/><path d="M5.7 5.7l12.6 12.6"/>',
    'clock'  => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    'archive'=> '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"/>',
];
/* Logótipo IDDigital Hosting (SVG em linha; o texto usa Arial ou equivalente métrico) */
function brand_logo(string $cls = 'brand-logo'): string {
    return '<svg class="' . h($cls) . '" viewBox="0 0 62.97 18.26" role="img" aria-label="IDDigital Hosting" xmlns="http://www.w3.org/2000/svg">'
        . '<path fill="#fff" d="M 10.696104,17.232981 C 9.5129773,16.842176 8.7260574,16.372185 7.9458244,15.590365 c -1.114,-1.116262 -1.7157692,-2.493883 -1.784426,-4.085056 -0.014374,-0.333159 -0.00865,-0.457078 0.029917,-0.647164 0.099813,-0.491997 0.3189197,-0.9047228 0.6668116,-1.2560559 0.8274806,-0.8356635 2.1314767,-1.0014038 3.189827,-0.405435 0.261545,0.1472777 0.723354,0.5928945 0.865202,0.8348679 0.214006,0.365059 0.316112,0.722462 0.350283,1.226095 0.0346,0.509923 0.209212,0.888772 0.54975,1.192761 0.343775,0.306876 0.717013,0.444297 1.196753,0.440625 0.525886,-0.004 0.905248,-0.154464 1.248715,-0.495181 0.235108,-0.233227 0.351055,-0.432298 0.431021,-0.740031 0.05275,-0.202983 0.05767,-0.273977 0.0419,-0.604108 C 14.662552,9.6065015 14.075119,8.3362136 12.999265,7.3056355 12.048684,6.3950566 10.862731,5.8387523 9.4907979,5.6598913 9.0218609,5.5987579 8.1134294,5.6186003 7.6756472,5.6995508 6.3679108,5.9413587 5.3155828,6.4713126 4.423572,7.3373012 3.910517,7.8353884 3.5632817,8.3130464 3.2715718,8.9219956 2.8556734,9.7901897 2.6909166,10.742689 2.7685575,11.830049 c 0.055923,0.783182 0.1672461,1.327816 0.436759,2.136766 0.1797827,0.539622 0.1806174,0.605202 0.00988,0.77594 -0.094738,0.09474 -0.119626,0.105283 -0.248473,0.105283 -0.1660019,0 -0.2799034,-0.05074 -0.3567817,-0.158919 C 2.5458511,14.598936 2.3598961,14.029801 2.2414377,13.561284 1.9117912,12.2575 1.8815863,10.789106 2.1618329,9.6914849 2.5560106,8.147645 3.6460195,6.7437251 5.1475424,5.8459267 7.3224606,4.545487 10.115883,4.5274669 12.319362,5.7996657 c 1.715935,0.9907074 2.873217,2.6135551 3.201846,4.4899243 0.07645,0.436502 0.110227,0.99086 0.07811,1.282039 -0.09176,0.832016 -0.604065,1.554468 -1.370112,1.932141 -0.425591,0.209822 -0.613626,0.24943 -1.177703,0.248064 -0.448773,-0.0011 -0.503433,-0.007 -0.732963,-0.07746 -0.87301,-0.268526 -1.522411,-0.925309 -1.734383,-1.754115 -0.02862,-0.111896 -0.06518,-0.356227 -0.08124,-0.542947 -0.03397,-0.394862 -0.102412,-0.627427 -0.25685,-0.872738 C 10.033828,10.167463 9.6093692,9.8704218 9.1869714,9.7634095 8.9528412,9.7040972 8.5620269,9.7097502 8.3021585,9.7762077 7.7275959,9.9231553 7.3086886,10.298932 7.111982,10.843844 c -0.074054,0.205143 -0.079853,0.249702 -0.077714,0.597194 0.00823,1.338483 0.5321468,2.601535 1.4809618,3.57036 0.7632773,0.779376 1.5081182,1.232518 2.5716382,1.564519 0.385877,0.120458 0.468886,0.189169 0.489653,0.405307 0.01075,0.111391 0.0027,0.152793 -0.03858,0.199197 -0.06269,0.07051 -0.307281,0.189422 -0.384621,0.187006 -0.03048,-9.44e-4 -0.236233,-0.06145 -0.457226,-0.134457 z M 6.6904661,17.164437 C 6.6024841,17.126114 6.1242485,16.631374 5.8040522,16.247429 5.3889771,15.749717 4.8134382,14.798822 4.5796876,14.224554 4.2080316,13.311486 4.0390981,12.44863 4.0344449,11.439633 4.0315488,10.812052 4.0523334,10.622866 4.1714275,10.192654 4.4032301,9.3552972 4.7979022,8.7065962 5.4566054,8.0802783 6.6288369,6.9656805 8.3477125,6.53442 9.9677565,6.9484445 11.395991,7.3134498 12.624593,8.385578 13.130529,9.7084047 c 0.179752,0.4699833 0.277045,0.9492623 0.284758,1.4027433 0.0039,0.2333 -0.0034,0.280082 -0.05759,0.367839 -0.07922,0.128173 -0.185,0.182331 -0.356132,0.182331 -0.271196,0 -0.421017,-0.180507 -0.42109,-0.50734 C 12.580366,10.630453 12.386096,9.9467474 12.106308,9.4850986 11.519961,8.5176305 10.503356,7.8549032 9.3382846,7.6806177 8.9765395,7.6265032 8.2377737,7.6433484 7.9250422,7.712841 6.3064884,8.0725247 5.1663437,9.216776 4.9019127,10.74686 c -0.048713,0.281867 -0.040483,1.037965 0.016134,1.482521 0.1392626,1.093469 0.435231,1.866856 1.1081841,2.895762 0.2908723,0.444728 0.4825181,0.683363 0.8959562,1.115635 0.2592815,0.271092 0.3388777,0.372163 0.3531957,0.448482 0.04265,0.227351 -0.069562,0.416401 -0.2855706,0.48112 -0.138344,0.04144 -0.193019,0.04037 -0.299346,-0.0059 z m 5.5207159,-1.54205 C 11.244805,15.510073 10.366448,15.094396 9.6752993,14.422292 8.8680425,13.637276 8.3961892,12.623707 8.3226635,11.516734 c -0.014569,-0.219391 -0.00898,-0.29249 0.029947,-0.394527 0.085794,-0.224661 0.3138299,-0.316951 0.5552824,-0.224741 0.1893172,0.0723 0.2336623,0.167004 0.2626962,0.561026 0.047867,0.649573 0.2164175,1.171521 0.5465019,1.692305 0.478925,0.755612 1.285532,1.346508 2.129856,1.56027 0.515341,0.130473 0.954321,0.158609 1.522371,0.09758 0.25322,-0.02721 0.502392,-0.04158 0.553715,-0.03196 0.0597,0.01126 0.129162,0.05719 0.192819,0.127645 0.08538,0.09451 0.0995,0.129217 0.0995,0.244514 0,0.157022 -0.07723,0.291864 -0.21238,0.370795 -0.171403,0.100097 -1.271672,0.163198 -1.791791,0.102753 z M 1.5515958,7.1526948 C 1.4873796,7.1293278 1.3569964,7.0003509 1.3135813,6.9172481 1.2251437,6.7479642 1.2653004,6.6170208 1.5014118,6.304768 2.2840541,5.2697396 3.2799235,4.4288405 4.4123052,3.8468473 5.3878281,3.345472 6.3437639,3.0512582 7.537093,2.8851119 c 0.4932469,-0.068671 1.9175775,-0.068671 2.4108249,0 2.4273701,0.3379607 4.3925631,1.4211281 5.8350501,3.2161431 0.273249,0.3400272 0.399842,0.5400029 0.399842,0.6316181 0,0.2252296 -0.195182,0.4254658 -0.414722,0.4254658 -0.07467,0 -0.158537,-0.019956 -0.201131,-0.047867 C 15.526779,7.0841417 15.377686,6.9100193 15.235648,6.7235286 14.506048,5.7655897 13.583182,5.007309 12.512436,4.485975 11.291939,3.8917299 10.097979,3.6209526 8.7009401,3.6215672 7.275676,3.6221957 6.0752471,3.8976143 4.8738546,4.4996332 3.7786794,5.0484254 2.900244,5.7808957 2.1395936,6.779554 2.0080624,6.952241 1.8662182,7.1112306 1.8243846,7.132865 1.7480846,7.172322 1.6292648,7.18096 1.5515958,7.1526948 Z M 3.8100123,2.7920664 C 3.497075,2.6920703 3.4166986,2.3074566 3.6618987,2.0833121 3.8117352,1.9463439 4.7695509,1.5215205 5.4243361,1.3016113 6.1572227,1.0554732 6.9907558,0.87692327 7.7864887,0.79561623 8.1981408,0.75355388 9.2857142,0.75413562 9.7123764,0.79666083 10.709221,0.89598665 11.56665,1.0988344 12.497294,1.4555195 12.959321,1.6326 13.75672,1.9956248 13.830686,2.0625642 13.908374,2.1328789 13.975124,2.3346744 13.95533,2.4394218 13.925446,2.5975653 13.842688,2.700374 13.702032,2.7540914 13.537356,2.8169826 13.504967,2.807915 12.926808,2.5369619 11.598059,1.9142622 10.445355,1.6422506 8.9975808,1.6097578 7.2861158,1.5713503 5.8249633,1.8966278 4.3478231,2.6448848 4.0272707,2.8072624 3.9358377,2.8322874 3.8100123,2.7920828 Z"/>'
        . '<g font-family="Arial,\'Liberation Sans\',Helvetica,sans-serif" font-weight="700">'
        . '<text x="18.0823" y="12.868" font-size="11.6841" fill="#16a596">id</text>'
        . '<text x="28.9553" y="12.7322" font-size="11.4367" fill="#fff">digital</text>'
        . '<text x="60.362" y="15.427" font-size="2.88254" font-weight="400" fill="#fff" text-anchor="end">hosting</text>'
        . '</g></svg>';
}

function ic(string $n, string $cls = ''): string {
    return '<svg class="i' . ($cls !== '' ? ' ' . $cls : '') . '" viewBox="0 0 24 24" aria-hidden="true">' . (ICONS[$n] ?? '') . '</svg>';
}

/* ---------- fila de tarefas (assíncrona) ---------- */
function job_submit(string $action, array $args, string $label): bool {
    $id = bin2hex(random_bytes(8));
    $payload = json_encode(['id' => $id, 'action' => $action, 'args' => array_values(array_map('strval', $args))]);
    $tmp = MP_TMP . '/' . $id . '.json';
    if (@file_put_contents($tmp, (string)$payload) === false || !@rename($tmp, MP_QUEUE . '/' . $id . '.json')) {
        @unlink($tmp);
        flash(false, 'Não foi possível colocar a tarefa na fila. Verifica as permissões de ' . MP_DATA . '.');
        return false;
    }
    $_SESSION['jobs'][$id] = ['label' => $label, 't' => time()];
    return true;
}
function job_collect(): int {
    $jobs = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
    foreach ($jobs as $id => $j) {
        $id = (string)$id;
        if (!preg_match('/^[a-f0-9]{16}$/', $id)) { unset($jobs[$id]); continue; }
        $res = MP_RESULTS . '/' . $id . '.json';
        clearstatcache(true, $res);
        if (is_file($res)) {
            $r = jload($res);
            @unlink($res);
            unset($jobs[$id]);
            $ok  = (bool)($r['ok'] ?? false);
            $msg = trim((string)($r['msg'] ?? ''));
            if ($msg === '') $msg = $j['label'] . ($ok ? ': concluído.' : ': falhou.');
            flash($ok, $msg, stripos($msg, 'password') !== false);
        } elseif (time() - (int)($j['t'] ?? 0) > 1800) {
            unset($jobs[$id]);
            flash(false, $j['label'] . ': sem resposta. No servidor: systemctl status minipainel-worker.path');
        }
    }
    $_SESSION['jobs'] = $jobs;
    return count($jobs);
}

/* ---------- limite de tentativas de login ---------- */
function rl_file(): string { return MP_RL . '/' . hash('sha256', (string)($_SERVER['REMOTE_ADDR'] ?? '')) . '.json'; }
function rl_wait(): int { $d = jload(rl_file()); $u = (int)($d['until'] ?? 0); return $u > time() ? $u - time() : 0; }
function rl_fail(): void {
    $f = rl_file();
    $d = jload($f);
    if ($d === null || time() - (int)($d['first'] ?? 0) > 900) $d = ['n' => 0, 'first' => time()];
    $d['n'] = (int)($d['n'] ?? 0) + 1;
    if ($d['n'] >= 5) $d = ['n' => 0, 'first' => time(), 'until' => time() + 600];
    @file_put_contents($f, (string)json_encode($d), LOCK_EX);
}
function rl_clear(): void { @unlink(rl_file()); }

/* ---------- estilos ---------- */
function mp_head(string $title): string {
    return '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' . h($title) . ' · IDDigital Hosting</title>'
        . '<script>(function(){var t=null;try{t=localStorage.getItem("mp-theme")}catch(e){}if(!t)t=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";document.documentElement.setAttribute("data-theme",t)})();</script>'
        . mp_css();
}
function mp_css(): string {
    return <<<'CSS'
<style>
:root{--bg:#e8edf2;--card:#fff;--ink:#14222f;--ink-2:#5f6e7c;--ink-3:#8d9aa6;--line:#e1e7ed;--line-2:#edf1f5;--hover:#f6f9fb;
--side:#13283a;--side-ink:#a9b8c6;--side-on:#1f5f8b;--acc:#1f5f8b;--acc-2:#184d72;--acc-bg:#e2edf6;--acc-ink:#1f5f8b;
--field:#eef3f9;--field-line:#d8e2ec;--hl:#1f5f8b;--c1:#1f5f8b;--c2:#66a8d8;--c3:#e0a33a;
--ok:#1c6b40;--ok-bg:#e2f5ea;--err:#b3261e;--err-bg:#fdecea;--warn:#9a5b08;--warn-bg:#fdf1dc;--blue-bg:#e8ecfb;--blue-ink:#3b4fb0;--vio-bg:#f1e9fb;--vio-ink:#6a3fa8;
--shadow:0 1px 2px rgba(16,24,40,.05);--pop:0 16px 40px rgba(16,24,40,.16);color-scheme:light}
[data-theme=dark]{--bg:#0d151d;--card:#16212c;--ink:#e6edf3;--ink-2:#a3b1bf;--ink-3:#728191;--line:#253342;--line-2:#1e2b38;--hover:#1a2733;
--side:#0a131b;--side-ink:#8fa1b3;--side-on:#2a6f9f;--acc:#3584bd;--acc-2:#4996cf;--acc-bg:#16334a;--acc-ink:#8cc4ec;
--field:#1b2836;--field-line:#2a3a4a;--hl:#235b84;--c1:#4a9ad3;--c2:#a8cdee;--c3:#f0b75a;
--ok:#7ed3a4;--ok-bg:#15372a;--err:#f19c95;--err-bg:#3d1b1a;--warn:#f0c27a;--warn-bg:#3a2b12;--blue-bg:#1e2a52;--blue-ink:#a9b6f5;--vio-bg:#2d2143;--vio-ink:#c8adf0;
--shadow:none;--pop:0 16px 40px rgba(0,0,0,.45);color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0}
body{font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,"Helvetica Neue",sans-serif;background:var(--bg);color:var(--ink);-webkit-font-smoothing:antialiased}
a{color:var(--acc-ink)}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
svg.i{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.app{display:grid;grid-template-columns:240px minmax(0,1fr);min-height:100vh}
.side{position:sticky;top:0;height:100vh;background:var(--side);color:var(--side-ink);display:flex;flex-direction:column;gap:2px;padding:18px 14px}
.brand{display:flex;align-items:center;gap:10px;color:#fff;font-weight:650;font-size:17px;padding:2px 10px 22px;text-decoration:none}
.logo{width:32px;height:32px;border-radius:9px;background:var(--acc);display:grid;place-items:center;color:#fff}
.nav a{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:9px;color:var(--side-ink);text-decoration:none;font-weight:500}
.nav a:hover{color:#fff;background:rgba(255,255,255,.04)}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#5fd0d1}
.nav a svg.tail{width:14px;height:14px;margin-left:auto;opacity:.6}
.side-foot{margin-top:auto;border-top:1px solid rgba(255,255,255,.08);padding:14px 6px 0 10px;display:flex;align-items:center;justify-content:space-between;gap:8px}
.side-foot b{display:block;color:#fff;font-weight:600}
.side-foot span{font-size:12px}
.side-foot form{margin:0}
.iconbtn{display:inline-grid;place-items:center;width:38px;height:38px;border-radius:9px;border:1px solid var(--line);background:var(--card);color:var(--ink-2);cursor:pointer;text-decoration:none}
.iconbtn:hover{color:var(--ink);border-color:var(--ink-3)}
.side .iconbtn{background:transparent;border-color:rgba(255,255,255,.12);color:var(--side-ink)}
.side .iconbtn:hover{color:#fff;border-color:rgba(255,255,255,.3)}
.main{display:flex;flex-direction:column;min-width:0}
.top{display:flex;align-items:center;gap:14px;padding:24px 32px 4px}
.top .grow{flex:1;min-width:0}
.top h1{margin:0;font-size:22px;font-weight:650;letter-spacing:-.01em}
.top p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.top-actions{display:flex;align-items:center;gap:8px}
.top-actions form{margin:0}
.burger{display:none}
.content{padding:18px 32px 36px;display:flex;flex-direction:column;gap:20px}
.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;box-shadow:var(--shadow);min-width:0}
.stat>div{min-width:0;flex:1}
.tile{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none}
.tile svg.i{width:21px;height:21px}
.t-acc{background:var(--acc-bg);color:var(--acc-ink)}.t-blue{background:var(--blue-bg);color:var(--blue-ink)}.t-vio{background:var(--vio-bg);color:var(--vio-ink)}.t-warn{background:var(--warn-bg);color:var(--warn)}
.stat .k{color:var(--ink-2);font-size:13px}
.stat .v{font-size:24px;font-weight:650;line-height:1.25}
.stat .v small{font-size:13px;font-weight:500;color:var(--ink-2)}
.meter{height:5px;border-radius:3px;background:var(--line-2);overflow:hidden;margin-top:6px}
.meter i{display:block;height:100%;background:var(--acc);border-radius:3px}
.meter i.hi{background:var(--err)}
.grid2{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:20px;align-items:start}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);min-width:0}
.card-h{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.card-h h2{margin:0;font-size:15px;font-weight:650}
.card-h p{margin:0;color:var(--ink-2);font-size:13px}
.card-b{padding:18px}
.card-f{padding:12px 18px;border-top:1px solid var(--line-2);font-size:13px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:38px;padding:0 16px;border-radius:9px;border:1px solid transparent;background:var(--acc);color:#fff;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.btn:hover{background:var(--acc-2)}
.btn.sec{background:var(--card);color:var(--ink);border-color:var(--line)}
.btn.sec:hover{border-color:var(--ink-3)}
.btn.dan{background:var(--err);color:#fff}
.btn.dan:hover{filter:brightness(.93)}
.btn.sm{height:32px;padding:0 11px;font-size:13px;border-radius:8px;gap:6px}
.btn.sm svg.i{width:15px;height:15px}
.btn:disabled{opacity:.6;cursor:wait}
.list{width:100%;border-collapse:collapse}
.list th{font-size:12px;font-weight:600;color:var(--ink-2);text-align:left;padding:10px 18px;border-bottom:1px solid var(--line-2)}
.list td{padding:12px 18px;border-bottom:1px solid var(--line-2);vertical-align:middle}
.list tr:last-child td{border-bottom:0}
.list tbody tr:hover td{background:var(--hover)}
.list .r{text-align:right}
.who{display:flex;align-items:center;gap:12px;min-width:0}
.av{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:650;flex:none;text-transform:uppercase}
.nm{font-weight:600}
.mu{color:var(--ink-2);font-size:12.5px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.pill::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}
.p-ok{background:var(--ok-bg);color:var(--ok)}.p-off{background:var(--line-2);color:var(--ink-2)}.p-err{background:var(--err-bg);color:var(--err)}
.port{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-weight:600;background:var(--acc-bg);color:var(--acc-ink);padding:2px 8px;border-radius:6px;font-size:12.5px}
.lim{display:flex;flex-wrap:wrap;gap:4px 10px;color:var(--ink-2);font-size:12.5px}
.lim b{color:var(--ink);font-weight:600}
.links a{display:inline-flex;align-items:center;gap:5px;text-decoration:none;font-weight:500}
.links a svg.i{width:14px;height:14px}
.row-list .item{display:flex;align-items:center;gap:12px;padding:12px 18px;border-bottom:1px solid var(--line-2)}
.row-list .item:last-child{border-bottom:0}
.row-list .grow{flex:1;min-width:0}
.row-list .item>.pill:first-child{min-width:74px;justify-content:center}
.svc-acts{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.svc-acts form{margin:0}
details.dd{position:relative;display:inline-block}
details.dd>summary{list-style:none;cursor:pointer}
details.dd>summary::-webkit-details-marker{display:none}
.dd-menu{position:absolute;right:0;top:calc(100% + 6px);z-index:30;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.dd-menu form{margin:0}
.dd-menu a,.dd-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer;text-decoration:none}
.dd-menu a:hover,.dd-menu button:hover{background:var(--line-2)}
.dd-menu .dan{color:var(--err)}
.dd-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
dialog{border:0;padding:0;border-radius:16px;background:var(--card);color:var(--ink);width:min(520px,calc(100vw - 24px));max-height:calc(100vh - 24px);box-shadow:var(--pop)}
dialog::backdrop{background:rgba(8,14,20,.55)}
dialog[open]{display:flex;flex-direction:column}
dialog form{display:flex;flex-direction:column;min-height:0;flex:1;margin:0}
dialog.drawer{margin:0 0 0 auto;height:100vh;max-height:100vh;width:min(480px,100vw);border-radius:16px 0 0 16px}
.dlg-h{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:18px 22px;border-bottom:1px solid var(--line-2)}
.dlg-h h3{margin:0;font-size:17px;font-weight:650}
.dlg-h p{margin:2px 0 0;color:var(--ink-2);font-size:13px}
.dlg-b{padding:20px 22px;display:grid;gap:16px;overflow:auto;flex:1;align-content:start}
.dlg-f{display:flex;justify-content:flex-end;gap:8px;padding:14px 22px;border-top:1px solid var(--line-2)}
.fld{display:flex;flex-direction:column;gap:6px;font-size:13px;color:var(--ink-2);font-weight:500}
.fld small{font-weight:400;color:var(--ink-3);font-size:12px}
.in{height:40px;padding:0 12px;border:1px solid var(--line);border-radius:9px;background:var(--card);color:var(--ink);font:inherit;width:100%}
.in:focus{outline:0;border-color:var(--acc);box-shadow:0 0 0 3px var(--acc-bg)}
.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.fsec{margin:6px 0 -4px;padding-top:14px;border-top:1px solid var(--line-2);font-size:13px;font-weight:650;color:var(--ink)}
.chk{display:flex;align-items:center;gap:10px;font-size:14px;color:var(--ink);font-weight:400}
.chk input{width:18px;height:18px;accent-color:var(--acc)}
.warnbox{padding:12px 14px;border-radius:10px;background:var(--warn-bg);color:var(--warn);font-size:13px}
.pills{display:flex;flex-wrap:wrap;gap:6px}
.pills a{padding:5px 12px;border:1px solid var(--line);border-radius:999px;color:var(--ink);text-decoration:none;font-size:13px;font-weight:500}
.pills a:hover{border-color:var(--ink-3)}
.pills a.on{background:var(--acc);border-color:var(--acc);color:#fff}
.lead{margin:0;padding:14px 18px 0;color:var(--ink-2);font-size:13px}
.exts{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:12px;padding:16px 18px 18px}
.ext{display:flex;align-items:center;justify-content:space-between;gap:12px;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.ext.on{border-color:var(--ok-bg);background:var(--hover)}
.ext .d{min-width:0}
.ext .d b{display:block;font-weight:600}
.ext .d span{display:block;color:var(--ink-2);font-size:12.5px}
.ext form{display:flex;align-items:center;gap:8px;margin:0}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{padding:2px 9px;border:1px solid var(--line);border-radius:6px;background:var(--hover);font-size:12px}
.empty{padding:40px 20px;text-align:center;color:var(--ink-2)}
.empty b{display:block;color:var(--ink);font-size:15px;margin-bottom:4px}
.empty .btn{margin-top:14px}
.toasts{position:fixed;top:16px;right:16px;z-index:100;display:flex;flex-direction:column;gap:10px;width:min(420px,calc(100vw - 32px))}
.toast{display:flex;gap:12px;align-items:flex-start;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:12px 12px 12px 14px}
.toast .ti{width:26px;height:26px;border-radius:50%;display:grid;place-items:center;flex:none}
.toast .ti svg.i{width:15px;height:15px}
.toast.ok .ti{background:var(--ok-bg);color:var(--ok)}
.toast.err .ti{background:var(--err-bg);color:var(--err)}
.toast .msg{flex:1;min-width:0;white-space:pre-wrap;font-size:13.5px;padding-top:2px;overflow-wrap:anywhere}
.toast .msg.mono{font-size:12.5px}
.toast button{border:0;background:none;color:var(--ink-3);cursor:pointer;padding:2px;display:grid}
.spin{width:16px;height:16px;border:2px solid var(--line);border-top-color:var(--acc);border-radius:50%;animation:sp .8s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.scrim{display:none}
.login{min-height:100vh;display:grid;place-items:center;padding:24px}
.login form{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--pop);padding:30px;display:flex;flex-direction:column;gap:16px}
.login .brand{color:var(--ink);justify-content:center;padding:0 0 6px}
.login .err{padding:10px 12px;border-radius:10px;background:var(--err-bg);color:var(--err);font-size:13px}
a.stat{color:inherit;text-decoration:none}
a.stat:hover{border-color:var(--ink-3)}
.stat.hot{border-color:var(--err)}
.stat.hot .v,.stat.hot .k{color:var(--err)}
.stats5{grid-template-columns:repeat(5,minmax(0,1fr))}
.stats5 .v small{display:block;font-size:12.5px;line-height:1.4;margin-top:2px}
.stats5 .v small,.stats5 .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stats5 .mu{font-size:12.5px}
@media (max-width:1600px) and (min-width:1181px){.stats5 .tile{display:none}}
.grid2e{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:20px;align-items:start}
.legend{display:flex;gap:14px;flex-wrap:wrap;color:var(--ink-2);font-size:12.5px;margin-right:auto}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.legend i.dash{background:none;border-top:2px dashed var(--err);height:0;width:14px;border-radius:0;vertical-align:3px;opacity:.7}
.chart{display:grid;grid-template-columns:60px minmax(0,1fr);grid-template-rows:200px 26px;padding:18px 20px 10px 0}
.ch-y{position:relative}
.ch-y span{position:absolute;right:10px;transform:translateY(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-plot{position:relative;border-left:1px solid var(--line);border-bottom:1px solid var(--line)}
.ch-plot svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible}
.ch-plot path.s{fill:none;stroke-width:2;vector-effect:non-scaling-stroke;stroke-linejoin:round;stroke-linecap:round}
.ch-plot line.g{stroke:var(--line-2);stroke-width:1;vector-effect:non-scaling-stroke}
.ch-plot line.ref{stroke:var(--err);stroke-width:1.5;stroke-dasharray:5 5;vector-effect:non-scaling-stroke;opacity:.6}
.ch-x{grid-column:2;position:relative}
.ch-x span{position:absolute;top:7px;transform:translateX(-50%);font-size:11.5px;color:var(--ink-3);white-space:nowrap}
.ch-x span.first{transform:none}
.ch-x span.last{transform:translateX(-100%)}
.ch-cur{position:absolute;top:0;bottom:0;width:1px;background:var(--ink-3);display:none;pointer-events:none}
.ch-tip{position:absolute;top:8px;display:none;background:var(--card);border:1px solid var(--line);border-radius:10px;box-shadow:var(--pop);padding:8px 10px;font-size:12px;pointer-events:none;white-space:nowrap;z-index:5;margin:0 10px}
.ch-tip b{display:block;margin-bottom:4px;font-weight:600}
.ch-tip i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px}
.ch-empty{position:absolute;inset:0;display:grid;place-items:center;color:var(--ink-2);font-size:13px;text-align:center;padding:0 20px}
.fm-bar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--line-2)}
.fm-site{width:auto;min-width:170px}
.crumbs{display:flex;align-items:center;flex-wrap:wrap;gap:2px;flex:1;min-width:0;font-size:14px}
.crumbs button{border:0;background:none;color:var(--acc-ink);font:inherit;cursor:pointer;padding:4px 6px;border-radius:6px;display:inline-flex;align-items:center;gap:6px}
.crumbs button:hover{background:var(--line-2)}
.crumbs button:last-child{color:var(--ink);font-weight:600}
.crumbs .sep{color:var(--ink-3)}
.fm-tools{display:flex;gap:8px;flex-wrap:wrap}
.fm-tools label.btn{cursor:pointer}
.fm-selbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 18px;background:var(--acc-bg);color:var(--acc-ink);border-bottom:1px solid var(--line-2);font-size:13.5px;font-weight:600}
.fm-selbar[hidden]{display:none}
.fm-selbar .grow{flex:1}
.fm-drop{position:relative;min-height:240px}
.fm-drop.over{outline:2px dashed var(--acc);outline-offset:-8px;background:var(--hover)}
.fm-hint{display:none}
.fm-drop.over .fm-hint{display:grid;place-items:center;position:absolute;inset:0;font-weight:600;color:var(--acc-ink);pointer-events:none;background:rgba(18,164,166,.06)}
.fm-first{display:flex;align-items:center;gap:12px;min-width:0}
.fm-name{display:inline-flex;align-items:center;gap:10px;border:0;background:none;color:var(--ink);font:inherit;cursor:pointer;padding:0;text-align:left;min-width:0;max-width:100%}
.fm-name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-name:hover span{color:var(--acc-ink);text-decoration:underline}
svg.i.dir{color:#d99a2b}
svg.i.zip{color:var(--vio-ink)}
svg.i.code{color:var(--blue-ink)}
svg.i.file{color:var(--ink-3)}
.fm-ck{display:inline-flex;align-items:center}
.fm-ck input{width:16px;height:16px;margin:0;accent-color:var(--acc)}
.fm-list th:first-child{display:flex;align-items:center;gap:12px}
.fm-list tr.sel td{background:var(--acc-bg)}
.fm-menu{position:fixed;z-index:70;min-width:220px;background:var(--card);border:1px solid var(--line);border-radius:12px;box-shadow:var(--pop);padding:6px}
.fm-menu[hidden]{display:none}
.fm-menu button{display:flex;align-items:center;gap:10px;width:100%;padding:9px 10px;border:0;background:none;border-radius:8px;color:var(--ink);font:inherit;text-align:left;cursor:pointer}
.fm-menu button:hover{background:var(--line-2)}
.fm-menu .dan{color:var(--err)}
.fm-menu hr{border:0;border-top:1px solid var(--line-2);margin:6px 2px}
.ups{position:fixed;right:16px;bottom:16px;z-index:90;width:min(420px,calc(100vw - 32px));max-height:50vh;display:flex;flex-direction:column;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--pop)}
.ups[hidden]{display:none}
.ups-h{display:flex;align-items:center;gap:10px;padding:10px 12px 10px 16px;border-bottom:1px solid var(--line-2)}
.ups-h span{flex:1;color:var(--ink-2);font-size:12.5px}
.ups-l{overflow:auto}
.up{padding:10px 16px;border-bottom:1px solid var(--line-2);font-size:13px}
.up:last-child{border-bottom:0}
.up .nm2{display:flex;justify-content:space-between;gap:10px}
.up .nm2 span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.up .nm2 span:last-child{color:var(--ink-2);white-space:nowrap}
.up .bar{height:5px;border-radius:3px;background:var(--line-2);margin-top:6px;overflow:hidden}
.up .bar i{display:block;height:100%;width:0;background:var(--acc);border-radius:3px;transition:width .2s}
.up.ok .bar i{background:#2ea36a}
.up.err .bar i{background:var(--err)}
.up.err .nm2 span:last-child{color:var(--err);white-space:normal;text-align:right}
dialog.fm-ed{width:min(1100px,100vw)}
.fm-ed .dlg-h p{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.fm-ed textarea{flex:1;min-height:0;width:100%;border:0;resize:none;padding:16px 22px;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--card);color:var(--ink);tab-size:4;outline:0;white-space:pre;overflow:auto}
.fm-ed .dlg-f{align-items:center}
.fm-ed .dlg-f .mu{flex:1}
/* ---------- tema v1.5 ---------- */
body{font-size:14.5px}
h1,h2,h3,.brand,.stat .v,.hl .v{letter-spacing:-.015em}
.app{grid-template-columns:282px minmax(0,1fr)}
.side{top:12px;margin:12px 0 12px 12px;height:calc(100vh - 24px);border-radius:24px;padding:24px 14px 18px;gap:2px;overflow-y:auto}
.brand{padding:2px 12px 16px;font-size:18px}
.logo{border-radius:11px;background:var(--side-on)}
.nav-sec{padding:18px 14px 8px;font-size:12px;font-weight:600;color:#7f95a8}
.nav a{padding:11px 14px;border-radius:13px;color:#d3dee8;font-weight:600}
.nav a:hover{background:rgba(255,255,255,.05);color:#fff}
.nav a.on{background:var(--side-on);color:#fff}
.nav a.on svg{color:#fff}
.side-foot{display:block;margin-top:auto;border-top:0;padding:16px 14px 0;color:#7f95a8;font-size:12px}
.top{padding:24px 34px 6px 30px;gap:12px;align-items:center}
.crumb{font-size:12.5px;font-weight:600;color:var(--ink-2);margin-bottom:2px}
.top h1{font-size:26px;font-weight:750}
.top p{margin-top:4px}
.top-actions{gap:10px;flex-wrap:wrap;justify-content:flex-end}
.chip{display:inline-flex;align-items:center;gap:8px;height:44px;padding:0 18px;border-radius:999px;background:var(--card);box-shadow:0 1px 2px rgba(16,40,64,.05),0 4px 14px rgba(16,40,64,.05);border:0;color:var(--ink);font:inherit;font-weight:600;cursor:pointer;text-decoration:none;white-space:nowrap}
.chip:hover{color:var(--acc-ink)}
.chip svg.i{width:17px;height:17px}
.chip.sm{height:32px;padding:0 14px;font-size:13px;box-shadow:none;background:var(--line-2)}
.chip.ghost{background:transparent;box-shadow:none;color:var(--ink-2);font-weight:500;padding:0 4px;cursor:default}
.chip.prim{background:var(--acc);color:#fff}
.chip.prim:hover{background:var(--acc-2);color:#fff}
.chip.icon{width:44px;padding:0;justify-content:center}
.chip.soft{background:var(--acc-bg);color:var(--acc-ink);box-shadow:none}
.chip.soft:hover{filter:brightness(.97)}
details.me>summary{list-style:none;padding:0 14px 0 7px}
details.me>summary::-webkit-details-marker{display:none}
.av-me{width:32px;height:32px;border-radius:50%;background:var(--acc);color:#fff;display:grid;place-items:center;font-weight:700;font-size:13px;text-transform:uppercase}
svg.i.chev{width:15px;height:15px;color:var(--ink-3)}
.content{padding:16px 34px 40px 30px;gap:24px}
.card,.stat{border:0;border-radius:24px;box-shadow:0 1px 2px rgba(16,40,64,.04),0 10px 30px rgba(16,40,64,.05)}
.card-h{padding:24px 28px;border-bottom:1px solid var(--line-2)}
.card-h h2{font-size:17px;font-weight:700}
.card-h>div>p{margin:4px 0 0}
.card-b{padding:24px 28px}
.card-f{padding:16px 28px}
.stat{padding:20px 22px}
.tile{border-radius:14px}
.btn{height:42px;border-radius:12px}
.btn.sm{height:34px;border-radius:10px}
.in{height:46px;border-radius:12px;background:var(--field);border-color:var(--field-line)}
.in:focus{background:var(--card);border-color:var(--acc);box-shadow:0 0 0 4px var(--acc-bg)}
.list th{padding:14px 28px;font-size:12.5px}
.list td{padding:16px 28px}
.row-list .item{padding:15px 28px}
.lead{padding:16px 28px 0}
.exts{padding:18px 28px 24px}
.ext{border-radius:16px}
.pill{padding:4px 12px}
.pills a{padding:7px 15px;font-weight:600}
.pills a.on{background:var(--acc);border-color:var(--acc)}
dialog{border-radius:24px}
dialog.drawer{border-radius:24px 0 0 24px}
.dlg-h,.dlg-b,.dlg-f{padding-left:26px;padding-right:26px}
.dd-menu,.fm-menu{border-radius:16px}
.toast{border-radius:16px}
.ups{border-radius:20px}
.fm-bar,.fm-selbar{padding-left:28px;padding-right:28px}
.chart{padding:22px 28px 12px 0}
.ch-plot path.a{stroke:none;fill-opacity:.1}
.ch-plot path.dot{fill:none;stroke-width:7;stroke-linecap:round;vector-effect:non-scaling-stroke}
.hero{display:grid;grid-template-columns:minmax(0,2.3fr) minmax(0,1fr);gap:24px;align-items:stretch}
.hl{background:var(--hl);color:#fff;border-radius:24px;padding:28px 30px 0;display:flex;flex-direction:column;overflow:hidden;min-height:320px;box-shadow:0 10px 30px rgba(16,40,64,.12)}
.hl .k{font-weight:700;font-size:15px;color:rgba(255,255,255,.9)}
.hl .v{font-size:60px;font-weight:800;line-height:1.05;margin-top:12px}
.hl .s{color:rgba(255,255,255,.85);font-weight:600;font-size:14px;margin-top:8px}
.hl svg{display:block;margin:auto -30px 0;width:calc(100% + 60px);height:130px}
.bars .item{display:grid;grid-template-columns:minmax(170px,1.3fr) minmax(0,1.4fr) 64px 104px 40px;gap:16px;align-items:center}
.bars .mu{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bars .num{text-align:right;font-variant-numeric:tabular-nums}
.bars .bar{height:8px;border-radius:4px;background:var(--line-2);overflow:hidden}
.bars .bar i{display:block;height:100%;background:var(--acc);border-radius:4px}
.bars .pill{justify-self:start}
.brand{display:flex;align-items:center}
.brand-logo{display:block;height:46px;width:auto;max-width:100%}
.auth-side .brand-logo{height:58px}
.cn-search{width:260px;height:40px}
.cn-hot{color:var(--err)}
.p-me{background:var(--acc-bg);color:var(--acc-ink)}
.p-me::before{display:none}
.btn.danger-o{background:var(--card);color:var(--err);border:1px solid #e3b4af}
.btn.danger-o:hover{background:var(--err-bg)}
.cron-cmd{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:460px}
.cron-when{white-space:nowrap}
.cron-fields{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px}
.cron-fields .in{text-align:center;padding:0 6px}
.cron-human{padding:10px 14px;border-radius:12px;background:var(--acc-bg);color:var(--acc-ink);font-weight:600;font-size:13.5px}
.cron-human.bad{background:var(--err-bg);color:var(--err)}
.cron-ta{height:auto;min-height:84px;padding:10px 12px;resize:vertical;line-height:1.5}
.cron-help{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:-6px}
.cron-out{margin:0;padding:18px 26px;max-height:60vh;overflow:auto;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;background:var(--hover)}
@media (max-width:900px){.cron-fields{grid-template-columns:repeat(3,minmax(0,1fr))}.cron-cmd{max-width:60vw}}
.bk-run .item{gap:16px}
dialog{text-align:left}
.rm-grp{display:grid;gap:14px}
.rm-grp[hidden]{display:none}
.auth{background:var(--card)}
.auth-wrap{display:grid;grid-template-columns:1fr 1fr;min-height:100vh}
.auth-side{background-color:#13283a;background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:48px 48px;color:#fff;padding:52px 56px;display:flex;flex-direction:column;justify-content:space-between;gap:40px}
.auth-side .brand{color:#fff;padding:0}
.auth-side .logo{background:#1f5f8b}
.auth-hero h1{margin:0;font-size:clamp(36px,3.6vw,56px);line-height:1.08;font-weight:800;letter-spacing:-.025em}
.auth-hero h1 span{color:#9db8cf}
.auth-hero p{margin:20px 0 0;max-width:460px;color:#c6d3de;font-size:17px;line-height:1.55}
.auth-foot{color:#8ea4b7;font-size:13px}
.auth-main{display:grid;place-items:center;padding:40px 28px;background:var(--card)}
.auth-form{width:min(380px,100%);display:flex;flex-direction:column;gap:18px}
.auth-form h2{margin:0;font-size:28px;font-weight:750;letter-spacing:-.02em}
.auth-form>p{margin:-10px 0 6px;color:var(--ink-2)}
.auth-form .fld{color:var(--ink);font-weight:600;font-size:14px}
.auth-form .btn{height:52px;border-radius:14px;font-size:15px;margin-top:4px}
.auth-form .err{padding:12px 14px;border-radius:12px;background:var(--err-bg);color:var(--err);font-size:13.5px}
@media (max-width:1180px){.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.grid2{grid-template-columns:1fr}.stats5{grid-template-columns:repeat(3,minmax(0,1fr))}.grid2e{grid-template-columns:1fr}}
@media (max-width:900px){
  .app{grid-template-columns:1fr}
  .side{position:fixed;left:0;top:0;bottom:0;height:auto;width:264px;z-index:60;transform:translateX(-100%);transition:transform .2s ease}
  body.nav-open .side{transform:none}
  body.nav-open .scrim{display:block;position:fixed;inset:0;background:rgba(8,14,20,.55);z-index:50}
  .burger{display:inline-grid}
  .top{padding:14px 16px 2px;gap:10px}
  .top h1{font-size:19px}
  .top p{display:none}
  .top-actions .btn .lbl{display:none}
  .top-actions .btn{width:38px;padding:0}
  .content{padding:12px 16px 28px;gap:16px}
  .stats{gap:12px}
  .stat{padding:12px;gap:10px;flex-direction:column;align-items:flex-start}
  .tile{width:36px;height:36px;border-radius:10px}
  .stat .v{font-size:20px}
  .fgrid{grid-template-columns:1fr}
  .in{font-size:16px}
  table.cards thead{display:none}
  table.cards,table.cards tbody,table.cards tr,table.cards td{display:block;width:100%}
  table.cards tr{position:relative;padding:12px 16px;border-bottom:1px solid var(--line-2)}
  table.cards tr:last-child{border-bottom:0}
  table.cards tbody tr:hover td{background:none}
  table.cards td{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:5px 0;border:0;text-align:right}
  table.cards td::before{content:attr(data-label);color:var(--ink-2);font-size:12.5px;text-align:left;flex:none}
  table.cards td.first{display:block;text-align:left;padding:0 44px 8px 0}
  table.cards td.first::before,table.cards td.act::before{content:none}
  table.cards td.act{position:absolute;top:12px;right:12px;width:auto;padding:0}
  table.cards .lim{justify-content:flex-end}
  .row-list .item{flex-wrap:wrap}
  .svc-acts{width:100%;justify-content:flex-start}
  .exts{grid-template-columns:1fr;padding:14px 16px}
  dialog.drawer{width:100vw;border-radius:0}
  .stats5{grid-template-columns:repeat(2,minmax(0,1fr))}
  .chart{grid-template-columns:44px minmax(0,1fr);grid-template-rows:160px 24px}
  .fm-site{width:100%}
  .crumbs{flex-basis:100%}
  .fm-tools{width:100%}
  .fm-tools .btn{flex:1}
  .fm-list td.first{padding-right:44px}
  .ups{right:8px;left:8px;bottom:8px;width:auto}
  .toasts{top:auto;bottom:16px;right:16px}
}
@media (max-width:420px){.stats{grid-template-columns:1fr 1fr}.stat .v small{display:block}}
@media (max-width:1180px){.hero{grid-template-columns:1fr}.hl{min-height:260px}}
@media (max-width:900px){
  .side{margin:0;top:0;height:100vh;border-radius:0 24px 24px 0}
  .top{padding:14px 16px 4px}
  .top .hide-m,.chip .lbl{display:none}
  .top{flex-wrap:wrap}
  .top-actions{order:3;width:100%;justify-content:flex-start}
  .ch-x span:nth-child(even){display:none}
  .hl{min-height:220px}
  .chip.prim,.chip{height:40px}
  .chip.prim{width:40px;padding:0;justify-content:center}
  details.me>summary{padding:0 4px}
  .content{padding:12px 16px 28px;gap:18px}
  .card-h,.card-b,.card-f,.row-list .item,.lead,.exts,.fm-bar,.fm-selbar{padding-left:18px;padding-right:18px}
  .chart{padding:16px 16px 10px 0}
  .hl{padding:22px 22px 0}
  .hl svg{margin:auto -22px 0;width:calc(100% + 44px)}
  .hl .v{font-size:46px}
  .bars .item{grid-template-columns:minmax(0,1fr) auto auto;gap:10px 12px}
  .bars .bar{grid-column:1 / -1;order:9}
  .bars .num{order:2}
  .auth-wrap{grid-template-columns:1fr}
  .auth-side{padding:28px 24px;gap:26px}
  .auth-hero h1{font-size:32px}
  .auth-hero p{font-size:15px}
  .auth-foot{display:none}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation-duration:2s!important}}
</style>
CSS;
}

function render_login(string $err): void { ?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head('Entrar') ?></head>
<body class="auth">
<div class="auth-wrap">
  <section class="auth-side">
    <span class="brand"><?= brand_logo() ?></span>
    <div class="auth-hero">
      <h1>Gerir o servidor<br><span>e todos os sites.</span></h1>
      <p>Sites, bases de dados, ficheiros e serviços, a partir de um só painel.</p>
    </div>
    <div class="auth-foot">© <?= date('Y') ?> IDDigital Hosting · v<?= h(MP_VERSION) ?></div>
  </section>
  <section class="auth-main">
    <form method="post" action="./" class="auth-form">
      <h2>Iniciar sessão</h2>
      <p>Acede ao painel de alojamento.</p>
      <?php if ($err !== ''): ?><div class="err"><?= h($err) ?></div><?php endif; ?>
      <?= csrf_field() ?>
      <label class="fld">Utilizador<input class="in" name="user" autocomplete="username" required autofocus></label>
      <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="current-password" required></label>
      <button class="btn" type="submit">Entrar</button>
    </form>
  </section>
</div>
</body>
</html>
<?php }

/* ---------- autenticação ---------- */
$auth  = jload(MP_AUTH);
$pages = [
    'resumo'   => ['Resumo', 'dash'],
    'recursos' => ['Recursos', 'cpu'],
    'sites'    => ['Sites', 'world'],
    'ficheiros'=> ['Ficheiros', 'folder'],
    'cron'     => ['Tarefas agendadas', 'clock'],
    'bd'       => ['Bases de dados', 'db'],
    'php'      => ['PHP', 'code'],
    'servicos' => ['Serviços', 'pulse'],
    'ligacoes' => ['Ligações', 'ban'],
    'backups'  => ['Backups', 'archive'],
    'conta'    => ['Conta', 'user'],
];
$pg   = qget('p');
$page = isset($pages[$pg]) ? $pg : 'resumo';

if (!empty($_SESSION['user']) && time() - (int)($_SESSION['seen'] ?? 0) > MP_IDLE) {
    $_SESSION = [];
    session_regenerate_id(true);
}

if (qget('stats') === 'live') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $d = @file_get_contents(MP_STATS . '/live.json');
    echo $d !== false ? $d : '{}';
    exit;
}

if (qget('stats') === 'conns') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{}'; exit; }
    session_write_close();
    $d = @file_get_contents(MP_STATS . '/conns.json');
    echo $d !== false ? $d : '{}';
    exit;
}

if (qget('bk') === 'dl') {
    if (empty($_SESSION['user'])) { http_response_code(401); exit; }
    session_write_close();
    $bs = qget('s'); $bid = qget('id'); $bf = qget('f');
    if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)
        || !preg_match('/^(ficheiros\.tar\.gz|sistema\.tar\.gz|bd-[a-z][a-z0-9_]{0,31}\.sql\.gz)$/', $bf)) { http_response_code(400); exit('Pedido inválido.'); }
    $path = MP_BK . '/' . $bs . '/' . $bid . '/' . $bf;
    if (!is_file($path) || !is_readable($path)) { http_response_code(404); exit('Ficheiro não encontrado.'); }
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/gzip');
    header('Content-Length: ' . (string)filesize($path));
    header('Content-Disposition: attachment; filename="' . trim($bs, '_') . '-' . $bid . '-' . $bf . '"');
    header('X-Accel-Buffering: no');
    readfile($path);
    exit;
}

if (qget('poll') === '1') {
    header('Content-Type: application/json');
    if (empty($_SESSION['user'])) { http_response_code(401); echo '{"pending":0}'; exit; }
    echo json_encode(['pending' => job_collect()]);
    exit;
}

if (empty($_SESSION['user'])) {
    $err = '';
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        $wait = rl_wait();
        if ($wait > 0) {
            $err = 'Demasiadas tentativas. Tenta novamente dentro de ' . (int)ceil($wait / 60) . ' min.';
        } elseif (!csrf_ok()) {
            $err = 'A sessão expirou. Tenta novamente.';
        } else {
            $u = post('user');
            $p = post_raw('pass');
            if ($auth !== null && hash_equals((string)($auth['user'] ?? ''), $u) && password_verify($p, (string)($auth['hash'] ?? ''))) {
                rl_clear();
                session_regenerate_id(true);
                $_SESSION['user'] = $u;
                $_SESSION['seen'] = time();
                unset($_SESSION['csrf']);
                go('resumo');
            }
            rl_fail();
            usleep(random_int(300000, 800000));
            $err = 'Utilizador ou password incorretos.';
        }
    }
    render_login($err);
    exit;
}
$_SESSION['seen'] = time();
$myIp = (string)($_SERVER['REMOTE_ADDR'] ?? '');
if ($myIp !== '' && (int)($_SESSION['ipmark'] ?? 0) < time() - 300) {
    $aif = MP_DATA . '/logs/admin-ips.json';
    $aid = jload($aif) ?? [];
    $aid[$myIp] = time();
    foreach ($aid as $k => $v) { if ((int)$v < time() - 7 * 86400) unset($aid[$k]); }
    @file_put_contents($aif, (string)json_encode($aid), LOCK_EX);
    $_SESSION['ipmark'] = time();
}

/* ---------- ações ---------- */
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    if (!csrf_ok()) { flash(false, 'Pedido inválido. Recarrega a página e tenta novamente.'); go($page); }
    $a    = post('a');
    $site = post('site');
    $php  = post('php');
    $db   = post('db');
    $back = [];
    $bad  = function (string $m) { flash(false, $m); };

    switch ($a) {
        case 'sair':
            $_SESSION = [];
            session_destroy();
            header('Location: ./');
            exit;

        case 'refresh':
            job_submit('refresh', [], 'Atualizar estado');
            break;

        case 'site_add':
            $port = post('port');
            if (!valid_site($site)) { $bad('Nome inválido: usa minúsculas, números e "-", a começar por letra (máx. 24).'); $back = ['novo' => 'site']; break; }
            if ($port !== '' && !ctype_digit($port)) { $bad('A porta tem de ser um número.'); $back = ['novo' => 'site']; break; }
            if ($php !== '' && !preg_match(RX_PHP, $php)) { $bad('Versão de PHP inválida.'); $back = ['novo' => 'site']; break; }
            $args = [$site];
            if ($port !== '') array_push($args, '--port', $port);
            if ($php !== '') array_push($args, '--php', $php);
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['novo' => 'site'];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            job_submit('site-add', $args, 'Criar o site ' . $site);
            break;

        case 'site_limits':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            $args = [$site];
            foreach (LIMITS as $k => $L) {
                $v = post($k);
                if (!ctype_digit($v) || (int)$v < $L[1] || (int)$v > $L[2]) {
                    $bad($L[0] . ': indica um valor entre ' . $L[1] . ' e ' . $L[2] . ($L[3] !== '' ? ' ' . $L[3] : '') . '.');
                    $back = ['limites' => $site];
                    break 2;
                }
                array_push($args, $L[4], (string)(int)$v);
            }
            array_push($args, '--display-errors', post('display_errors') === '1' ? '1' : '0');
            job_submit('site-limits', $args, 'Limites do site ' . $site);
            break;

        case 'site_del':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-del', post('keep') === '1' ? [$site, '--keep-files'] : [$site], 'Apagar o site ' . $site);
            break;

        case 'site_php':
            if (!valid_site($site) || !preg_match(RX_PHP, $php)) { $bad('Pedido inválido.'); break; }
            job_submit('site-php', [$site, $php], 'Mudar ' . $site . ' para PHP ' . $php);
            break;

        case 'site_on':
        case 'site_off':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit($a === 'site_on' ? 'site-enable' : 'site-disable', [$site], ($a === 'site_on' ? 'Ativar ' : 'Desativar ') . $site);
            break;

        case 'site_perm':
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            job_submit('site-fixperms', [$site], 'Corrigir permissões de ' . $site);
            break;

        case 'ext_add':
        case 'ext_del':
            $ext = post('ext');
            if (!preg_match(RX_PHP, $php) || !preg_match(RX_EXT, $ext)) { $bad('Pedido inválido.'); break; }
            job_submit($a === 'ext_add' ? 'ext-add' : 'ext-del', [$php, $ext], ($a === 'ext_add' ? 'Instalar ' : 'Remover ') . $ext . ' no PHP ' . $php);
            $back = ['v' => $php];
            break;

        case 'svc':
            $svc = post('svc'); $act = post('act');
            if (!preg_match(RX_SVC, $svc) || !in_array($act, ['reload', 'restart', 'start', 'stop'], true)) { $bad('Pedido inválido.'); break; }
            $names = ['reload' => 'Recarregar', 'restart' => 'Reiniciar', 'start' => 'Iniciar', 'stop' => 'Parar'];
            job_submit('service', [$svc, $act], $names[$act] . ' ' . $svc);
            break;

        case 'bk_now':
            $tg = post('target'); $rm = post('remote');
            if ($tg !== 'all' && !preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $tg)) { $bad('Pedido inválido.'); break; }
            $args = $tg === 'all' ? [] : ['--site', $tg];
            if ($rm !== '' && preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) array_push($args, '--remote', $rm);
            job_submit('backup-start', $args, 'Iniciar backup');
            break;

        case 'bk_restore':
            $bs = post('s'); $bid = post('id'); $what = post('what');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid) || !in_array($what, ['all', 'files', 'db'], true)) { $bad('Pedido inválido.'); break; }
            if (post('ok') !== '1') { $bad('Confirma que compreendes que o conteúdo atual vai ser substituído.'); break; }
            job_submit('bk-restore', [$bs, $bid, '--what', $what], 'Repor backup de ' . ($bs === '_bd' ? 'bases de dados' : $bs));
            break;

        case 'bk_del':
            $bs = post('s'); $bid = post('id');
            if (!preg_match('/^([a-z][a-z0-9-]{0,23}|_bd|_sistema)$/', $bs) || !preg_match('/^\d{8}-\d{6}$/', $bid)) { $bad('Pedido inválido.'); break; }
            job_submit('bk-delete', [$bs, $bid], 'Apagar backup');
            break;

        case 'bk_conf':
            $tm = post('time'); $kd = post('daily'); $kw = post('weekly'); $km = post('monthly'); $rm = post('remote');
            if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $tm)) { $bad('Hora inválida.'); break; }
            foreach ([$kd, $kw, $km] as $v) { if (!ctype_digit($v) || (int)$v > 999) { $bad('Os valores de retenção têm de ser números entre 0 e 999.'); break 2; } }
            if ((int)$kd < 1) { $bad('Guarda pelo menos 1 backup diário.'); break; }
            if ($rm !== 'none' && !preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rm)) $rm = 'none';
            job_submit('bk-conf', [post('on') === 'on' ? '--on' : '--off', '--time', $tm, '--daily', $kd, '--weekly', $kw, '--monthly', $km, '--remote', $rm], 'Agendamento dos backups');
            break;

        case 'bk_remote_add':
            $rn = post('name'); $rt = post('type');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn) || !in_array($rt, ['sftp', 's3', 'rclone'], true)) { $bad('Nome ou tipo inválido.'); break; }
            $args = [$rn, $rt];
            if ($rt === 'sftp') {
                $port = post('port') !== '' ? post('port') : '22';
                if (!ctype_digit($port)) { $bad('Porta inválida.'); break; }
                array_push($args, '--host', post('host'), '--port', $port, '--user', post('user'), '--path', post('path_sftp'));
                if (post_raw('pass') !== '') array_push($args, '--pass', post_raw('pass'));
                if (trim(post_raw('key')) !== '') array_push($args, '--key', str_replace(["\r\n", "\r", "\n"], '\n', trim(post_raw('key'))));
            } elseif ($rt === 's3') {
                array_push($args, '--provider', post('provider'), '--endpoint', post('endpoint'), '--region', post('region'), '--access', post('access'), '--secret', post_raw('secret'), '--bucket', post('bucket'), '--path', post('path_s3'));
            } else {
                $cfg = str_replace(["\r\n", "\r"], "\n", trim(post_raw('config')));
                array_push($args, '--config', str_replace("\n", '\n', $cfg), '--path', post('path_rc'));
            }
            job_submit('bk-remote-add', $args, 'Adicionar destino ' . $rn);
            break;

        case 'bk_remote_test':
        case 'bk_remote_del':
            $rn = post('name');
            if (!preg_match('/^[a-z][a-z0-9-]{1,23}$/', $rn)) { $bad('Destino inválido.'); break; }
            job_submit($a === 'bk_remote_test' ? 'bk-remote-test' : 'bk-remote-del', [$rn], ($a === 'bk_remote_test' ? 'Testar ' : 'Remover ') . $rn, );
            break;

        case 'db_link':
            $ls = post('site');
            if (!preg_match(RX_DB, $db) || ($ls !== 'none' && !valid_site($ls))) { $bad('Pedido inválido.'); break; }
            job_submit('db-link', [$db, $ls], 'Associar ' . $db);
            break;

        case 'cron_save':
            $cid = post('id'); $when = trim(preg_replace('/\s+/', ' ', post('when')) ?? ''); $cmdc = trim(str_replace(["\r", "\n"], ' ', post_raw('cmd')));
            $desc = substr(trim(str_replace(["\r", "\n", '|'], ' ', post_raw('desc'))), 0, 80);
            if (!valid_site($site)) { $bad('Site inválido.'); break; }
            if ($cid !== '' && !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Tarefa inválida.'); break; }
            if (!preg_match('/^(@(hourly|daily|weekly|monthly|yearly|annually)|(\S+ ){4}\S+)$/', $when)) { $bad('Periodicidade inválida.'); break; }
            if ($cmdc === '' || strlen($cmdc) > 2000) { $bad('O comando é obrigatório (até 2000 caracteres).'); break; }
            $args = $cid === '' ? [$site] : [$site, $cid];
            array_push($args, '--when', $when, '--cmd', $cmdc, '--label', $desc);
            job_submit($cid === '' ? 'cron-add' : 'cron-edit', $args, ($cid === '' ? 'Criar tarefa em ' : 'Atualizar tarefa de ') . $site);
            $back = $site !== '' ? ['site' => qget('site')] : [];
            break;

        case 'cron_run':
        case 'cron_on':
        case 'cron_off':
        case 'cron_del':
            $cid = post('id');
            if (!valid_site($site) || !preg_match('/^[a-f0-9]{8}$/', $cid)) { $bad('Pedido inválido.'); break; }
            $map = ['cron_run' => ['cron-run', 'Executar tarefa'], 'cron_on' => ['cron-on', 'Ativar tarefa'], 'cron_off' => ['cron-off', 'Pausar tarefa'], 'cron_del' => ['cron-del', 'Apagar tarefa']];
            job_submit($map[$a][0], [$site, $cid], $map[$a][1] . ' de ' . $site);
            $back = qget('site') !== '' ? ['site' => qget('site')] : [];
            break;

        case 'fw_block':
            $ip = post('ip'); $dur = post('dur');
            if (!valid_net($ip)) { $bad('IP ou rede inválida (ex.: 185.220.101.47 ou 45.148.10.0/24; redes de /8 a /32).'); break; }
            if (!in_array($dur, ['1h', '24h', '7d', 'perm'], true)) $dur = '24h';
            $why = substr(preg_replace('/[^\p{L}\p{N} .,:;()\/_-]/u', '', post('reason')) ?? '', 0, 80);
            job_submit('block', [$ip, '--for', $dur, '--reason', $why, '--protect', $myIp], 'Bloquear ' . $ip);
            break;

        case 'fw_unblock':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP inválido.'); break; }
            job_submit('unblock', [$ip], 'Desbloquear ' . $ip);
            break;

        case 'fw_allow_add':
        case 'fw_allow_del':
            $ip = post('ip');
            if (!valid_net($ip)) { $bad('IP ou rede inválida.'); break; }
            job_submit($a === 'fw_allow_add' ? 'allow-add' : 'allow-del', [$ip], ($a === 'fw_allow_add' ? 'Confiar em ' : 'Deixar de confiar em ') . $ip);
            break;

        case 'fw_auto':
            $lim = post('limit'); $dur = post('dur');
            if (!ctype_digit($lim) || (int)$lim < 10 || (int)$lim > 100000) { $bad('O limite tem de ser um número entre 10 e 100000.'); break; }
            if (!in_array($dur, ['600s', '1h', '24h', '7d'], true)) $dur = '1h';
            job_submit('fw-auto', [post('on') === 'on' ? 'on' : 'off', '--limit', (string)(int)$lim, '--duration', $dur], 'Bloqueio automático');
            break;

        case 'db_add':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Nome inválido: usa minúsculas, números e "_", a começar por letra (máx. 32).'); $back = ['novo' => 'bd']; break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); $back = ['novo' => 'bd']; break; }
            $dsite = post('site');
            $dargs = $pw !== '' ? [$db, $pw] : [$db];
            if ($dsite !== '' && valid_site($dsite)) array_push($dargs, '--site', $dsite);
            job_submit('db-add', $dargs, 'Criar a base de dados ' . $db);
            break;

        case 'db_del':
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            job_submit('db-del', [$db], 'Apagar a base de dados ' . $db);
            break;

        case 'db_admin_pw':
            job_submit('db-admin-passwd', [], 'Password da conta de administração');
            break;

        case 'pma_update':
            job_submit('pma-update', [], 'Atualizar o phpMyAdmin');
            break;

        case 'db_pass':
            $pw = post('pw');
            if (!preg_match(RX_DB, $db)) { $bad('Base de dados inválida.'); break; }
            if ($pw !== '' && !preg_match(RX_PASS, $pw)) { $bad('Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -).'); break; }
            job_submit('db-passwd', $pw !== '' ? [$db, $pw] : [$db], 'Password de ' . $db);
            break;

        case 'conta_pass':
            $cur = post_raw('atual'); $n1 = post_raw('nova'); $n2 = post_raw('repetir');
            if ($auth === null || !password_verify($cur, (string)($auth['hash'] ?? ''))) { $bad('A password atual está incorreta.'); break; }
            if (strlen($n1) < 10) { $bad('A nova password tem de ter pelo menos 10 caracteres.'); break; }
            if ($n1 !== $n2) { $bad('As passwords novas não coincidem.'); break; }
            job_submit('panel-passwd-hash', [password_hash($n1, PASSWORD_BCRYPT)], 'Password do painel');
            break;

        default:
            $bad('Ação desconhecida.');
    }
    go($page, $back);
}

/* ---------- dados para a vista ---------- */
$pending = job_collect();
$state   = jload(MP_STATE) ?? [];
$sites   = is_array($state['sites'] ?? null) ? $state['sites'] : [];
$dbs     = is_array($state['databases'] ?? null) ? $state['databases'] : [];
$phps    = is_array($state['php'] ?? null) ? $state['php'] : [];
$svcs    = is_array($state['service_list'] ?? null) ? $state['service_list'] : [];
$sys     = is_array($state['system'] ?? null) ? $state['system'] : [];
$pma     = is_array($state['pma'] ?? null) ? $state['pma'] : [];
$dbAdmin = is_array($state['db_admin'] ?? null) ? $state['db_admin'] : [];
$pmaOn   = !empty($pma['installed']);
$defPhp  = (string)($state['default_php'] ?? '');
$host    = host_only();
$flashes = is_array($_SESSION['flash'] ?? null) ? $_SESSION['flash'] : [];
unset($_SESSION['flash']);
$jobs    = is_array($_SESSION['jobs'] ?? null) ? $_SESSION['jobs'] : [];
$active  = count(array_filter($sites, function ($s) { return !empty($s['enabled']); }));
$bySite  = [];
foreach ($sites as $s) { $v = (string)($s['php'] ?? ''); $bySite[$v] = ($bySite[$v] ?? 0) + 1; }
$svcDown = count(array_filter($svcs, function ($s) { return empty($s['active']); }));

function php_options(array $phps, string $sel): string {
    $o = '';
    foreach ($phps as $p) {
        $v = (string)($p['version'] ?? '');
        $o .= '<option value="' . h($v) . '"' . ($v === $sel ? ' selected' : '') . '>PHP ' . h($v) . '</option>';
    }
    return $o;
}
function limit_fields(array $L): string {
    $o = '<div class="fgrid">';
    foreach (LIMITS as $k => $d) {
        $o .= '<label class="fld">' . h($d[0]) . ($d[3] !== '' ? ' (' . h($d[3]) . ')' : '')
            . '<input class="in" name="' . h($k) . '" inputmode="numeric" pattern="[0-9]{1,6}" required value="' . (int)$L[$k] . '">'
            . '<small>' . h($d[5]) . ', ' . (int)$d[1] . ' a ' . (int)$d[2] . '</small></label>';
    }
    $o .= '<label class="fld">Mostrar erros no ecrã<select class="in" name="display_errors">'
        . '<option value="0"' . ($L['display_errors'] ? '' : ' selected') . '>Não (produção)</option>'
        . '<option value="1"' . ($L['display_errors'] ? ' selected' : '') . '>Sim (desenvolvimento)</option>'
        . '</select><small>display_errors</small></label></div>';
    return $o;
}
function svc_actions(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? ''); $on = !empty($s['active']); $panel = !empty($s['panel']);
    $btn = function (string $act, string $icon, string $label, string $confirm = '') use ($id) {
        return '<form method="post"' . ($confirm !== '' ? ' data-confirm="' . h($confirm) . '"' : '') . '>' . act_fields('svc', ['svc' => $id, 'act' => $act])
            . '<button class="btn sm sec" type="submit">' . ic($icon) . h($label) . '</button></form>';
    };
    $o = '';
    if ($id === 'nginx') {
        $o .= $btn('reload', 'reload', 'Recarregar');
        $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar o nginx? Os sites e o painel ficam indisponíveis durante 1 a 2 segundos.');
    } elseif ($id === 'mariadb') {
        $o .= $on ? $btn('restart', 'power', 'Reiniciar', 'Reiniciar o MariaDB? Os sites perdem a ligação à base de dados durante alguns segundos.')
                  : $btn('start', 'play', 'Iniciar');
    } else {
        $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
        if ($on) {
            $o .= $btn('reload', 'reload', 'Recarregar');
            $o .= $btn('restart', 'power', 'Reiniciar', 'Reiniciar ' . ($s['name'] ?? '') . '? Os pedidos em curso são interrompidos.');
            if (!$panel) $o .= $btn('stop', 'stop', 'Parar', 'Parar ' . ($s['name'] ?? '') . '? ' . ($n > 0 ? $n . ' site(s) deixam de funcionar até voltares a iniciar.' : 'Nenhum site usa esta versão.'));
        } else {
            $o .= $btn('start', 'play', 'Iniciar');
        }
    }
    return '<div class="svc-acts">' . $o . '</div>';
}
function fmt_bytes(float $b, int $dec = 1): string {
    $u = ['B', 'KB', 'MB', 'GB', 'TB']; $i = 0;
    while ($b >= 1024 && $i < 4) { $b /= 1024; $i++; }
    return number_format($b, $i === 0 ? 0 : $dec, ',', ' ') . ' ' . $u[$i];
}
function fmt_bps(float $b): string {
    $u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s']; $i = 0;
    while ($b >= 1000 && $i < 3) { $b /= 1000; $i++; }
    return number_format($b, $i === 0 ? 0 : 1, ',', ' ') . ' ' . $u[$i];
}
function fmt_int(float $n): string { return number_format($n, 0, ',', ' '); }
function fmt_dec(float $n, int $d = 1): string { return number_format($n, $d, ',', ' '); }
function live_stats(): array {
    $l = jload(MP_STATS . '/live.json') ?? [];
    $l['fresh'] = isset($l['ts']) && time() - (int)$l['ts'] < 30;
    return $l;
}
function tz_off(array $live): int {
    if (!preg_match('/^([+-])(\d{2})(\d{2})$/', (string)($live['tz'] ?? ''), $m)) return 0;
    $s = (int)$m[2] * 3600 + (int)$m[3] * 60;
    return $m[1] === '-' ? -$s : $s;
}
/* Histórico: junta o ficheiro mais grosseiro com os mais finos para o período mais recente */
function hist_load(string $range): array {
    $cfg = [
        '24h' => [86400, [['hist-1m.csv', 60]]],
        '7d'  => [604800, [['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
        '30d' => [2592000, [['hist-1h.csv', 3600], ['hist-10m.csv', 600], ['hist-1m.csv', 60]]],
    ];
    if (!isset($cfg[$range])) $range = '24h';
    $from = time() - $cfg[$range][0];
    $rows = []; $after = 0;
    foreach ($cfg[$range][1] as $fc) {
        $fh = @fopen(MP_STATS . '/' . $fc[0], 'r');
        if ($fh === false) continue;
        $last = $after;
        while (($line = fgets($fh)) !== false) {
            $c = explode(',', trim($line));
            if (count($c) < 8) continue;
            $t = (int)$c[0];
            if ($t < $from || $t < $after) continue;
            $rows[] = array_map('intval', $c);
            if ($t + $fc[1] > $last) $last = $t + $fc[1];
        }
        fclose($fh);
        $after = $last;
    }
    usort($rows, function ($a, $b) { return $a[0] <=> $b[0]; });
    return ['rows' => $rows, 'from' => $from, 'to' => time(), 'range' => $range, 'step' => $cfg[$range][1][0][1]];
}
function downsample(array $rows, int $max): array {
    $n = count($rows);
    if ($n <= $max) return $rows;
    $k = (int)ceil($n / $max); $out = [];
    for ($i = 0; $i < $n; $i += $k) {
        $chunk = array_slice($rows, $i, $k); $m = count($chunk); $avg = $chunk[0];
        for ($c = 1; $c < count($avg); $c++) { $s = 0; foreach ($chunk as $r) $s += $r[$c]; $avg[$c] = $s / $m; }
        $out[] = $avg;
    }
    return $out;
}
function nice_max(float $v): float {
    if ($v <= 0) return 1;
    $e = pow(10, floor(log10($v))); $f = $v / $e;
    $n = $f <= 1 ? 1 : ($f <= 2 ? 2 : ($f <= 2.5 ? 2.5 : ($f <= 5 ? 5 : 10)));
    return $n * $e;
}
function fmt_axis(float $v, string $fmt): string {
    if ($fmt === 'pct') return fmt_int($v) . '%';
    if ($fmt === 'bps') return fmt_bps($v);
    return fmt_dec($v, $v < 10 ? 1 : 0);
}
/* Gráfico de linhas em SVG (sem bibliotecas). $series: [[nome, cor, coluna, divisor]] */
/* Curva suave monótona (Fritsch-Carlson): passa por todos os pontos sem ultrapassá-los */
function smooth_path(array $p, float $lo, float $hi): string {
    $n = count($p);
    if ($n === 0) return '';
    $d = 'M' . $p[0][0] . ' ' . $p[0][1];
    if ($n === 1) return $d . 'h1';
    $dl = []; $m = [];
    for ($i = 0; $i < $n - 1; $i++) { $dx = $p[$i + 1][0] - $p[$i][0]; $dl[$i] = $dx != 0 ? ($p[$i + 1][1] - $p[$i][1]) / $dx : 0; }
    $m[0] = $dl[0]; $m[$n - 1] = $dl[$n - 2];
    for ($i = 1; $i < $n - 1; $i++) $m[$i] = ($dl[$i - 1] * $dl[$i] <= 0) ? 0 : ($dl[$i - 1] + $dl[$i]) / 2;
    for ($i = 0; $i < $n - 1; $i++) {
        if ($dl[$i] == 0) { $m[$i] = 0; $m[$i + 1] = 0; continue; }
        $a = $m[$i] / $dl[$i]; $b = $m[$i + 1] / $dl[$i]; $q = $a * $a + $b * $b;
        if ($q > 9) { $t = 3 / sqrt($q); $m[$i] = $t * $a * $dl[$i]; $m[$i + 1] = $t * $b * $dl[$i]; }
    }
    for ($i = 0; $i < $n - 1; $i++) {
        $h3 = ($p[$i + 1][0] - $p[$i][0]) / 3;
        $c1y = max($lo, min($hi, $p[$i][1] + $m[$i] * $h3));
        $c2y = max($lo, min($hi, $p[$i + 1][1] - $m[$i + 1] * $h3));
        $d .= 'C' . round($p[$i][0] + $h3, 1) . ' ' . round($c1y, 1) . ' ' . round($p[$i + 1][0] - $h3, 1) . ' ' . round($c2y, 1) . ' ' . $p[$i + 1][0] . ' ' . $p[$i + 1][1];
    }
    return $d;
}
function sparkline(array $v): string {
    $n = count($v);
    if ($n < 2) return '';
    $mx = max(1, max($v)); $pts = [];
    foreach (array_values($v) as $i => $x) $pts[] = [round($i * 1000 / ($n - 1), 1), round(112 - ($x / $mx) * 92, 1)];
    $line = smooth_path($pts, 0, 120);
    return '<svg viewBox="0 0 1000 120" preserveAspectRatio="none" aria-hidden="true"><path d="' . $line . 'L1000 120L0 120Z" style="fill:#fff;fill-opacity:.13;stroke:none"/>'
        . '<path d="' . $line . '" style="fill:none;stroke:#fff;stroke-opacity:.9;stroke-width:2.5" vector-effect="non-scaling-stroke"/></svg>';
}
/* Pedidos por hora (24 h) somando todos os sites, e totais por site */
function traffic_24h(array $sites): array {
    $now = time(); $from = $now - 86400;
    $hours = [];
    for ($t = intdiv($from, 3600) * 3600 + 3600; $t <= intdiv($now, 3600) * 3600; $t += 3600) $hours[$t] = 0;
    $per = [];
    foreach ($sites as $s) {
        $n = (string)($s['name'] ?? '');
        if (!valid_site($n)) continue;
        $per[$n] = [0, 0.0];
        $fh = @fopen(MP_STATS . '/traffic/' . $n . '.csv', 'r');
        if ($fh === false) continue;
        while (($l = fgets($fh)) !== false) {
            $c = explode(',', trim($l));
            if (count($c) < 3 || (int)$c[0] < $from - 3599) continue;
            $per[$n][0] += (int)$c[1]; $per[$n][1] += (float)$c[2];
            if (isset($hours[(int)$c[0]])) $hours[(int)$c[0]] += (int)$c[1];
        }
        fclose($fh);
    }
    return ['hours' => $hours, 'per' => $per];
}
function chart_html(array $H, array $series, string $fmt, ?float $ymax = null, ?float $ref = null, int $tz = 0): string {
    $rows = downsample($H['rows'], 480);
    $from = (int)$H['from']; $to = (int)$H['to']; $span = max(1, $to - $from);
    $vals = []; $mx = 0.0;
    foreach ($series as $si => $s) {
        $vals[$si] = [];
        foreach ($rows as $r) { $v = $r[$s[2]] / $s[3]; $vals[$si][] = $v; if ($v > $mx) $mx = $v; }
    }
    if ($ymax === null) $ymax = nice_max(max($mx, (float)($ref ?? 0)) * 1.15);
    $gap = max(180, (int)($H['step'] ?? 60) * 3) * max(1, (int)ceil(count($H['rows']) / 480));
    $svg = '';
    for ($k = 1; $k <= 3; $k++) { $y = 50 * $k; $svg .= '<line class="g" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    if ($ref !== null && $ref < $ymax) { $y = round(200 * (1 - $ref / $ymax), 1); $svg .= '<line class="ref" x1="0" x2="1000" y1="' . $y . '" y2="' . $y . '"/>'; }
    $dots = count($rows) <= 40;
    foreach ($series as $si => $s) {
        $segs = []; $cur = []; $prevT = null;
        foreach ($rows as $i => $r) {
            $pt = [round(($r[0] - $from) / $span * 1000, 1), round(200 * (1 - min($vals[$si][$i], $ymax) / $ymax), 1)];
            if ($prevT !== null && $r[0] - $prevT > $gap) { $segs[] = $cur; $cur = []; }
            $cur[] = $pt; $prevT = $r[0];
        }
        if ($cur) $segs[] = $cur;
        $col = 'stroke:' . $s[1];
        $line = ''; $area = ''; $dotp = '';
        foreach ($segs as $seg) {
            $p = smooth_path($seg, 0, 200);
            $line .= $p;
            if ($si === 0 && count($seg) > 1) $area .= $p . 'L' . $seg[count($seg) - 1][0] . ' 200L' . $seg[0][0] . ' 200Z';
            if ($dots) foreach ($seg as $pt) $dotp .= 'M' . $pt[0] . ' ' . $pt[1] . 'h0.01';
        }
        if ($area !== '') $svg .= '<path class="a" style="fill:' . h($s[1]) . '" d="' . $area . '"/>';
        if ($line !== '') $svg .= '<path class="s" style="' . h($col) . '" d="' . $line . '"/>';
        if ($dotp !== '') $svg .= '<path class="dot" style="' . h($col) . '" d="' . $dotp . '"/>';
    }
    $ylab = '';
    for ($k = 0; $k <= 4; $k++) $ylab .= '<span style="top:' . ($k * 25) . '%">' . h(fmt_axis($ymax * (4 - $k) / 4, $fmt)) . '</span>';
    $xlab = '';
    for ($k = 0; $k <= 6; $k++) {
        $t = (int)($from + $span * $k / 6) + $tz;
        $lab = $H['range'] === '24h' ? gmdate('H:i', $t) : gmdate('d/m', $t);
        $xlab .= '<span' . ($k === 0 ? ' class="first"' : ($k === 6 ? ' class="last"' : '')) . ' style="left:' . round($k * 100 / 6, 3) . '%">' . h($lab) . '</span>';
    }
    $data = ['from' => $from, 'to' => $to, 'tz' => $tz, 'fmt' => $fmt, 't' => array_map(function ($r) { return (int)$r[0]; }, $rows), 's' => []];
    foreach ($series as $si => $s) $data['s'][] = ['n' => $s[0], 'c' => $s[1], 'v' => array_map(function ($v) { return round($v, 2); }, $vals[$si])];
    $empty = count($rows) < 2 ? '<div class="ch-empty">Ainda sem dados suficientes para este período; é gravado um ponto por minuto.</div>' : '';
    return '<div class="chart" data-chart="' . h((string)json_encode($data)) . '"><div class="ch-y">' . $ylab . '</div>'
        . '<div class="ch-plot"><svg viewBox="0 0 1000 200" preserveAspectRatio="none" aria-hidden="true">' . $svg . '</svg>'
        . '<div class="ch-cur"></div><div class="ch-tip"></div>' . $empty . '</div><div class="ch-x">' . $xlab . '</div></div>';
}
function legend(array $series): string {
    $o = '<div class="legend">';
    foreach ($series as $s) $o .= '<span><i style="background:' . h($s[1]) . '"></i>' . h($s[0]) . '</span>';
    return $o . '</div>';
}

function svc_usage(array $s, array $bySite): string {
    $id = (string)($s['id'] ?? '');
    if ($id === 'nginx') return 'Servidor web dos sites e do painel';
    if ($id === 'mariadb') return 'Bases de dados (apenas localhost)';
    $n = (int)($bySite[(string)($s['version'] ?? '')] ?? 0);
    $t = $n === 0 ? 'Nenhum site' : ($n === 1 ? '1 site' : $n . ' sites');
    return !empty($s['panel']) ? $t . ' e o próprio painel' : $t;
}

$titles = [
    'resumo'   => $sys ? trim(($sys['hostname'] ?? '') . ' · ' . ($sys['ip'] ?? '') . ' · ' . ($sys['os'] ?? '') . ' · ativo há ' . fmt_uptime((int)($sys['uptime'] ?? 0)), ' ·') : 'Estado do servidor',
    'sites'    => 'Cada site tem a sua porta e fica acessível por IP ou localhost.',
    'bd'       => 'O utilizador tem o mesmo nome da base de dados. Servidor localhost, porta 3306.',
    'php'      => 'Versões instaladas e extensões de cada versão.',
    'servicos' => 'Estado dos serviços e ações de manutenção.',
    'conta'    => 'Acesso ao painel.',
    'recursos' => 'Utilização do servidor e de cada site, atualizada a cada 5 segundos.',
    'ficheiros'=> 'Ficheiros de cada site, geridos com o utilizador do próprio site.',
    'ligacoes' => 'Ligações abertas a este servidor, bloqueio de IPs e bloqueio automático.',
    'cron'     => 'Tarefas agendadas (cron) de cada site, como no cPanel.',
    'backups'  => 'Backups dos sites e das bases de dados, locais e remotos.',
];
$groups = ['Geral' => ['resumo', 'recursos'], 'Alojamento' => ['sites', 'ficheiros', 'cron', 'bd', 'php'], 'Sistema' => ['servicos', 'ligacoes', 'backups', 'conta']];
$section = 'Geral';
foreach ($groups as $gl => $keys) { if (in_array($page, $keys, true)) $section = $gl; }
$lvTop = live_stats();
$today = gmdate('d/m/Y', time() + tz_off($lvTop));
$openOnLoad = '';
if (qget('novo') === 'site') $openOnLoad = 'dlg-site-new';
elseif (qget('novo') === 'bd') $openOnLoad = 'dlg-db-new';
elseif (qget('limites') !== '' && valid_site(qget('limites'))) $openOnLoad = 'dlg-lim-' . qget('limites');
?>
<!doctype html>
<html lang="pt-PT">
<head><?= mp_head($pages[$page][0]) ?></head>
<body data-pending="<?= (int)$pending ?>" data-autoopen="<?= h($openOnLoad) ?>">
<noscript><?php if ($pending > 0): ?><meta http-equiv="refresh" content="3"><?php endif; ?><div style="padding:10px 16px;background:#fdf1dc;color:#9a5b08">O painel precisa de JavaScript para as janelas e menus.</div></noscript>
<div class="app">
  <aside class="side" id="side">
    <a class="brand" href="?p=resumo" aria-label="IDDigital Hosting — Resumo"><?= brand_logo() ?></a>
    <nav class="nav">
      <?php foreach ($groups as $gl => $keys): ?>
        <div class="nav-sec"><?= h($gl) ?></div>
        <?php foreach ($keys as $k): $pd = $pages[$k]; ?>
          <a href="?p=<?= h($k) ?>"<?= $k === $page ? ' class="on" aria-current="page"' : '' ?>><?= ic($pd[1]) ?><?= h($pd[0]) ?></a>
          <?php if ($k === 'bd' && $pmaOn): ?><a href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('table') ?>phpMyAdmin<?= ic('ext', 'tail') ?></a><?php endif; ?>
        <?php endforeach; ?>
      <?php endforeach; ?>
    </nav>
    <div class="side-foot">IDDigital Hosting v<?= h(MP_VERSION) ?></div>
  </aside>
  <div class="scrim" data-nav-close></div>

  <div class="main">
    <header class="top">
      <button class="iconbtn burger" type="button" data-nav-open aria-label="Abrir menu"><?= ic('menu') ?></button>
      <div class="grow">
        <div class="crumb"><?= h($section) ?></div>
        <h1><?= h($pages[$page][0]) ?></h1>
        <p><?= h($titles[$page]) ?></p>
      </div>
      <div class="top-actions">
        <?php if ($page === 'sites' || $page === 'resumo'): ?>
          <button class="chip prim" type="button" data-open="dlg-site-new" aria-label="Novo site"><?= ic('plus') ?><span class="lbl">Novo site</span></button>
        <?php elseif ($page === 'bd'): ?>
          <button class="chip prim" type="button" data-open="dlg-db-new" aria-label="Nova base de dados"><?= ic('plus') ?><span class="lbl">Nova base de dados</span></button>
        <?php elseif ($page === 'cron' && $sites): ?>
          <button class="chip prim" type="button" data-cron-new aria-label="Nova tarefa"><?= ic('plus') ?><span class="lbl">Nova tarefa</span></button>
        <?php elseif ($page === 'backups'): ?>
          <button class="chip prim" type="button" data-open="dlg-bk-now" aria-label="Fazer backup agora"><?= ic('archive') ?><span class="lbl">Fazer backup</span></button>
        <?php elseif ($page === 'ligacoes'): ?>
          <button class="chip prim" type="button" data-open="dlg-block" aria-label="Bloquear IP"><?= ic('ban') ?><span class="lbl">Bloquear IP</span></button>
        <?php endif; ?>
        <form method="post" style="margin:0"><?= act_fields('refresh') ?><button class="chip" type="submit" title="Atualizar estado" aria-label="Atualizar estado"><?= ic('reload') ?><span class="lbl">Atualizar</span></button></form>
        <span class="chip sm hide-m">v<?= h(MP_VERSION) ?></span>
        <span class="chip ghost hide-m"><?= h($today) ?></span>
        <button class="chip icon" type="button" data-theme-toggle title="Mudar tema" aria-label="Mudar tema"><?= ic('moon') ?></button>
        <details class="dd me">
          <summary class="chip" aria-label="Conta"><span class="av-me"><?= h(substr((string)$_SESSION['user'], 0, 1)) ?></span><span class="lbl"><?= h($_SESSION['user']) ?></span><?= ic('chev', 'chev') ?></summary>
          <div class="dd-menu">
            <a href="?p=conta"><?= ic('user') ?>Conta e password</a>
            <hr>
            <form method="post"><?= act_fields('sair') ?><button type="submit"><?= ic('out') ?>Sair</button></form>
          </div>
        </details>
      </div>
    </header>

    <main class="content">
<?php if (!$state): ?>
      <div class="card"><div class="empty"><b>O estado do servidor ainda não está disponível</b>Carrega em atualizar, no canto superior direito, ou corre <span class="mono">mpanel state</span> no servidor para ver o erro.</div></div>
<?php endif; ?>

<?php if ($page === 'resumo'):
    $lv = live_stats();
    $disk = (int)round($lv['fresh'] ? (float)($lv['disk']['pct'] ?? 0) : (float)($sys['disk'] ?? 0));
    $ram  = (int)round($lv['fresh'] ? (float)($lv['mem']['pct'] ?? 0) : (float)($sys['ram'] ?? 0));
    $hot  = $disk >= 90 || $ram >= 90;
    $H24  = hist_load('24h');
    $tr   = traffic_24h($sites);
    $reqTot = 0; $byTot = 0.0;
    foreach ($tr['per'] as $pv) { $reqTot += $pv[0]; $byTot += $pv[1]; }
    $reqMax = 1;
    foreach ($tr['per'] as $pv) $reqMax = max($reqMax, $pv[0]);
    $sorted = $sites;
    usort($sorted, function ($x, $y) use ($tr) { return ($tr['per'][$y['name'] ?? ''][0] ?? 0) <=> ($tr['per'][$x['name'] ?? ''][0] ?? 0); }); ?>
      <div class="hero">
        <section class="card">
          <div class="card-h"><div><h2>Utilização do servidor</h2><p>CPU e memória nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=recursos">Ver recursos</a></div>
          <?= chart_html($H24, [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10]], 'pct', 100, null, tz_off($lv)) ?>
        </section>
        <section class="hl">
          <div class="k">Pedidos nas últimas 24 horas</div>
          <div class="v"><?= h(fmt_int($reqTot)) ?></div>
          <div class="s"><?= h(fmt_bytes($byTot)) ?> transferidos · <?= $active ?> de <?= count($sites) ?> sites ativos</div>
          <?= sparkline(array_values($tr['hours'])) ?>
        </section>
      </div>

      <section class="stats">
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Sites ativos</div><div class="v"><?= $active ?> <small>de <?= count($sites) ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('db') ?></span><div><div class="k">Bases de dados</div><div class="v"><?= count($dbs) ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('code') ?></span><div><div class="k">Versões de PHP</div><div class="v"><?= count($phps) ?> <small><?= $defPhp !== '' ? 'predefinida ' . h($defPhp) : '' ?></small></div></div></div>
        <a class="stat<?= $hot ? ' hot' : '' ?>" href="?p=recursos"><span class="tile t-warn"><?= ic('cpu') ?></span><div><div class="k">Disco e memória<?= $hot ? ' · atenção' : '' ?></div><div class="v"><?= $disk ?>% <small>disco · <?= $ram ?>% RAM</small></div><div class="meter"><i class="<?= $disk >= 90 ? 'hi' : '' ?>" style="width:<?= max(0, min(100, $disk)) ?>%"></i></div></div></a>
      </section>

      <div class="grid2">
        <section class="card">
          <div class="card-h"><div><h2>Sites</h2><p>Pedidos nas últimas 24 horas</p></div><a class="chip sm soft" href="?p=sites">Ver todos</a></div>
          <?php if (!$sites): ?>
            <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
          <?php else: ?>
          <div class="row-list bars">
            <?php foreach (array_slice($sorted, 0, 8) as $s): $n = (string)$s['name']; $port = (int)$s['port']; $on = !empty($s['enabled']); $rq = (int)($tr['per'][$n][0] ?? 0); ?>
              <div class="item">
                <div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu"><span class="mono">:<?= $port ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div>
                <div class="bar"><i style="width:<?= round($rq * 100 / $reqMax, 1) ?>%"></i></div>
                <b class="num"><?= h(fmt_int($rq)) ?></b>
                <span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span>
                <?php if ($on): ?><a class="iconbtn" href="<?= h(site_url($host, $port)) ?>" target="_blank" rel="noopener" title="Abrir" aria-label="Abrir <?= h($n) ?>"><?= ic('ext') ?></a><?php else: ?><span></span><?php endif; ?>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Serviços</h2><p>Estado atual</p></div><?php if ($svcDown > 0): ?><span class="pill p-err"><?= $svcDown ?> parado<?= $svcDown === 1 ? '' : 's' ?></span><?php else: ?><a class="chip sm soft" href="?p=servicos">Gerir</a><?php endif; ?></div>
          <div class="row-list">
            <?php foreach ($svcs as $s): $on = !empty($s['active']); ?>
              <div class="item">
                <span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span>
                <div class="grow nm"><?= h($s['name'] ?? '') ?></div>
                <?php if (($s['id'] ?? '') === 'nginx' || ($s['id'] ?? '') === 'mariadb' || !$on): ?>
                  <?= svc_actions($s, $bySite) ?>
                <?php else: ?>
                  <form method="post" style="margin:0"><?= act_fields('svc', ['svc' => (string)$s['id'], 'act' => 'reload']) ?><button class="btn sm sec" type="submit"><?= ic('reload') ?>Recarregar</button></form>
                <?php endif; ?>
              </div>
            <?php endforeach; ?>
            <?php if (!$svcs): ?><div class="empty">Sem informação dos serviços.</div><?php endif; ?>
          </div>
        </section>
      </div>

<?php elseif ($page === 'sites'): ?>
      <section class="card">
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>Cria o primeiro; fica logo acessível numa porta própria.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th>Endereço</th><th>PHP</th><th>Limites</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($sites as $s):
                $n = (string)($s['name'] ?? ''); $port = (int)($s['port'] ?? 0); $on = !empty($s['enabled']); $L = site_limits($s);
                $url = site_url($host, $port); ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div style="min-width:0"><div class="nm"><?= h($n) ?></div><div class="mu mono"><?= h($s['root'] ?? '') ?></div></div></div></td>
              <td data-label="Endereço">
                <div class="links"><span class="port">:<?= $port ?></span>
                <?php if ($on): ?> <a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= h(preg_replace('#^http://|/$#', '', $url)) ?><?= ic('ext') ?></a><?php endif; ?></div>
              </td>
              <td data-label="PHP"><?= h($s['php'] ?? '') ?></td>
              <td data-label="Limites"><div class="lim"><span><b><?= (int)$L['memory'] ?></b> MB</span><span>upload <b><?= (int)$L['upload'] ?></b> MB</span><span><b><?= (int)$L['exec'] ?></b> s</span></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativo' : 'Desativado' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($on): ?><a href="<?= h($url) ?>" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir site</a><?php endif; ?>
                    <a href="?p=ficheiros&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('folder') ?>Ficheiros</a>
                    <a href="?p=cron&amp;site=<?= h(rawurlencode($n)) ?>"><?= ic('clock') ?>Tarefas agendadas</a>
                    <button type="button" data-open="dlg-lim-<?= h($n) ?>"><?= ic('sliders') ?>Limites</button>
                    <button type="button" data-open="dlg-php-<?= h($n) ?>"><?= ic('code') ?>Mudar versão de PHP</button>
                    <form method="post"><?= act_fields('site_perm', ['site' => $n]) ?><button type="submit"><?= ic('lock') ?>Corrigir permissões</button></form>
                    <form method="post"><?= act_fields($on ? 'site_off' : 'site_on', ['site' => $n]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Desativar' : 'Ativar' ?></button></form>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-del-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'recursos'):
    $live = live_stats();
    $tz = tz_off($live);
    $range = in_array(qget('r'), ['24h', '7d', '30d'], true) ? qget('r') : '24h';
    $H = hist_load($range);
    $sj = jload(MP_STATS . '/sites.json') ?? [];
    $sjs = is_array($sj['sites'] ?? null) ? $sj['sites'] : [];
    $ls = is_array($live['sites'] ?? null) ? $live['sites'] : [];
    $ncpu = max(1, (int)($live['cpus'] ?? ($sys['cpus'] ?? 1)));
    $mem = is_array($live['mem'] ?? null) ? $live['mem'] : [];
    $dsk = is_array($live['disk'] ?? null) ? $live['disk'] : [];
    $swp = is_array($live['swap'] ?? null) ? $live['swap'] : [];
    $load = is_array($live['load'] ?? null) ? $live['load'] : [0, 0, 0];
    $net = is_array($live['net'] ?? null) ? $live['net'] : [];
    $sCpu = [['CPU', 'var(--c1)', 1, 10], ['Memória', 'var(--c2)', 2, 10], ['Swap', 'var(--c3)', 3, 10]];
    $sNet = [['Receção', 'var(--c1)', 6, 1], ['Envio', 'var(--c2)', 7, 1]];
    $sLoad = [['Carga (1 min)', 'var(--c3)', 5, 100]];
    $pills = '<div class="pills">';
    foreach (['24h' => '24 h', '7d' => '7 dias', '30d' => '30 dias'] as $rk => $rl) $pills .= '<a class="' . ($rk === $range ? 'on' : '') . '" href="?p=recursos&amp;r=' . $rk . '">' . $rl . '</a>';
    $pills .= '</div>';
?>
      <?php if (!$live['fresh']): ?>
        <div class="card"><div class="empty"><b>O recolhedor de estatísticas não está a responder</b>No servidor: <span class="mono">systemctl status minipainel-stats</span></div></div>
      <?php endif; ?>
      <section class="stats stats5" data-live>
        <div class="stat"><span class="tile t-acc"><?= ic('cpu') ?></span><div><div class="k">CPU (<?= $ncpu ?> vCPU)</div><div class="v" data-l="cpu"><?= h(fmt_dec((float)($live['cpu'] ?? 0))) ?>%</div><div class="meter"><i data-lm="cpu" style="width:<?= min(100, (float)($live['cpu'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('server') ?></span><div><div class="k">Memória</div><div class="v"><span data-l="mem"><?= h(fmt_dec((float)($mem['pct'] ?? 0))) ?>%</span> <small data-l="mem-sub"><?= h(fmt_bytes((float)($mem['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($mem['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="mem" style="width:<?= min(100, (float)($mem['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('db') ?></span><div><div class="k">Disco /</div><div class="v"><span data-l="disk"><?= h(fmt_dec((float)($dsk['pct'] ?? 0))) ?>%</span> <small data-l="disk-sub"><?= h(fmt_bytes((float)($dsk['used'] ?? 0) * 1024) . ' / ' . fmt_bytes((float)($dsk['total'] ?? 0) * 1024)) ?></small></div><div class="meter"><i data-lm="disk" style="width:<?= min(100, (float)($dsk['pct'] ?? 0)) ?>%"></i></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('pulse') ?></span><div><div class="k">Carga</div><div class="v"><span data-l="load"><?= h(fmt_dec((float)($load[0] ?? 0), 2)) ?></span> <small data-l="load-sub">5 min <?= h(fmt_dec((float)($load[1] ?? 0), 2)) ?> · 15 min <?= h(fmt_dec((float)($load[2] ?? 0), 2)) ?></small></div><div class="mu" data-l="swap">Swap <?= h(fmt_dec((float)($swp['pct'] ?? 0))) ?>%</div></div></div>
        <div class="stat"><span class="tile t-acc"><?= ic('world') ?></span><div><div class="k">Rede</div><div class="v" data-l="net"><?= h(fmt_bps((float)($net['rx'] ?? 0) + (float)($net['tx'] ?? 0))) ?></div><div class="mu" data-l="net-sub">↓ <?= h(fmt_bps((float)($net['rx'] ?? 0))) ?> · ↑ <?= h(fmt_bps((float)($net['tx'] ?? 0))) ?></div></div></div>
      </section>

      <section class="card">
        <div class="card-h"><h2>CPU, memória e swap</h2><?= legend($sCpu) ?><?= $pills ?></div>
        <?= chart_html($H, $sCpu, 'pct', 100, null, $tz) ?>
      </section>

      <div class="grid2e">
        <section class="card">
          <div class="card-h"><h2>Rede</h2><?= legend($sNet) ?></div>
          <?= chart_html($H, $sNet, 'bps', null, null, $tz) ?>
        </section>
        <section class="card">
          <div class="card-h"><h2>Carga do sistema</h2><div class="legend"><span><i style="background:var(--c3)"></i>Carga (1 min)</span><span><i class="dash"></i><?= $ncpu ?> vCPU</span></div></div>
          <?= chart_html($H, $sLoad, 'load', null, (float)$ncpu, $tz) ?>
        </section>
      </div>

      <section class="card">
        <div class="card-h"><h2>Consumo por site</h2><p>CPU e RAM em tempo real; tráfego das últimas 24 horas.</p></div>
        <?php if (!$sites): ?>
          <div class="empty">Ainda não há sites.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Site</th><th class="r">CPU</th><th class="r">RAM</th><th class="r">Disco</th><th class="r">Pedidos (24 h)</th><th class="r">Tráfego (24 h)</th></tr></thead>
          <tbody>
          <?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); $L = $ls[$n] ?? []; $J = $sjs[$n] ?? []; ?>
            <tr>
              <td class="first" data-label="Site"><div class="who"><span class="av <?= tone($n) ?>"><?= h(substr($n, 0, 1)) ?></span><div><div class="nm"><?= h($n) ?></div><div class="mu"><span class="mono">:<?= (int)($s['port'] ?? 0) ?></span> · PHP <?= h($s['php'] ?? '') ?></div></div></div></td>
              <td class="r" data-label="CPU" data-ls="<?= h($n) ?>:cpu"><?= h(fmt_dec((float)($L['cpu'] ?? 0))) ?>%</td>
              <td class="r" data-label="RAM" data-ls="<?= h($n) ?>:rss"><?= h(fmt_bytes((float)($L['rss'] ?? 0) * 1024)) ?></td>
              <td class="r" data-label="Disco"><?= isset($J['disk']) && (int)($sj['disk_ts'] ?? 0) > 0 ? h(fmt_bytes((float)$J['disk'])) : '<span class="mu">a medir…</span>' ?></td>
              <td class="r" data-label="Pedidos (24 h)"><?= h(fmt_int((float)($J['req24'] ?? 0))) ?></td>
              <td class="r" data-label="Tráfego (24 h)"><?= h(fmt_bytes((float)($J['bytes24'] ?? 0))) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">CPU em percentagem da capacidade total do servidor. A RAM é aproximada (inclui memória partilhada entre processos). O disco de cada site é medido de hora a hora; as bases de dados não estão incluídas.</div>
      </section>

<?php elseif ($page === 'ficheiros'):
    $names = [];
    foreach ($sites as $s) { $n = (string)($s['name'] ?? ''); if (valid_site($n)) $names[] = $n; }
    $fmSite = in_array(qget('site'), $names, true) ? qget('site') : ($names[0] ?? '');
?>
      <?php if (!$names): ?>
        <section class="card"><div class="empty"><b>Ainda não há sites</b>Cria um site para poderes gerir os ficheiros dele.<br><button class="btn" type="button" data-open="dlg-site-new"><?= ic('plus') ?>Novo site</button></div></section>
      <?php else: ?>
      <section class="card fm" id="fm" data-site="<?= h($fmSite) ?>" data-dir="<?= h(qget('dir')) ?>">
        <div class="fm-bar">
          <select class="in fm-site" id="fm-site" aria-label="Site">
            <?php foreach ($names as $n): ?><option value="<?= h($n) ?>"<?= $n === $fmSite ? ' selected' : '' ?>><?= h($n) ?></option><?php endforeach; ?>
          </select>
          <nav class="crumbs" id="fm-crumbs" aria-label="Caminho"></nav>
          <div class="fm-tools">
            <button class="btn sm sec" type="button" data-fm="mkdir"><?= ic('folderplus') ?>Nova pasta</button>
            <button class="btn sm sec" type="button" data-fm="newfile"><?= ic('file') ?>Novo ficheiro</button>
            <label class="btn sm sec"><?= ic('upload') ?>Enviar pasta<input type="file" id="fm-updir" webkitdirectory multiple hidden></label>
            <label class="btn sm"><?= ic('upload') ?>Enviar ficheiros<input type="file" id="fm-upfiles" multiple hidden></label>
          </div>
        </div>
        <div class="fm-selbar" id="fm-selbar" hidden>
          <span id="fm-selcount"></span><span class="grow"></span>
          <button class="btn sm sec" type="button" data-fm="move"><?= ic('move') ?>Mover</button>
          <button class="btn sm sec" type="button" data-fm="zip"><?= ic('zip') ?>Compactar</button>
          <button class="btn sm sec" type="button" data-fm="chmod"><?= ic('lock') ?>Permissões</button>
          <button class="btn sm dan" type="button" data-fm="delete"><?= ic('trash') ?>Apagar</button>
          <button class="btn sm sec" type="button" data-fm="clear">Limpar seleção</button>
        </div>
        <div class="fm-drop" id="fm-drop">
          <table class="list cards fm-list">
            <thead><tr><th><label class="fm-ck"><input type="checkbox" id="fm-all" aria-label="Selecionar tudo"></label> Nome</th><th class="r">Tamanho</th><th>Modificado</th><th>Permissões</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
            <tbody id="fm-rows"><tr><td colspan="5" class="empty">A carregar…</td></tr></tbody>
          </table>
          <div class="fm-hint">Larga aqui para enviar para esta pasta</div>
        </div>
        <div class="card-f mu" id="fm-foot">Arrasta ficheiros ou pastas para a lista para os enviar. Os envios são feitos por partes e retomam se a ligação falhar.</div>
      </section>
      <div class="fm-menu" id="fm-menu" hidden></div>
      <div class="ups" id="fm-ups" hidden>
        <div class="ups-h"><b>Envios</b><span id="fm-ups-sum"></span><button class="iconbtn" type="button" id="fm-ups-close" aria-label="Fechar"><?= ic('x') ?></button></div>
        <div class="ups-l" id="fm-ups-list"></div>
      </div>
      <dialog id="fm-dlg">
        <form method="dialog">
          <div class="dlg-h"><h3 id="fm-dlg-t"></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b"><div id="fm-dlg-msg" class="mu"></div><input class="in" id="fm-dlg-in" autocomplete="off"></div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" id="fm-dlg-ok" value="ok">OK</button></div>
        </form>
      </dialog>
      <dialog class="drawer fm-ed" id="fm-ed" data-keep>
        <div class="dlg-h"><div style="min-width:0"><h3>Editar ficheiro</h3><p class="mono" id="fm-ed-t"></p></div><button class="iconbtn" type="button" id="fm-ed-x" aria-label="Fechar"><?= ic('x') ?></button></div>
        <textarea id="fm-ed-ta" spellcheck="false" autocapitalize="off" autocomplete="off" aria-label="Conteúdo do ficheiro"></textarea>
        <div class="dlg-f"><span class="mu" id="fm-ed-st"></span><button class="btn sec" type="button" id="fm-ed-close">Fechar</button><button class="btn" type="button" id="fm-ed-save">Gravar (Ctrl+S)</button></div>
      </dialog>
      <?php endif; ?>

<?php elseif ($page === 'bd'): ?>
      <section class="card">
        <div class="row-list">
          <div class="item">
            <span class="av t-acc"><?= ic('table') ?></span>
            <div class="grow"><div class="nm">phpMyAdmin</div><div class="mu"><?= $pmaOn ? 'Versão ' . h($pma['version'] ?? '') . '. Só abre com sessão iniciada neste painel; o login é feito com um utilizador da base de dados.' : 'Não está instalado. Instala a versão oficial mais recente.' ?></div></div>
            <div class="svc-acts">
              <?php if ($pmaOn): ?><a class="btn sm" href="/phpmyadmin/" target="_blank" rel="noopener"><?= ic('ext') ?>Abrir phpMyAdmin</a><?php endif; ?>
              <form method="post"><?= act_fields('pma_update') ?><button class="btn sm sec" type="submit"><?= ic('reload') ?><?= $pmaOn ? 'Procurar atualização' : 'Instalar' ?></button></form>
            </div>
          </div>
          <div class="item">
            <span class="av t-warn"><?= ic('shield') ?></span>
            <div class="grow"><div class="nm mono"><?= h($dbAdmin['user'] ?? 'mpadmin') ?>@localhost</div><div class="mu">Conta de administração com acesso a todas as bases de dados. Só funciona a partir do próprio servidor, por exemplo no phpMyAdmin.</div></div>
            <div class="svc-acts">
              <form method="post" data-confirm="<?= !empty($dbAdmin['exists']) ? h('Gerar uma nova password para a conta de administração? A password atual deixa de funcionar.') : '' ?>"><?= act_fields('db_admin_pw') ?><button class="btn sm sec" type="submit"><?= ic('key') ?><?= !empty($dbAdmin['exists']) ? 'Gerar nova password' : 'Criar conta' ?></button></form>
            </div>
          </div>
        </div>
      </section>

      <section class="card">
        <?php if (!$dbs): ?>
          <div class="empty"><b>Ainda não há bases de dados</b>Cada base de dados é criada com um utilizador próprio.<br><button class="btn" type="button" data-open="dlg-db-new"><?= ic('plus') ?>Nova base de dados</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Base de dados</th><th>Utilizador</th><th>Site</th><th class="r">Tamanho</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($dbs as $d): $n = (string)($d['name'] ?? ''); ?>
            <tr>
              <td class="first" data-label="Base de dados"><div class="who"><span class="av t-blue"><?= ic('db') ?></span><div class="nm mono"><?= h($n) ?></div></div></td>
              <td class="mono" data-label="Utilizador"><?= h($n) ?>@localhost</td>
              <td data-label="Site"><?= ($d['site'] ?? '') !== '' ? '<span class="pill p-me">' . h($d['site']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="r" data-label="Tamanho"><?= h(number_format((float)($d['size_mb'] ?? 0), 2, ',', ' ')) ?> MB</td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações de <?= h($n) ?>"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($pmaOn): ?><a href="/phpmyadmin/index.php?route=/database/structure&amp;db=<?= h(rawurlencode($n)) ?>" target="_blank" rel="noopener"><?= ic('table') ?>Abrir no phpMyAdmin</a><?php endif; ?>
                    <button type="button" data-open="dlg-dblink-<?= h($n) ?>"><?= ic('world') ?>Associar a um site</button>
                    <button type="button" data-open="dlg-dbpw-<?= h($n) ?>"><?= ic('key') ?>Mudar password</button>
                    <hr>
                    <button type="button" class="dan" data-open="dlg-dbdel-<?= h($n) ?>"><?= ic('trash') ?>Apagar</button>
                  </div>
                </details>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

<?php elseif ($page === 'php'):
    $selV = qget('v') !== '' ? qget('v') : $defPhp;
    $sel = null;
    foreach ($phps as $p) { if ((string)($p['version'] ?? '') === $selV) $sel = $p; }
    if ($sel === null && $phps) $sel = $phps[0];
    $sv = $sel !== null ? (string)($sel['version'] ?? '') : '';
?>
      <section class="card">
        <div class="card-h"><h2>Versões instaladas</h2><p>Para acrescentar versões, volta a correr o instalador com --php.</p></div>
        <?php if (!$phps): ?>
          <div class="empty">Sem informação sobre versões de PHP.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Versão</th><th>Serviço</th><th class="r">Sites</th><th class="r">Extensões opcionais</th><th>Predefinida</th></tr></thead>
          <tbody>
          <?php foreach ($phps as $p): $v = (string)($p['version'] ?? '');
                $ni = count(array_filter(is_array($p['extensions'] ?? null) ? $p['extensions'] : [], function ($e) { return !empty($e['installed']); })); ?>
            <tr>
              <td class="first" data-label="Versão"><div class="who"><span class="av t-vio"><?= ic('code') ?></span><a class="nm" href="?p=php&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a></div></td>
              <td data-label="Serviço"><span class="pill <?= !empty($p['active']) ? 'p-ok' : 'p-err' ?>"><?= !empty($p['active']) ? 'A correr' : 'Parado' ?></span></td>
              <td class="r" data-label="Sites"><?= (int)($bySite[$v] ?? 0) ?></td>
              <td class="r" data-label="Extensões opcionais"><?= $ni ?></td>
              <td data-label="Predefinida"><?= $v === $defPhp ? 'Sim' : 'Não' ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
      </section>

      <?php if ($sel !== null):
            $exts = is_array($sel['extensions'] ?? null) ? $sel['extensions'] : [];
            $mods = is_array($sel['modules'] ?? null) ? $sel['modules'] : []; ?>
      <section class="card">
        <div class="card-h">
          <h2>Extensões do PHP <?= h($sv) ?></h2>
          <div class="pills"><?php foreach ($phps as $p): $v = (string)($p['version'] ?? ''); ?><a class="<?= $v === $sv ? 'on' : '' ?>" href="?p=php&amp;v=<?= h(rawurlencode($v)) ?>">PHP <?= h($v) ?></a><?php endforeach; ?></div>
        </div>
        <?php $ns = (int)($bySite[$sv] ?? 0); ?>
        <p class="lead">Aplicam-se a todos os sites com PHP <?= h($sv) ?> (<?= $ns ?> site<?= $ns === 1 ? '' : 's' ?>). Instalar ou remover pode demorar alguns minutos.</p>
        <?php if (!$exts): ?>
          <div class="empty">Sem informação sobre extensões.</div>
        <?php else: ?>
        <div class="exts">
          <?php foreach ($exts as $e): $x = (string)($e['name'] ?? ''); $inst = !empty($e['installed']); ?>
            <div class="ext<?= $inst ? ' on' : '' ?>">
              <div class="d"><b><?= h($x) ?></b><span><?= h($e['desc'] ?? '') ?></span></div>
              <form method="post"<?= $inst ? ' data-confirm="' . h('Remover a extensão ' . $x . ' do PHP ' . $sv . '?') . '"' : '' ?>>
                <?= act_fields($inst ? 'ext_del' : 'ext_add', ['php' => $sv, 'ext' => $x]) ?>
                <?php if ($inst): ?><span class="pill p-ok">Instalada</span><?php endif; ?>
                <button class="btn sm sec" type="submit"><?= $inst ? 'Remover' : 'Instalar' ?></button>
              </form>
            </div>
          <?php endforeach; ?>
        </div>
        <?php endif; ?>
        <?php if ($mods): ?>
          <div class="card-f"><div class="mu" style="margin-bottom:8px">Módulos carregados (<?= count($mods) ?>)</div><div class="chips"><?php foreach ($mods as $m): ?><span class="chip"><?= h($m) ?></span><?php endforeach; ?></div></div>
        <?php endif; ?>
      </section>
      <?php endif; ?>

<?php elseif ($page === 'ligacoes'):
    $cj = jload(MP_STATS . '/conns.json') ?? [];
    $fw = jload(MP_STATS . '/fw.json') ?? [];
    $fwAuto = is_array($fw['auto'] ?? null) ? $fw['auto'] : ['on' => false, 'limit' => 150, 'duration' => 3600];
    $fwBlocks = array_values(array_filter(is_array($fw['blocks'] ?? null) ? $fw['blocks'] : [], function ($b) { return (int)($b['exp'] ?? 0) === 0 || (int)$b['exp'] > time(); }));
    $fwAllow = is_array($fw['allow'] ?? null) ? $fw['allow'] : [];
    $portLabels = [];
    foreach ($sites as $s) $portLabels[(string)(int)($s['port'] ?? 0)] = (string)($s['name'] ?? '');
    $portLabels[(string)(int)($sys['panel_port'] ?? 2443)] = 'Painel';
    $portLabels += ['22' => 'SSH', '3306' => 'MariaDB', '80' => 'HTTP', '443' => 'HTTPS'];
    $durs = ['600s' => '10 minutos', '1h' => '1 hora', '24h' => '24 horas', '7d' => '7 dias'];
    $curDur = (int)($fwAuto['duration'] ?? 3600);
    $tzl = tz_off(live_stats());
?>
      <?php if (empty($fw['nft'])): ?>
        <div class="card"><div class="empty"><b>A firewall do painel não está ativa</b>No servidor: <span class="mono">mpanel fw-restore</span> (requer o pacote nftables).</div></div>
      <?php endif; ?>
      <section class="stats" id="cn-stats">
        <div class="stat"><span class="tile t-acc"><?= ic('pulse') ?></span><div><div class="k">Ligações abertas</div><div class="v" data-c="total"><?= (int)($cj['total'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('world') ?></span><div><div class="k">IPs distintos</div><div class="v" data-c="distinct"><?= (int)($cj['distinct'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('reload') ?></span><div><div class="k">Em espera (SYN)</div><div class="v" data-c="syn"><?= (int)($cj['syn'] ?? 0) ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('ban') ?></span><div><div class="k">IPs bloqueados</div><div class="v"><?= count($fwBlocks) ?></div></div></div>
      </section>

      <section class="card" id="cn" data-me="<?= h($myIp) ?>" data-limit="<?= (int)$fwAuto['limit'] ?>" data-auto="<?= !empty($fwAuto['on']) ? 1 : 0 ?>"
        data-labels="<?= h((string)json_encode($portLabels)) ?>" data-allow="<?= h((string)json_encode(array_values($fwAllow))) ?>" data-init="<?= h((string)json_encode($cj)) ?>">
        <div class="card-h">
          <div><h2>Ligações por IP</h2><p>Atualiza a cada 5 segundos. Só ligações a serviços deste servidor.</p></div>
          <input class="in cn-search" id="cn-q" type="search" placeholder="Procurar IP…" aria-label="Procurar IP" autocomplete="off">
        </div>
        <table class="list cards">
          <thead><tr><th>IP de origem</th><th class="r">Ligações</th><th>Destino</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody id="cn-rows"><tr><td colspan="4" class="empty">A carregar…</td></tr></tbody>
        </table>
        <div class="card-f mu" id="cn-foot"></div>
      </section>

      <section class="card">
          <div class="card-h"><div><h2>IPs bloqueados</h2><p>Bloqueados em todas as portas, incluindo SSH.</p></div></div>
          <?php if (!$fwBlocks): ?>
            <div class="empty">Nenhum IP bloqueado.</div>
          <?php else: ?>
          <table class="list cards">
            <thead><tr><th>IP / rede</th><th>Origem</th><th>Motivo</th><th>Expira</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
            <tbody>
            <?php foreach ($fwBlocks as $b): $exp = (int)($b['exp'] ?? 0); $left = $exp - time(); ?>
              <tr>
                <td class="first" data-label="IP"><div class="nm mono"><?= h($b['ip'] ?? '') ?></div></td>
                <td data-label="Origem"><span class="pill <?= ($b['by'] ?? '') === 'auto' ? 'p-err' : 'p-off' ?>"><?= ($b['by'] ?? '') === 'auto' ? 'Automático' : 'Manual' ?></span> <span class="mu"><?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzl)) ?></span></td>
                <td data-label="Motivo" class="mu"><?= h(($b['reason'] ?? '') !== '' ? $b['reason'] : '—') ?></td>
                <td data-label="Expira"><?= $exp === 0 ? 'Permanente' : 'em ' . h($left >= 86400 ? round($left / 86400) . ' d' : ($left >= 3600 ? round($left / 3600) . ' h' : max(1, round($left / 60)) . ' min')) ?></td>
                <td class="act r"><form method="post" style="margin:0"><?= act_fields('fw_unblock', ['ip' => (string)($b['ip'] ?? '')]) ?><button class="btn sm sec" type="submit">Desbloquear</button></form></td>
              </tr>
            <?php endforeach; ?>
            </tbody>
          </table>
          <?php endif; ?>
      </section>

      <div class="grid2e">
          <section class="card">
            <div class="card-h"><div><h2>Bloqueio automático</h2><p>Bloqueia IPs com demasiadas ligações abertas em simultâneo.</p></div><span class="pill <?= !empty($fwAuto['on']) ? 'p-ok' : 'p-off' ?>"><?= !empty($fwAuto['on']) ? 'Ativo' : 'Desativado' ?></span></div>
            <form method="post" class="card-b">
              <?= act_fields('fw_auto') ?>
              <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
                <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($fwAuto['on']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($fwAuto['on']) ? ' selected' : '' ?>>Desativado</option></select></label>
                <label class="fld">Limite por IP<input class="in" name="limit" inputmode="numeric" pattern="[0-9]{2,6}" required value="<?= (int)$fwAuto['limit'] ?>"><small>ligações abertas</small></label>
                <label class="fld">Duração<select class="in" name="dur"><?php foreach ($durs as $dk => $dl): $ds = (int)fw_secs_php($dk); ?><option value="<?= h($dk) ?>"<?= $ds === $curDur ? ' selected' : '' ?>><?= h($dl) ?></option><?php endforeach; ?></select></label>
              </div>
              <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
            </form>
            <div class="card-f mu">Nunca são bloqueados: este servidor, os IPs de confiança e os IPs de onde usaste o painel nos últimos 7 dias.</div>
          </section>

          <section class="card">
            <div class="card-h"><div><h2>IPs de confiança</h2><p>Nunca são bloqueados, nem manual nem automaticamente.</p></div></div>
            <?php if ($fwAllow): ?>
            <div class="row-list">
              <?php foreach ($fwAllow as $a): ?>
                <div class="item"><span class="grow mono"><?= h($a) ?></span><form method="post" style="margin:0"><?= act_fields('fw_allow_del', ['ip' => (string)$a]) ?><button class="btn sm sec" type="submit">Remover</button></form></div>
              <?php endforeach; ?>
            </div>
            <?php endif; ?>
            <form method="post" class="card-b" style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap">
              <?= act_fields('fw_allow_add') ?>
              <label class="fld" style="flex:1;min-width:200px">IP ou rede<input class="in mono" name="ip" required placeholder="ex.: <?= h($myIp !== '' ? $myIp : '89.155.12.30') ?>" autocomplete="off"></label>
              <button class="btn sec" type="submit">Adicionar</button>
            </form>
          </section>
      </div>

      <dialog id="dlg-block">
        <form method="post">
          <?= act_fields('fw_block') ?>
          <div class="dlg-h"><h3>Bloquear IP ou rede</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">IP ou rede<input class="in mono" name="ip" id="blk-ip" required placeholder="ex.: 185.220.101.47 ou 45.148.10.0/24" autocomplete="off"></label>
            <div class="fgrid">
              <label class="fld">Duração<select class="in" name="dur"><option value="1h">1 hora</option><option value="24h" selected>24 horas</option><option value="7d">7 dias</option><option value="perm">Permanente</option></select></label>
              <label class="fld">Motivo (opcional)<input class="in" name="reason" maxlength="80" autocomplete="off"></label>
            </div>
            <div class="warnbox">O IP fica bloqueado em todas as portas, incluindo SSH, e as ligações abertas são cortadas de imediato.</div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Bloquear</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'cron'):
    $crons = is_array($state['crons'] ?? null) ? $state['crons'] : [];
    $cr = jload(MP_STATS . '/crons.json') ?? [];
    $runs = is_array($cr['runs'] ?? null) ? $cr['runs'] : [];
    $fSite = qget('site');
    if ($fSite !== '') $crons = array_values(array_filter($crons, function ($c) use ($fSite) { return ($c['site'] ?? '') === $fSite; }));
    $sitePorts = [];
    foreach ($sites as $s) $sitePorts[(string)$s['name']] = (int)$s['port'];
    $tzc = tz_off(live_stats());
?>
      <section class="card">
        <div class="card-h">
          <div><h2>Tarefas agendadas</h2><p>Cada tarefa corre com o utilizador do seu site. A saída fica guardada e não há sobreposição de execuções.</p></div>
          <?php if ($sites): ?>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="cron">
            <select class="in" name="site" onchange="this.form.submit()" aria-label="Filtrar por site" style="height:40px;min-width:180px">
              <option value="">Todos os sites</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select>
          </form>
          <?php endif; ?>
        </div>
        <?php if (!$sites): ?>
          <div class="empty"><b>Ainda não há sites</b>As tarefas agendadas pertencem a um site.</div>
        <?php elseif (!$crons): ?>
          <div class="empty"><b>Sem tarefas agendadas<?= $fSite !== '' ? ' neste site' : '' ?></b>Cria uma tarefa para correr um script PHP, chamar um URL ou executar um comando.<br><button class="btn" type="button" data-cron-new><?= ic('plus') ?>Nova tarefa</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Tarefa</th><th>Quando</th><th>Última execução</th><th>Estado</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($crons as $c):
                $cid = (string)($c['id'] ?? ''); $cs = (string)($c['site'] ?? ''); $on = !empty($c['on']);
                $run = $runs[$cs . ':' . $cid] ?? null; $rc = $run['rc'] ?? null; ?>
            <tr>
              <td class="first" data-label="Tarefa">
                <div class="who"><span class="av <?= tone($cs) ?>"><?= ic('clock') ?></span><div style="min-width:0">
                  <div class="nm"><?= h(($c['desc'] ?? '') !== '' ? $c['desc'] : $cs) ?></div>
                  <div class="mu mono cron-cmd" title="<?= h($c['cmd'] ?? '') ?>"><?= h($c['cmd'] ?? '') ?></div>
                </div></div>
              </td>
              <td data-label="Quando" class="cron-when"><div><?= h(cron_human((string)($c['when'] ?? ''))) ?></div><div class="mu"><span class="mono"><?= h($c['when'] ?? '') ?></span> · <?= h($cs) ?></div></td>
              <td data-label="Última execução" class="cron-when">
                <?php if ($run === null): ?><span class="mu">Ainda não correu</span>
                <?php elseif ($rc === 'running'): ?><span class="pill p-me">A correr</span> <span class="mu"><?= h(ago((int)$run['start'], time())) ?></span>
                <?php else: ?><span class="pill <?= $rc === '0' ? 'p-ok' : 'p-err' ?>"><?= $rc === '0' ? 'Sucesso' : 'Erro ' . h($rc) ?></span> <span class="mu"><?= h(ago((int)$run['end'], time())) ?> · <?= max(0, (int)$run['end'] - (int)$run['start']) ?> s</span><?php endif; ?>
              </td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-off' ?>"><?= $on ? 'Ativa' : 'Em pausa' ?></span></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações da tarefa"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <form method="post"><?= act_fields('cron_run', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('play') ?>Executar agora</button></form>
                    <button type="button" data-open="dlg-cronlog-<?= h($cid) ?>"><?= ic('file') ?>Ver saída</button>
                    <button type="button" data-cron-edit="<?= h((string)json_encode(['site' => $cs, 'id' => $cid, 'when' => $c['when'] ?? '', 'cmd' => $c['cmd'] ?? '', 'desc' => $c['desc'] ?? ''])) ?>"><?= ic('edit') ?>Editar</button>
                    <form method="post"><?= act_fields($on ? 'cron_off' : 'cron_on', ['site' => $cs, 'id' => $cid]) ?><button type="submit"><?= ic('toggle') ?><?= $on ? 'Pôr em pausa' : 'Ativar' ?></button></form>
                    <hr>
                    <form method="post" data-confirm="Apagar esta tarefa agendada?"><?= act_fields('cron_del', ['site' => $cs, 'id' => $cid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <dialog id="dlg-cronlog-<?= h($cid) ?>" style="width:min(820px,calc(100vw - 24px))">
                  <div class="dlg-h"><div style="min-width:0"><h3>Saída da última execução</h3><p class="mono cron-cmd"><?= h($c['cmd'] ?? '') ?></p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                  <pre class="cron-out"><?= $run !== null && ($run['tail'] ?? '') !== '' ? h($run['tail']) : 'Ainda não há saída registada.' ?></pre>
                  <div class="dlg-f"><span class="mu" style="margin-right:auto">Registo completo: /srv/www/<?= h($cs) ?>/logs/cron-<?= h($cid) ?>.log</span><button class="btn sec" type="button" data-close>Fechar</button></div>
                </dialog>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">Dentro do comando, <span class="mono">php</span> usa a versão de PHP do site. O comando arranca na pasta public_html do site. A saída fica em logs/cron-&lt;id&gt;.log e o resultado é atualizado a cada minuto.</div>
      </section>

      <dialog class="drawer" id="dlg-cron" aria-labelledby="t-cron">
        <form method="post" id="cron-form">
          <?= act_fields('cron_save') ?>
          <input type="hidden" name="id" id="cron-id">
          <div class="dlg-h"><div><h3 id="t-cron">Nova tarefa agendada</h3><p>Como no cPanel: periodicidade e comando.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">Site<select class="in" name="site" id="cron-site">
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>" data-port="<?= (int)$s['port'] ?>"<?= $sn === $fSite ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
            </select></label>
            <label class="fld">Definições comuns<select class="in" id="cron-preset">
              <option value="">— escolher —</option>
              <option value="* * * * *">A cada minuto</option>
              <option value="*/5 * * * *">A cada 5 minutos</option>
              <option value="*/15 * * * *">A cada 15 minutos</option>
              <option value="*/30 * * * *">A cada 30 minutos</option>
              <option value="0 * * * *">De hora a hora</option>
              <option value="0 */6 * * *">A cada 6 horas</option>
              <option value="0 3 * * *">Uma vez por dia (03:00)</option>
              <option value="0 3 * * 0">Uma vez por semana (domingo, 03:00)</option>
              <option value="0 3 1 * *">Uma vez por mês (dia 1, 03:00)</option>
            </select></label>
            <div class="cron-fields">
              <label class="fld">Minuto<input class="in mono" id="cf-0" value="*/5" autocomplete="off"></label>
              <label class="fld">Hora<input class="in mono" id="cf-1" value="*" autocomplete="off"></label>
              <label class="fld">Dia<input class="in mono" id="cf-2" value="*" autocomplete="off"></label>
              <label class="fld">Mês<input class="in mono" id="cf-3" value="*" autocomplete="off"></label>
              <label class="fld">Semana<input class="in mono" id="cf-4" value="*" autocomplete="off"></label>
            </div>
            <div class="mu" style="margin-top:-8px;font-size:12px">Minuto 0–59 · hora 0–23 · dia 1–31 · mês 1–12 · dia da semana 0–6 (0 = domingo). Aceita *, listas (1,15), intervalos (8-20) e passos (*/10).</div>
            <input type="hidden" name="when" id="cron-when">
            <div class="cron-human" id="cron-human"></div>
            <label class="fld">Comando<textarea class="in mono cron-ta" name="cmd" id="cron-cmd" rows="3" required maxlength="2000" spellcheck="false" placeholder="php /srv/www/loja/public_html/cron.php"></textarea></label>
            <div class="cron-help">
              <span class="mu">Inserir:</span>
              <button class="chip sm" type="button" data-ins="php">Script PHP</button>
              <button class="chip sm" type="button" data-ins="url">Chamar URL do site</button>
              <button class="chip sm" type="button" data-ins="quiet">Sem saída</button>
            </div>
            <label class="fld">Descrição (opcional)<input class="in" name="desc" id="cron-desc" maxlength="80" placeholder="ex.: Cron do PrestaShop" autocomplete="off"></label>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit" id="cron-submit">Criar tarefa</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'backups'):
    $bk = jload(MP_STATS . '/backup.json') ?? [];
    $bkRun = jload(MP_STATS . '/backup-run.json');
    $bkConf = is_array($bk['conf'] ?? null) ? $bk['conf'] : ['enabled' => true, 'time' => '03:00', 'keep_daily' => 7, 'keep_weekly' => 4, 'keep_monthly' => 3, 'remote' => ''];
    $bkSets = is_array($bk['sets'] ?? null) ? $bk['sets'] : [];
    $bkRem = is_array($bk['remotes'] ?? null) ? $bk['remotes'] : [];
    $bkLast = is_array($bk['last'] ?? null) ? $bk['last'] : null;
    $tzb = tz_off(live_stats());
    $fSet = qget('set');
    if ($fSet !== '') $bkSets = array_values(array_filter($bkSets, function ($x) use ($fSet) { return ($x['site'] ?? '') === $fSet; }));
    $setName = function (string $s): string { return $s === '_bd' ? 'Bases de dados sem site' : ($s === '_sistema' ? 'Configuração do sistema' : $s); };
    $typeName = ['auto' => ['Automático', 'p-off'], 'manual' => ['Manual', 'p-me'], 'pre-restauro' => ['Antes de repor', 'p-err']];
    $next = '';
    if (!empty($bkConf['enabled'])) {
        [$hh, $mm] = array_map('intval', explode(':', (string)$bkConf['time'] . ':0'));
        $loc = time() + $tzb; $today = intdiv($loc, 86400) * 86400 + $hh * 3600 + $mm * 60;
        $next = gmdate('d/m H:i', $today > $loc ? $today : $today + 86400);
    }
?>
      <?php if ($bkRun): ?>
        <div class="card bk-run" data-bk-running><div class="row-list"><div class="item"><span class="spin"></span><div class="grow"><div class="nm">Backup em curso</div><div class="mu"><?= h($bkRun['step'] ?? '') ?> · desde há <?= max(1, (int)ceil((time() - (int)($bkRun['since'] ?? time())) / 60)) ?> min</div></div><span class="mu">A página atualiza sozinha.</span></div></div></div>
      <?php endif; ?>
      <section class="stats">
        <div class="stat"><span class="tile <?= $bkLast && empty($bkLast['ok']) ? 't-warn' : 't-acc' ?>"><?= ic('archive') ?></span><div><div class="k">Último backup</div><div class="v"><?= $bkLast ? (empty($bkLast['ok']) ? 'Com erros' : 'Sucesso') : '—' ?> <small><?= $bkLast ? h(ago((int)$bkLast['ts'], time())) : 'ainda não houve' ?></small></div></div></div>
        <div class="stat"><span class="tile t-blue"><?= ic('clock') ?></span><div><div class="k">Próximo automático</div><div class="v"><?= $next !== '' ? h($next) : 'Desativado' ?></div></div></div>
        <div class="stat"><span class="tile t-vio"><?= ic('db') ?></span><div><div class="k">Espaço ocupado (local)</div><div class="v"><?= h(fmt_bytes((float)($bk['total'] ?? 0))) ?> <small><?= count($bk['sets'] ?? []) ?> backups</small></div></div></div>
        <div class="stat"><span class="tile t-warn"><?= ic('upload') ?></span><div><div class="k">Cópia remota</div><div class="v"><?= ($bkConf['remote'] ?? '') !== '' ? h($bkConf['remote']) : 'Só local' ?></div></div></div>
      </section>
      <?php if ($bkLast && empty($bkLast['ok'])): ?><div class="card"><div class="card-b" style="color:var(--err)"><?= h($bkLast['msg'] ?? '') ?></div></div><?php endif; ?>

      <section class="card">
        <div class="card-h">
          <div><h2>Backups guardados</h2><p>Cada backup de um site inclui os ficheiros, as bases de dados associadas e as tarefas agendadas.</p></div>
          <form method="get" style="margin:0"><input type="hidden" name="p" value="backups">
            <select class="in" name="set" onchange="this.form.submit()" aria-label="Filtrar" style="height:40px;min-width:200px">
              <option value="">Todos</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>"<?= $sn === $fSet ? ' selected' : '' ?>><?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd"<?= $fSet === '_bd' ? ' selected' : '' ?>>Bases de dados sem site</option>
              <option value="_sistema"<?= $fSet === '_sistema' ? ' selected' : '' ?>>Configuração do sistema</option>
            </select>
          </form>
        </div>
        <?php if (!$bkSets): ?>
          <div class="empty"><b>Ainda não há backups<?= $fSet !== '' ? ' deste conjunto' : '' ?></b>Faz o primeiro agora ou espera pelo backup automático.<br><button class="btn" type="button" data-open="dlg-bk-now"><?= ic('archive') ?>Fazer backup agora</button></div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Conjunto</th><th>Data</th><th>Tipo</th><th>Conteúdo</th><th class="r">Tamanho</th><th>Remoto</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($bkSets as $i => $b): $bs = (string)($b['site'] ?? ''); $bid = (string)($b['id'] ?? ''); $tn = $typeName[$b['type'] ?? 'manual'] ?? ['Manual', 'p-me'];
                $dbl = is_array($b['dbs'] ?? null) ? $b['dbs'] : []; $did = 'bk' . $i; ?>
            <tr>
              <td class="first" data-label="Conjunto"><div class="who"><span class="av <?= $bs[0] === '_' ? 't-vio' : tone($bs) ?>"><?= $bs[0] === '_' ? ic($bs === '_bd' ? 'db' : 'server') : h(substr($bs, 0, 1)) ?></span><div class="nm"><?= h($setName($bs)) ?></div></div></td>
              <td data-label="Data"><?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?></td>
              <td data-label="Tipo"><span class="pill <?= $tn[1] ?>"><?= $tn[0] ?></span></td>
              <td data-label="Conteúdo" class="mu"><?= h(implode(' + ', array_filter([!empty($b['files']) ? ($bs === '_sistema' ? 'Configuração' : 'Ficheiros') : '', $dbl ? count($dbl) . ' BD' : '']))) ?: '—' ?></td>
              <td class="r" data-label="Tamanho"><?= h(fmt_bytes((float)($b['size'] ?? 0))) ?></td>
              <td data-label="Remoto"><?= ($b['remote'] ?? '') !== '' ? '<span class="pill p-ok">' . h($b['remote']) . '</span>' : '<span class="mu">—</span>' ?></td>
              <td class="act r">
                <details class="dd">
                  <summary class="iconbtn" aria-label="Ações do backup"><?= ic('dots') ?></summary>
                  <div class="dd-menu">
                    <?php if ($bs !== '_sistema'): ?><button type="button" data-open="dlg-rs-<?= $did ?>"><?= ic('reload') ?>Repor…</button><?php endif; ?>
                    <?php if (!empty($b['files'])): $ff = $bs === '_sistema' ? 'sistema.tar.gz' : 'ficheiros.tar.gz'; ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=<?= $ff ?>"><?= ic('download') ?>Descarregar <?= $bs === '_sistema' ? 'configuração' : 'ficheiros' ?></a><?php endif; ?>
                    <?php foreach ($dbl as $d): ?><a href="?bk=dl&amp;s=<?= h(rawurlencode($bs)) ?>&amp;id=<?= h($bid) ?>&amp;f=bd-<?= h(rawurlencode((string)$d)) ?>.sql.gz"><?= ic('download') ?>Descarregar BD <?= h($d) ?></a><?php endforeach; ?>
                    <hr>
                    <form method="post" data-confirm="Apagar este backup (cópia local)?"><?= act_fields('bk_del', ['s' => $bs, 'id' => $bid]) ?><button type="submit" class="dan"><?= ic('trash') ?>Apagar</button></form>
                  </div>
                </details>
                <?php if ($bs !== '_sistema'): ?>
                <dialog id="dlg-rs-<?= $did ?>">
                  <form method="post">
                    <?= act_fields('bk_restore', ['s' => $bs, 'id' => $bid]) ?>
                    <div class="dlg-h"><h3>Repor <?= h($setName($bs)) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
                    <div class="dlg-b">
                      <p class="mu" style="margin:0">Backup de <?= h(gmdate('d/m/Y H:i', (int)($b['created'] ?? 0) + $tzb)) ?>.</p>
                      <?php if ($bs !== '_bd'): ?>
                      <label class="chk"><input type="radio" name="what" value="all" checked> Tudo: ficheiros, bases de dados e tarefas agendadas</label>
                      <label class="chk"><input type="radio" name="what" value="files"> Só os ficheiros (public_html)</label>
                      <?php if ($dbl): ?><label class="chk"><input type="radio" name="what" value="db"> Só as bases de dados (<?= h(implode(', ', $dbl)) ?>)</label><?php endif; ?>
                      <?php else: ?><input type="hidden" name="what" value="db"><p style="margin:0">Repõe as bases de dados: <?= h(implode(', ', $dbl)) ?>.</p><?php endif; ?>
                      <div class="warnbox">O conteúdo atual é substituído. Antes de repor é feito automaticamente um backup do estado atual ("Antes de repor"), para poderes voltar atrás.</div>
                      <label class="chk"><input type="checkbox" name="ok" value="1" required> Compreendo que o conteúdo atual vai ser substituído</label>
                    </div>
                    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Repor backup</button></div>
                  </form>
                </dialog>
                <?php endif; ?>
              </td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">Local: /var/backups/minipainel. As bases de dados só entram no backup de um site se estiverem associadas a ele (página Bases de dados); as restantes vão para "Bases de dados sem site".</div>
      </section>

      <div class="grid2e">
        <section class="card">
          <div class="card-h"><div><h2>Agendamento e retenção</h2><p>Backup automático diário de todos os sites e bases de dados.</p></div><span class="pill <?= !empty($bkConf['enabled']) ? 'p-ok' : 'p-off' ?>"><?= !empty($bkConf['enabled']) ? 'Ativo' : 'Desativado' ?></span></div>
          <form method="post" class="card-b">
            <?= act_fields('bk_conf') ?>
            <div class="fgrid">
              <label class="fld">Estado<select class="in" name="on"><option value="on"<?= !empty($bkConf['enabled']) ? ' selected' : '' ?>>Ativo</option><option value="off"<?= empty($bkConf['enabled']) ? ' selected' : '' ?>>Desativado</option></select></label>
              <label class="fld">Hora<input class="in" type="time" name="time" required value="<?= h($bkConf['time'] ?? '03:00') ?>"></label>
            </div>
            <div class="fgrid" style="grid-template-columns:repeat(3,minmax(0,1fr));margin-top:14px">
              <label class="fld">Diários<input class="in" name="daily" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_daily'] ?>"></label>
              <label class="fld">Semanais<input class="in" name="weekly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_weekly'] ?>"></label>
              <label class="fld">Mensais<input class="in" name="monthly" inputmode="numeric" pattern="[0-9]{1,3}" required value="<?= (int)$bkConf['keep_monthly'] ?>"></label>
            </div>
            <label class="fld" style="margin-top:14px">Cópia remota<select class="in" name="remote"><option value="none">Só local</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?> (<?= h($r['type']) ?>)</option><?php endforeach; ?></select></label>
            <div style="margin-top:16px"><button class="btn" type="submit">Guardar</button></div>
          </form>
          <div class="card-f mu">A retenção aplica-se ao local e ao remoto: por exemplo, 7 diários, 4 semanais e 3 mensais cobrem cerca de 3 meses. Os backups manuais ficam até os apagares. Se o disco passar de 90%, o backup é cancelado e o erro aparece aqui.</div>
        </section>

        <section class="card">
          <div class="card-h"><div><h2>Destinos remotos</h2><p>SFTP, S3 (Backblaze, Wasabi, MinIO, AWS…) ou qualquer destino do rclone.</p></div><button class="chip sm soft" type="button" data-open="dlg-bk-remote">Adicionar destino</button></div>
          <?php if (!$bkRem): ?>
            <div class="empty">Sem destinos remotos. Os backups ficam só neste servidor.</div>
          <?php else: ?>
          <div class="row-list">
            <?php foreach ($bkRem as $r): ?>
              <div class="item">
                <span class="av t-blue"><?= ic('upload') ?></span>
                <div class="grow"><div class="nm"><?= h($r['name']) ?> <span class="pill p-off"><?= h(strtoupper((string)$r['type'])) ?></span></div><div class="mu mono"><?= h($r['root']) ?>/<?= h($sys['hostname'] ?? 'servidor') ?>/…</div></div>
                <div class="svc-acts">
                  <form method="post"><?= act_fields('bk_remote_test', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Testar</button></form>
                  <form method="post" data-confirm="Remover o destino <?= h($r['name']) ?>? Os backups já enviados não são apagados."><?= act_fields('bk_remote_del', ['name' => (string)$r['name']]) ?><button class="btn sm sec" type="submit">Remover</button></form>
                </div>
              </div>
            <?php endforeach; ?>
          </div>
          <?php endif; ?>
        </section>
      </div>

      <dialog id="dlg-bk-now">
        <form method="post">
          <?= act_fields('bk_now') ?>
          <div class="dlg-h"><h3>Fazer backup agora</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <label class="fld">O que guardar<select class="in" name="target">
              <option value="all">Tudo (todos os sites, bases de dados e configuração)</option>
              <?php foreach ($sites as $s): $sn = (string)$s['name']; ?><option value="<?= h($sn) ?>">Site <?= h($sn) ?></option><?php endforeach; ?>
              <option value="_bd">Bases de dados sem site</option>
              <option value="_sistema">Configuração do sistema</option>
            </select></label>
            <?php if ($bkRem): ?>
            <label class="fld">Enviar também para<select class="in" name="remote"><option value="">Não enviar (só local)</option><?php foreach ($bkRem as $r): ?><option value="<?= h($r['name']) ?>"<?= ($bkConf['remote'] ?? '') === $r['name'] ? ' selected' : '' ?>><?= h($r['name']) ?></option><?php endforeach; ?></select></label>
            <?php endif; ?>
            <p class="mu" style="margin:0">Corre em segundo plano; podes continuar a usar o painel. Os backups manuais não são apagados pela retenção.</p>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Iniciar backup</button></div>
        </form>
      </dialog>

      <dialog class="drawer" id="dlg-bk-remote">
        <form method="post" autocomplete="off">
          <?= act_fields('bk_remote_add') ?>
          <div class="dlg-h"><div><h3>Adicionar destino remoto</h3><p>As credenciais ficam só neste servidor (/etc/minipainel, acesso root).</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
          <div class="dlg-b">
            <div class="fgrid">
              <label class="fld">Nome<input class="in" name="name" required pattern="[a-z][a-z0-9\-]{1,23}" placeholder="ex.: storagebox"></label>
              <label class="fld">Tipo<select class="in" name="type" id="rm-type"><option value="sftp">SFTP</option><option value="s3">S3 compatível</option><option value="rclone">Outro (configuração rclone)</option></select></label>
            </div>
            <div data-rm="sftp" class="rm-grp">
              <div class="fgrid">
                <label class="fld">Servidor<input class="in" name="host" placeholder="backup.exemplo.pt"></label>
                <label class="fld">Porta<input class="in" name="port" value="22" inputmode="numeric"></label>
                <label class="fld">Utilizador<input class="in" name="user"></label>
                <label class="fld">Password<input class="in" type="password" name="pass" autocomplete="new-password"><small>Ou usa uma chave privada abaixo</small></label>
              </div>
              <label class="fld">Chave privada (opcional)<textarea class="in mono cron-ta" name="key" rows="3" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"></textarea></label>
              <label class="fld">Pasta no servidor<input class="in mono" name="path_sftp" value="backups"></label>
            </div>
            <div data-rm="s3" class="rm-grp" hidden>
              <div class="fgrid">
                <label class="fld">Fornecedor<select class="in" name="provider"><option value="Other">Outro / MinIO / Backblaze B2 (S3)</option><option value="Wasabi">Wasabi</option><option value="AWS">Amazon S3</option><option value="Cloudflare">Cloudflare R2</option><option value="DigitalOcean">DigitalOcean Spaces</option></select></label>
                <label class="fld">Região<input class="in" name="region" placeholder="eu-central-1"></label>
              </div>
              <label class="fld">Endpoint<input class="in mono" name="endpoint" placeholder="s3.eu-central-003.backblazeb2.com"><small>Vazio para Amazon S3</small></label>
              <div class="fgrid">
                <label class="fld">Chave de acesso<input class="in mono" name="access"></label>
                <label class="fld">Chave secreta<input class="in mono" type="password" name="secret" autocomplete="new-password"></label>
                <label class="fld">Bucket<input class="in mono" name="bucket"></label>
                <label class="fld">Prefixo (opcional)<input class="in mono" name="path_s3" placeholder="servidores"></label>
              </div>
            </div>
            <div data-rm="rclone" class="rm-grp" hidden>
              <label class="fld">Configuração rclone<textarea class="in mono cron-ta" name="config" rows="7" placeholder="[nome]&#10;type = drive&#10;scope = drive&#10;token = {...}"></textarea><small>Para Google Drive, OneDrive, Dropbox…: corre "rclone config" no teu PC e cola aqui a secção gerada. O nome entre [ ] tem de ser igual ao nome acima.</small></label>
              <label class="fld">Pasta no destino<input class="in mono" name="path_rc" value="iddigital-hosting"></label>
            </div>
          </div>
          <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Adicionar</button></div>
        </form>
      </dialog>

<?php elseif ($page === 'servicos'): ?>
      <section class="card">
        <?php if (!$svcs): ?>
          <div class="empty">Sem informação dos serviços.</div>
        <?php else: ?>
        <table class="list cards">
          <thead><tr><th>Serviço</th><th>Estado</th><th>Utilização</th><th class="r"><span class="sr-only">Ações</span></th></tr></thead>
          <tbody>
          <?php foreach ($svcs as $s): $on = !empty($s['active']); ?>
            <tr>
              <td class="first" data-label="Serviço"><div class="who"><span class="av <?= $on ? 't-acc' : 't-warn' ?>"><?= ic(($s['id'] ?? '') === 'mariadb' ? 'db' : ((($s['id'] ?? '') === 'nginx') ? 'world' : 'code')) ?></span><div><div class="nm"><?= h($s['name'] ?? '') ?></div><div class="mu mono"><?= h($s['unit'] ?? '') ?></div></div></div></td>
              <td data-label="Estado"><span class="pill <?= $on ? 'p-ok' : 'p-err' ?>"><?= $on ? 'Ativo' : 'Parado' ?></span></td>
              <td data-label="Utilização" class="mu"><?= h(svc_usage($s, $bySite)) ?></td>
              <td data-label="Ações"><?= svc_actions($s, $bySite) ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
        <?php endif; ?>
        <div class="card-f mu">Recarregar aplica configurações sem cortar ligações. Antes de cada ação a configuração é testada; se tiver erros, nada é alterado. Os serviços arrancam sozinhos quando o servidor reinicia.</div>
      </section>

<?php else: ?>
      <section class="card" style="max-width:none">
        <div class="card-h"><h2>Password do painel</h2><p>Utilizador: <?= h($_SESSION['user']) ?></p></div>
        <form method="post" class="card-b">
          <?= act_fields('conta_pass') ?>
          <div class="fgrid" style="grid-template-columns:repeat(auto-fit,minmax(220px,1fr))">
            <label class="fld">Password atual<input class="in" type="password" name="atual" required autocomplete="current-password"></label>
            <label class="fld">Nova password<input class="in" type="password" name="nova" required minlength="10" autocomplete="new-password"><small>Mínimo 10 caracteres</small></label>
            <label class="fld">Repetir nova password<input class="in" type="password" name="repetir" required minlength="10" autocomplete="new-password"></label>
          </div>
          <div style="margin-top:16px"><button class="btn" type="submit">Alterar password</button></div>
        </form>
        <div class="card-f mu">No servidor também podes usar <span class="mono">mpanel passwd</span>.</div>
      </section>
<?php endif; ?>
    </main>
  </div>
</div>

<!-- Novo site -->
<dialog class="drawer" id="dlg-site-new" aria-labelledby="t-site-new">
  <form method="post">
    <?= act_fields('site_add') ?>
    <div class="dlg-h"><div><h3 id="t-site-new">Novo site</h3><p>Fica acessível em http://IP:porta e http://localhost:porta.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in" name="site" required maxlength="24" pattern="[a-z][a-z0-9\-]{0,23}" placeholder="loja" autocomplete="off"><small>Minúsculas, números e "-", a começar por letra</small></label>
      <div class="fgrid">
        <label class="fld">Porta<input class="in" name="port" inputmode="numeric" pattern="[0-9]{1,5}" placeholder="automática" autocomplete="off"><small>Vazio = próxima livre a partir de 8001</small></label>
        <label class="fld">Versão de PHP<select class="in" name="php"><?= php_options($phps, $defPhp) ?></select></label>
      </div>
      <div class="fsec">Limites do PHP</div>
      <?= limit_fields(LIMIT_DEFAULTS + ['display_errors' => false]) ?>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar site</button></div>
  </form>
</dialog>

<!-- Nova base de dados -->
<dialog class="drawer" id="dlg-db-new" aria-labelledby="t-db-new">
  <form method="post">
    <?= act_fields('db_add') ?>
    <div class="dlg-h"><div><h3 id="t-db-new">Nova base de dados</h3><p>O utilizador é criado com o mesmo nome.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <label class="fld">Nome<input class="in mono" name="db" required maxlength="32" pattern="[a-z][a-z0-9_]{0,31}" placeholder="loja_db" autocomplete="off"><small>Minúsculas, números e "_", a começar por letra</small></label>
      <label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label>
      <label class="fld">Site associado<select class="in" name="site"><option value="">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"><?= h($ssn) ?></option><?php endforeach; ?></select><small>Entra nos backups do site e é reposta com ele</small></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Criar base de dados</button></div>
  </form>
</dialog>

<?php foreach ($sites as $s): $n = (string)($s['name'] ?? ''); if (!valid_site($n)) continue; $L = site_limits($s); ?>
<dialog class="drawer" id="dlg-lim-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_limits', ['site' => $n]) ?>
    <div class="dlg-h"><div><h3>Limites de <?= h($n) ?></h3><p>Aplicados ao PHP-FPM e ao nginx deste site.</p></div><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <?= limit_fields($L) ?>
      <div class="mu">O upload máximo também define o tamanho máximo de pedido no nginx (client_max_body_size). Se a configuração falhar, os valores anteriores são repostos.</div>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar limites</button></div>
  </form>
</dialog>
<dialog id="dlg-php-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_php', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Versão de PHP de <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Versão<select class="in" name="php"><?= php_options($phps, (string)($s['php'] ?? '')) ?></select><small>A troca é feita sem interromper o site.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar versão</button></div>
  </form>
</dialog>
<dialog id="dlg-del-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('site_del', ['site' => $n]) ?>
    <div class="dlg-h"><h3>Apagar o site <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b">
      <div class="warnbox">O site deixa de estar acessível na porta <?= (int)($s['port'] ?? 0) ?>, e o utilizador de sistema e a configuração são removidos. As bases de dados não são apagadas.</div>
      <label class="chk"><input type="checkbox" name="keep" value="1"> Manter os ficheiros em <?= h('/srv/www/' . $n) ?></label>
    </div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar site</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<?php foreach ($dbs as $d): $n = (string)($d['name'] ?? ''); if (!preg_match(RX_DB, $n)) continue; ?>
<dialog id="dlg-dblink-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_link', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Associar <?= h($n) ?> a um site</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Site<select class="in" name="site"><option value="none">Nenhum</option><?php foreach ($sites as $ss): $ssn = (string)$ss['name']; ?><option value="<?= h($ssn) ?>"<?= ($d['site'] ?? '') === $ssn ? ' selected' : '' ?>><?= h($ssn) ?></option><?php endforeach; ?></select><small>A base de dados passa a entrar nos backups do site e é reposta com ele.</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Guardar</button></div>
  </form>
</dialog>
<dialog id="dlg-dbpw-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_pass', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Nova password para <?= h($n) ?></h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><label class="fld">Password<input class="in" name="pw" type="password" maxlength="64" autocomplete="new-password"><small>Vazio = gerada automaticamente e mostrada no fim</small></label></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn" type="submit">Mudar password</button></div>
  </form>
</dialog>
<dialog id="dlg-dbdel-<?= h($n) ?>">
  <form method="post">
    <?= act_fields('db_del', ['db' => $n]) ?>
    <div class="dlg-h"><h3>Apagar a base de dados <?= h($n) ?>?</h3><button class="iconbtn" type="button" data-close aria-label="Fechar"><?= ic('x') ?></button></div>
    <div class="dlg-b"><div class="warnbox">A base de dados e o utilizador <?= h($n) ?>@localhost são apagados. Esta ação não pode ser anulada.</div></div>
    <div class="dlg-f"><button class="btn sec" type="button" data-close>Cancelar</button><button class="btn dan" type="submit">Apagar base de dados</button></div>
  </form>
</dialog>
<?php endforeach; ?>

<div class="toasts" aria-live="polite">
  <?php foreach ($jobs as $j): ?>
    <div class="toast pending"><span class="ti"><span class="spin"></span></span><div class="msg"><?= h(($j['label'] ?? 'Tarefa') . '…') ?></div></div>
  <?php endforeach; ?>
  <?php foreach ($flashes as $f): $sticky = !empty($f[2]); $m = (string)$f[1]; ?>
    <div class="toast <?= $f[0] ? 'ok' : 'err' ?>"<?= $sticky ? '' : ' data-auto' ?>>
      <span class="ti"><?= ic($f[0] ? 'check' : 'alert') ?></span>
      <div class="msg<?= strpos($m, "\n") !== false ? ' mono' : '' ?>"><?= h($m) ?></div>
      <button type="button" data-dismiss aria-label="Fechar"><?= ic('x') ?></button>
    </div>
  <?php endforeach; ?>
</div>

<script>
(function () {
  var $ = function (s, c) { return (c || document).querySelectorAll(s); };
  function openDlg(id) { var d = document.getElementById(id); if (d && d.showModal && !d.open) { closeMenus(); d.showModal(); var f = d.querySelector('input:not([type=hidden]),select'); if (f) f.focus(); } }
  function closeMenus(except) { $('details.dd[open]').forEach(function (x) { if (x !== except) x.removeAttribute('open'); }); }
  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-open]');
    if (t) { e.preventDefault(); openDlg(t.getAttribute('data-open')); return; }
    var c = e.target.closest('[data-close]');
    if (c) { var d = c.closest('dialog'); if (d) d.close(); return; }
    if (e.target.closest('[data-dismiss]')) { e.target.closest('.toast').remove(); return; }
    if (e.target.closest('[data-nav-open]')) { document.body.classList.add('nav-open'); return; }
    if (e.target.closest('[data-nav-close]')) { document.body.classList.remove('nav-open'); return; }
    if (e.target.closest('[data-theme-toggle]')) {
      var n = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', n);
      try { localStorage.setItem('mp-theme', n); } catch (x) {}
      return;
    }
    if (!e.target.closest('details.dd')) closeMenus();
  });
  $('details.dd').forEach(function (d) { d.addEventListener('toggle', function () { if (d.open) closeMenus(d); }); });
  $('dialog').forEach(function (d) { d.addEventListener('click', function (e) { if (e.target === d && !d.hasAttribute('data-keep')) d.close(); }); });
  document.addEventListener('submit', function (e) {
    var f = e.target, m = f.getAttribute('data-confirm');
    if ((f.getAttribute('method') || '').toLowerCase() === 'dialog') return;
    if (m && !window.confirm(m)) { e.preventDefault(); return; }
    setTimeout(function () { $('button', f).forEach(function (b) { b.disabled = true; }); }, 0);
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeMenus(); document.body.classList.remove('nav-open'); } });
  $('.toast[data-auto]').forEach(function (t) { setTimeout(function () { t.remove(); }, 6000); });
  var o = document.body.getAttribute('data-autoopen');
  if (o) openDlg(o);
  if (parseInt(document.body.getAttribute('data-pending'), 10) > 0) {
    var poll = function () {
      fetch('?poll=1', { credentials: 'same-origin', cache: 'no-store' })
        .then(function (r) { if (r.status === 401) return { pending: 0 }; return r.json(); })
        .then(function (d) { if (d.pending > 0) setTimeout(poll, 1000); else location.replace(location.pathname + location.search.replace(/[?&](novo|limites)=[^&]*/g, '')); })
        .catch(function () { setTimeout(poll, 1500); });
    };
    setTimeout(poll, 700);
  }
})();
</script>
<?php if ($page === 'backups'): ?>
<script>
(function () {
  var t = document.getElementById('rm-type');
  if (t) {
    var sw = function () { document.querySelectorAll('.rm-grp').forEach(function (g) { g.hidden = g.getAttribute('data-rm') !== t.value; }); };
    t.addEventListener('change', sw); sw();
  }
  function tick() { if (document.querySelector("dialog[open]")) setTimeout(tick, 5000); else location.reload(); }
  if (document.querySelector("[data-bk-running]")) setTimeout(tick, 5000);
})();
</script>
<?php endif; ?>
<?php if ($page === 'cron'): ?>
<script>
(function () {
  var dlg = document.getElementById('dlg-cron'); if (!dlg) return;
  var F = [0, 1, 2, 3, 4].map(function (i) { return document.getElementById('cf-' + i); });
  var human = document.getElementById('cron-human'), when = document.getElementById('cron-when'), cmd = document.getElementById('cron-cmd');
  var site = document.getElementById('cron-site');
  var days = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function desc(p) {
    var mi = p[0], ho = p[1], dm = p[2], mo = p[3], dw = p[4], n = /^\d+$/, m;
    var hm = function () { return two(+ho) + ':' + two(+mi); };
    if (dm === '*' && mo === '*' && dw === '*') {
      if (mi === '*' && ho === '*') return 'A cada minuto';
      if ((m = /^\*\/(\d+)$/.exec(mi)) && ho === '*') return 'A cada ' + m[1] + ' minutos';
      if (n.test(mi) && ho === '*') return 'De hora a hora, ao minuto ' + (+mi);
      if (n.test(mi) && (m = /^\*\/(\d+)$/.exec(ho))) return 'A cada ' + m[1] + ' horas, ao minuto ' + (+mi);
      if (n.test(mi) && n.test(ho)) return 'Todos os dias às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && dm === '*' && mo === '*') {
      if (/^[0-7]$/.test(dw)) return 'À ' + days[+dw] + ' às ' + hm();
      if (dw === '1-5') return 'Dias úteis às ' + hm();
    }
    if (n.test(mi) && n.test(ho) && n.test(dm) && mo === '*' && dw === '*') return 'No dia ' + (+dm) + ' de cada mês às ' + hm();
    return 'Expressão personalizada';
  }
  function sync() {
    var p = F.map(function (f) { return f.value.trim() || '*'; });
    var ok = p.every(function (x) { return /^(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(\/[0-9]+)?)*$/.test(x); });
    when.value = p.join(' ');
    human.textContent = ok ? desc(p) + '  ·  ' + when.value : 'Expressão inválida';
    human.classList.toggle('bad', !ok);
  }
  F.forEach(function (f) { f.addEventListener('input', sync); });
  document.getElementById('cron-preset').addEventListener('change', function (e) {
    if (!e.target.value) return; e.target.value.split(' ').forEach(function (v, i) { F[i].value = v; }); sync();
  });
  function ins(t) { var s = cmd.selectionStart, v = cmd.value; cmd.value = v.slice(0, s) + t + v.slice(cmd.selectionEnd); cmd.focus(); cmd.selectionStart = cmd.selectionEnd = s + t.length; }
  document.querySelector('.cron-help').addEventListener('click', function (e) {
    var b = e.target.closest('[data-ins]'); if (!b) return;
    var sn = site.value, port = site.options[site.selectedIndex].getAttribute('data-port');
    var k = b.getAttribute('data-ins');
    if (k === 'php') ins('php /srv/www/' + sn + '/public_html/');
    else if (k === 'url') ins('curl -fsS -m 300 "http://127.0.0.1' + (port === '80' ? '' : ':' + port) + '/"');
    else ins(' >/dev/null 2>&1');
  });
  function open(d) {
    document.getElementById('t-cron').textContent = d ? 'Editar tarefa agendada' : 'Nova tarefa agendada';
    document.getElementById('cron-submit').textContent = d ? 'Guardar alterações' : 'Criar tarefa';
    document.getElementById('cron-id').value = d ? d.id : '';
    if (d) { site.value = d.site; cmd.value = d.cmd; document.getElementById('cron-desc').value = d.desc || ''; var w = d.when.split(/\s+/); if (w.length === 5) w.forEach(function (v, i) { F[i].value = v; }); }
    else { cmd.value = ''; document.getElementById('cron-desc').value = ''; ['*/5', '*', '*', '*', '*'].forEach(function (v, i) { F[i].value = v; }); }
    site.disabled = !!d;
    document.getElementById('cron-preset').value = ''; sync(); dlg.showModal(); cmd.focus();
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-cron-new]'); if (b) { e.preventDefault(); open(null); return; }
    b = e.target.closest('[data-cron-edit]'); if (b) { e.preventDefault(); open(JSON.parse(b.getAttribute('data-cron-edit'))); }
  });
  document.getElementById('cron-form').addEventListener('submit', function (e) {
    sync(); if (human.classList.contains('bad')) { e.preventDefault(); return; }
    if (cmd.value.indexOf('\n') !== -1) cmd.value = cmd.value.replace(/[\r\n]+/g, ' ');
    site.disabled = false;
  });
  sync();
})();
</script>
<?php endif; ?>
<?php if ($page === 'ligacoes'): ?>
<script>
(function () {
  var box = document.getElementById('cn'); if (!box) return;
  var L = JSON.parse(box.getAttribute('data-labels') || '{}'), allow = JSON.parse(box.getAttribute('data-allow') || '[]');
  var me = box.getAttribute('data-me'), lim = +box.getAttribute('data-limit') || 0, auto = box.getAttribute('data-auto') === '1';
  var data = JSON.parse(box.getAttribute('data-init') || '{}'), q = document.getElementById('cn-q');
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function lab(p) { return L[p] ? L[p] + ' :' + p : ':' + p; }
  function render() {
    var rows = (data.ips || []), f = (q.value || '').trim(), h = '';
    if (f) rows = rows.filter(function (r) { return r.ip.indexOf(f) !== -1; });
    rows.slice(0, 200).forEach(function (r) {
      var ports = Object.keys(r.ports || {}).sort(function (a, b) { return r.ports[b] - r.ports[a]; })
        .map(function (p) { return esc(lab(p)) + ' (' + r.ports[p] + ')'; }).join(' · ');
      var isMe = r.ip === me, ok = allow.indexOf(r.ip) !== -1, hot = lim && r.n >= lim * 0.8;
      var act = isMe ? '<span class="mu">protegido</span>' : ok ? '<span class="mu">confiança</span>'
        : '<button class="btn sm danger-o" type="button" data-block="' + esc(r.ip) + '">Bloquear</button>';
      h += '<tr><td class="first" data-label="IP"><span class="nm mono">' + esc(r.ip) + '</span>' + (isMe ? ' <span class="pill p-me">tu</span>' : '') +
        (r.syn ? '<div class="mu">' + r.syn + ' em espera (SYN)</div>' : '') + '</td>' +
        '<td class="r" data-label="Ligações"><b class="' + (hot ? 'cn-hot' : '') + '">' + r.n + '</b></td>' +
        '<td class="mu" data-label="Destino">' + ports + '</td><td class="act r">' + act + '</td></tr>';
    });
    if (!h) h = '<tr><td colspan="4" class="empty">' + (f ? 'Nenhum IP corresponde à pesquisa.' : 'Sem ligações abertas de momento.') + '</td></tr>';
    document.getElementById('cn-rows').innerHTML = h;
    document.querySelectorAll('[data-c]').forEach(function (e) { var k = e.getAttribute('data-c'); if (data[k] !== undefined) e.textContent = data[k]; });
    var t = data.ts ? new Date(data.ts * 1000) : null;
    document.getElementById('cn-foot').textContent = (rows.length > 200 ? 'A mostrar 200 de ' + rows.length + ' IPs. ' : '') +
      (auto ? 'Bloqueio automático ativo acima de ' + lim + ' ligações por IP. ' : 'Bloqueio automático desativado. ') +
      (t ? 'Última leitura às ' + t.toLocaleTimeString('pt-PT') + '.' : '');
  }
  document.getElementById('cn-rows').addEventListener('click', function (e) {
    var b = e.target.closest('[data-block]'); if (!b) return;
    document.getElementById('blk-ip').value = b.getAttribute('data-block');
    document.getElementById('dlg-block').showModal();
  });
  q.addEventListener('input', render);
  function poll() {
    fetch('?stats=conns', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) { if (d && d.ts) { data = d; render(); } })
      .catch(function () {}).then(function () { setTimeout(poll, 5000); });
  }
  render(); setTimeout(poll, 5000);
})();
</script>
<?php endif; ?>
<?php if ($page === 'recursos' || $page === 'resumo'): ?>
<script>
(function () {
  function dec(v, d) { return Number(v || 0).toFixed(d === undefined ? 1 : d).replace('.', ','); }
  function bytes(b) { var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b || 0); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function bps(b) { var u = ['b/s', 'Kb/s', 'Mb/s', 'Gb/s'], i = 0; b = Number(b || 0); while (b >= 1000 && i < 3) { b /= 1000; i++; } return (i ? b.toFixed(1).replace('.', ',') : Math.round(b)) + ' ' + u[i]; }
  function fmt(v, f) { return f === 'pct' ? dec(v) + '%' : f === 'bps' ? bps(v) : dec(v, 2); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function set(k, t) { document.querySelectorAll('[data-l="' + k + '"]').forEach(function (e) { e.textContent = t; }); }
  function bar(k, v) { document.querySelectorAll('[data-lm="' + k + '"]').forEach(function (e) { e.style.width = Math.max(0, Math.min(100, v)) + '%'; e.classList.toggle('hi', v >= 90); }); }
  function upd() {
    fetch('?stats=live', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { if (r.status === 401) { location.reload(); return null; } return r.json(); })
      .then(function (d) {
        if (!d || !d.ts) return;
        set('cpu', dec(d.cpu) + '%'); bar('cpu', d.cpu);
        set('mem', dec(d.mem.pct) + '%'); set('mem-sub', bytes(d.mem.used * 1024) + ' / ' + bytes(d.mem.total * 1024)); bar('mem', d.mem.pct);
        set('disk', dec(d.disk.pct) + '%'); set('disk-sub', bytes(d.disk.used * 1024) + ' / ' + bytes(d.disk.total * 1024)); bar('disk', d.disk.pct);
        set('load', dec(d.load[0], 2)); set('load-sub', '5 min ' + dec(d.load[1], 2) + ' · 15 min ' + dec(d.load[2], 2));
        set('swap', 'Swap ' + dec(d.swap.pct) + '%');
        set('net', bps(d.net.rx + d.net.tx)); set('net-sub', '↓ ' + bps(d.net.rx) + ' · ↑ ' + bps(d.net.tx));
        document.querySelectorAll('[data-ls]').forEach(function (e) {
          var p = e.getAttribute('data-ls').split(':'), s = (d.sites || {})[p[0]] || { cpu: 0, rss: 0 };
          e.textContent = p[1] === 'cpu' ? dec(s.cpu) + '%' : bytes(s.rss * 1024);
        });
      })
      .catch(function () {})
      .then(function () { setTimeout(upd, 5000); });
  }
  if (document.querySelector('[data-live]')) setTimeout(upd, 5000);

  document.querySelectorAll('.chart').forEach(function (c) {
    var d; try { d = JSON.parse(c.getAttribute('data-chart')); } catch (e) { return; }
    if (!d.t || d.t.length < 2) return;
    var plot = c.querySelector('.ch-plot'), cur = c.querySelector('.ch-cur'), tip = c.querySelector('.ch-tip');
    function two(n) { return (n < 10 ? '0' : '') + n; }
    plot.addEventListener('mousemove', function (e) {
      var r = plot.getBoundingClientRect(), t = d.from + (d.to - d.from) * ((e.clientX - r.left) / r.width);
      var lo = 0, hi = d.t.length - 1;
      while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (d.t[mid] < t) lo = mid; else hi = mid; }
      var i = Math.abs(d.t[lo] - t) <= Math.abs(d.t[hi] - t) ? lo : hi;
      var x = (d.t[i] - d.from) / (d.to - d.from) * 100;
      cur.style.left = x + '%'; cur.style.display = 'block';
      var dt = new Date((d.t[i] + d.tz) * 1000);
      var lab = two(dt.getUTCDate()) + '/' + two(dt.getUTCMonth() + 1) + ' ' + two(dt.getUTCHours()) + ':' + two(dt.getUTCMinutes());
      tip.innerHTML = '<b>' + lab + '</b>' + d.s.map(function (s) { return '<div><i style="background:' + esc(s.c) + '"></i>' + esc(s.n) + ': ' + fmt(s.v[i], d.fmt) + '</div>'; }).join('');
      tip.style.display = 'block';
      if (x > 60) { tip.style.left = ''; tip.style.right = (100 - x) + '%'; } else { tip.style.right = ''; tip.style.left = x + '%'; }
    });
    plot.addEventListener('mouseleave', function () { cur.style.display = 'none'; tip.style.display = 'none'; });
  });
})();
</script>
<?php endif; ?>
<?php if ($page === 'ficheiros' && !empty($fmSite)): ?>
<script>
(function () {
  var root = document.getElementById('fm'); if (!root) return;
  var IC = <?= json_encode(['dir' => ic('folder', 'dir'), 'zip' => ic('zip', 'zip'), 'code' => ic('code', 'code'), 'file' => ic('file', 'file'), 'up' => ic('up', 'file'), 'dots' => ic('dots'), 'home' => ic('home'), 'open' => ic('folder'), 'dl' => ic('download'), 'edit' => ic('edit'), 'ren' => ic('edit'), 'move' => ic('move'), 'zipb' => ic('zip'), 'perm' => ic('lock'), 'del' => ic('trash'), 'x' => ic('x')], JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) ?>;
  var $ = function (id) { return document.getElementById(id); };
  var st = { site: root.getAttribute('data-site'), path: '', items: [], sel: {} };
  var EDIT = /(\.(php|phtml|inc|html?|css|scss|js|mjs|json|txt|md|xml|svg|ini|conf|env|log|csv|sql|ya?ml|twig|tpl|sh|py|htaccess|htpasswd|user\.ini)|^\.[a-z]+)$/i;
  var ARCH = /\.(zip|tar|tgz|tar\.gz|tar\.bz2)$/i;
  var CH = 8 * 1024 * 1024;

  function base(site) { return '/ficheiros/' + encodeURIComponent(site || st.site) + '/'; }
  function join(a, b) { return a ? (b ? a + '/' + b : a) : b; }
  function enc(s) { return encodeURIComponent(s); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function bytes(b) { if (b === null || b === undefined) return '—'; var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0; b = Number(b); while (b >= 1024 && i < 4) { b /= 1024; i++; } return (i ? b.toFixed(1).replace('.', ',') : b) + ' ' + u[i]; }
  function two(n) { return (n < 10 ? '0' : '') + n; }
  function when(t) { var d = new Date(t * 1000); return two(d.getDate()) + '/' + two(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + two(d.getHours()) + ':' + two(d.getMinutes()); }
  function toast(ok, msg) {
    var box = document.querySelector('.toasts'); if (!box) return;
    var t = document.createElement('div'); t.className = 'toast ' + (ok ? 'ok' : 'err');
    t.innerHTML = '<span class="ti">' + (ok ? '✓' : '!') + '</span><div class="msg"></div><button type="button" data-dismiss aria-label="Fechar">' + IC.x + '</button>';
    t.querySelector('.msg').textContent = msg; box.appendChild(t);
    if (ok) setTimeout(function () { t.remove(); }, 5000);
  }
  function api(a, data, q, site) {
    var init = { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' };
    if (data instanceof FormData) { init.method = 'POST'; init.body = data; }
    else if (data) { init.method = 'POST'; init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(data); }
    return fetch(base(site) + '?a=' + a + (q ? '&' + q : ''), init).then(function (r) {
      if (r.redirected && r.url.indexOf('/ficheiros/') === -1) { location.reload(); throw new Error('A sessão expirou.'); }
      return r.json().catch(function () { throw new Error('Resposta inválida do servidor (' + r.status + ').'); })
        .then(function (j) { j._s = r.status; return j; });
    });
  }
  function must(j) { if (!j.ok) { var e = new Error(j.error || 'Falhou.'); e.j = j; throw e; } return j; }
  function fail(e) { toast(false, e.message || String(e)); }

  /* ---------- diálogo ---------- */
  function ask(title, msg, value, okLabel, danger) {
    var d = $('fm-dlg'), inp = $('fm-dlg-in'), ok = $('fm-dlg-ok');
    $('fm-dlg-t').textContent = title; $('fm-dlg-msg').textContent = msg || '';
    $('fm-dlg-msg').hidden = !msg;
    inp.hidden = value === null; inp.value = value === null ? '' : value;
    ok.textContent = okLabel || 'OK'; ok.className = 'btn' + (danger ? ' dan' : '');
    d.returnValue = ''; d.showModal();
    if (value !== null) { inp.focus(); var dot = inp.value.lastIndexOf('.'); inp.setSelectionRange(0, dot > 0 ? dot : inp.value.length); } else ok.focus();
    return new Promise(function (res) {
      d.addEventListener('close', function h() { d.removeEventListener('close', h); res(d.returnValue === 'ok' ? (value === null ? true : inp.value.trim()) : null); });
    });
  }

  /* ---------- listagem ---------- */
  function setUrl() { var u = '?p=ficheiros&site=' + enc(st.site) + (st.path ? '&dir=' + enc(st.path) : ''); history.replaceState(null, '', u); }
  function load(path) {
    if (path !== undefined) { st.path = path; st.sel = {}; }
    return api('list', null, 'p=' + enc(st.path)).then(must).then(function (j) {
      st.items = j.items; render(j.free);
    }).catch(function (e) {
      if (st.path) { toast(false, e.message); st.path = ''; return load(); }
      $('fm-rows').innerHTML = '<tr><td colspan="5" class="empty"></td></tr>';
      $('fm-rows').querySelector('td').textContent = e.message;
    }).then(setUrl);
  }
  function kind(it) { return it.d ? 'dir' : ARCH.test(it.n) ? 'zip' : EDIT.test(it.n) ? 'code' : 'file'; }
  function render(free) {
    var tb = $('fm-rows'), h = '';
    if (st.path) h += '<tr data-up="1"><td class="first" colspan="5"><button type="button" class="fm-name" data-act="up">' + IC.up + '<span>.. (pasta acima)</span></button></td></tr>';
    st.items.forEach(function (it, i) {
      h += '<tr data-i="' + i + '"' + (st.sel[it.n] ? ' class="sel"' : '') + '>' +
        '<td class="first" data-label="Nome"><div class="fm-first"><label class="fm-ck"><input type="checkbox"' + (st.sel[it.n] ? ' checked' : '') + ' aria-label="Selecionar ' + esc(it.n) + '"></label>' +
        '<button type="button" class="fm-name" data-act="open">' + IC[kind(it)] + '<span>' + esc(it.n) + (it.l ? ' ↪' : '') + '</span></button></div></td>' +
        '<td class="r mu" data-label="Tamanho">' + (it.d ? '—' : bytes(it.s)) + '</td>' +
        '<td class="mu" data-label="Modificado">' + when(it.m) + '</td>' +
        '<td class="mono mu" data-label="Permissões">' + esc(it.p.replace(/^0(?=\d{3}$)/, '')) + '</td>' +
        '<td class="act r"><button type="button" class="iconbtn" data-act="menu" aria-label="Ações de ' + esc(it.n) + '">' + IC.dots + '</button></td></tr>';
    });
    if (!st.items.length) h += '<tr><td colspan="5" class="empty">Pasta vazia. Arrasta ficheiros para aqui ou usa “Enviar ficheiros”.</td></tr>';
    tb.innerHTML = h;
    crumbs(); selbar();
    var nd = st.items.filter(function (i) { return i.d; }).length;
    $('fm-foot').textContent = nd + ' pasta(s), ' + (st.items.length - nd) + ' ficheiro(s)' + (free ? ' · ' + bytes(free) + ' livres no disco' : '') + ' · arrasta ficheiros ou pastas para a lista para os enviar';
  }
  function crumbs() {
    var c = $('fm-crumbs'), parts = st.path ? st.path.split('/') : [], h = '<button type="button" data-path="">' + IC.home + esc(st.site) + '</button>';
    parts.forEach(function (p, i) { h += '<span class="sep">/</span><button type="button" data-path="' + esc(parts.slice(0, i + 1).join('/')) + '">' + esc(p) + '</button>'; });
    c.innerHTML = h;
  }
  function selected() { return Object.keys(st.sel); }
  function selbar() {
    var n = selected().length;
    $('fm-selbar').hidden = n === 0;
    $('fm-selcount').textContent = n === 1 ? '1 item selecionado' : n + ' itens selecionados';
    $('fm-all').checked = n > 0 && n === st.items.length;
  }

  /* ---------- ações ---------- */
  function done(msg) { return function (j) { must(j); if (msg) toast(true, typeof msg === 'function' ? msg(j) : msg); return load(); }; }
  function download(it) {
    var a = document.createElement('a'); a.href = base() + '?a=dl&p=' + enc(join(st.path, it.n)); a.download = it.n;
    document.body.appendChild(a); a.click(); a.remove();
  }
  function open(it) {
    if (it.d) return load(join(st.path, it.n));
    if (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n) && it.n.indexOf('.') === -1) return edit(join(st.path, it.n));
    download(it);
  }
  function act(name, items) {
    var p = st.path;
    if (name === 'mkdir' || name === 'newfile') {
      return ask(name === 'mkdir' ? 'Nova pasta' : 'Novo ficheiro', 'Em /' + p, '', 'Criar').then(function (v) {
        if (!v) return;
        return api(name, { p: p, name: v }).then(must).then(function () {
          return load().then(function () { if (name === 'newfile') edit(join(p, v)); });
        });
      }).catch(fail);
    }
    if (!items.length) return;
    var one = items.length === 1 ? items[0] : null;
    var label = one ? '“' + one + '”' : items.length + ' itens';
    if (name === 'rename') {
      return ask('Mudar o nome', null, one, 'Mudar nome').then(function (v) { if (!v || v === one) return; return api('rename', { p: p, from: one, to: v }).then(done('Nome alterado.')); }).catch(fail);
    }
    if (name === 'move') {
      return ask('Mover ' + label, 'Pasta de destino, a partir da raiz do site (ex.: public_html/img). Vazio = raiz do site.', p, 'Mover').then(function (v) {
        if (v === null) return; return api('move', { p: p, items: items, to: v }).then(done('Movido para /' + v + '.'));
      }).catch(fail);
    }
    if (name === 'zip') {
      return ask('Compactar ' + label, 'Nome do ficheiro ZIP, criado nesta pasta.', (one || 'arquivo') + '.zip', 'Compactar').then(function (v) {
        if (!v) return; toast(true, 'A compactar…'); return api('zip', { p: p, items: items, name: v }).then(done(function (j) { return 'Criado ' + j.name + ' (' + j.count + ' ficheiros).'; }));
      }).catch(fail);
    }
    if (name === 'chmod') {
      var cur = one ? (st.items.filter(function (i) { return i.n === one; })[0] || {}).p : '';
      return ask('Permissões de ' + label, 'Em octal, por exemplo 640 para ficheiros e 2750 para pastas.', (cur || '640').replace(/^0(?=\d{3}$)/, ''), 'Aplicar').then(function (v) {
        if (!v) return; return api('chmod', { p: p, items: items, mode: v }).then(done('Permissões alteradas.'));
      }).catch(fail);
    }
    if (name === 'delete') {
      return ask('Apagar ' + label + '?', 'As pastas são apagadas com todo o conteúdo. Esta ação não pode ser anulada.', null, 'Apagar', true).then(function (ok) {
        if (!ok) return; return api('delete', { p: p, items: items }).then(done(items.length === 1 ? 'Apagado.' : items.length + ' itens apagados.'));
      }).catch(fail);
    }
    if (name === 'extract' || name === 'extractto') {
      var into = name === 'extractto' ? ask('Extrair para uma pasta', 'Nome da pasta a criar nesta localização.', one.replace(ARCH, ''), 'Extrair') : Promise.resolve('');
      return into.then(function (v) {
        if (v === null) return; toast(true, 'A extrair ' + one + '…');
        return api('extract', { p: join(p, one), into: v }).then(done(function (j) { return j.count + ' ficheiro(s) extraído(s)' + (j.skipped ? '; ' + j.skipped + ' ignorado(s) por segurança' : '') + '.'; }));
      }).catch(fail);
    }
  }

  /* ---------- menu de cada item ---------- */
  var menu = $('fm-menu');
  function hideMenu() { menu.hidden = true; }
  function showMenu(it, btn) {
    var o = [];
    if (it.d) o.push(['open', IC.open, 'Abrir']); else o.push(['dl', IC.dl, 'Descarregar']);
    if (!it.d && (EDIT.test(it.n) || it.s < 2097152 && !ARCH.test(it.n))) o.push(['edit', IC.edit, 'Editar']);
    if (ARCH.test(it.n)) { o.push(['extract', IC.zipb, 'Extrair aqui']); o.push(['extractto', IC.zipb, 'Extrair para pasta…']); }
    o.push(['rename', IC.ren, 'Mudar o nome'], ['move', IC.move, 'Mover…'], ['zip', IC.zipb, 'Compactar em ZIP'], ['chmod', IC.perm, 'Permissões'], ['-'], ['delete', IC.del, 'Apagar']);
    menu.innerHTML = o.map(function (x) { return x[0] === '-' ? '<hr>' : '<button type="button" data-m="' + x[0] + '"' + (x[0] === 'delete' ? ' class="dan"' : '') + '>' + x[1] + x[2] + '</button>'; }).join('');
    menu.hidden = false;
    var r = btn.getBoundingClientRect(), mh = menu.offsetHeight, mw = menu.offsetWidth;
    menu.style.left = Math.max(8, Math.min(window.innerWidth - mw - 8, r.right - mw)) + 'px';
    menu.style.top = (r.bottom + mh + 8 > window.innerHeight ? Math.max(8, r.top - mh - 6) : r.bottom + 6) + 'px';
    menu.onclick = function (e) {
      var b = e.target.closest('[data-m]'); if (!b) return; hideMenu();
      var m = b.getAttribute('data-m');
      if (m === 'open') load(join(st.path, it.n));
      else if (m === 'dl') download(it);
      else if (m === 'edit') edit(join(st.path, it.n));
      else act(m, [it.n]);
    };
  }
  document.addEventListener('click', function (e) { if (!menu.hidden && !e.target.closest('#fm-menu') && !e.target.closest('[data-act="menu"]')) hideMenu(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hideMenu(); });
  window.addEventListener('scroll', hideMenu, true);

  $('fm-rows').addEventListener('click', function (e) {
    var tr = e.target.closest('tr'); if (!tr) return;
    if (tr.getAttribute('data-up')) { var parts = st.path.split('/'); parts.pop(); load(parts.join('/')); return; }
    var it = st.items[+tr.getAttribute('data-i')]; if (!it) return;
    var b = e.target.closest('[data-act]');
    if (b && b.getAttribute('data-act') === 'open') open(it);
    else if (b && b.getAttribute('data-act') === 'menu') { e.stopPropagation(); if (!menu.hidden) hideMenu(); else showMenu(it, b); }
  });
  $('fm-rows').addEventListener('change', function (e) {
    var tr = e.target.closest('tr'); var it = tr && st.items[+tr.getAttribute('data-i')]; if (!it) return;
    if (e.target.checked) st.sel[it.n] = 1; else delete st.sel[it.n];
    tr.classList.toggle('sel', e.target.checked); selbar();
  });
  $('fm-all').addEventListener('change', function (e) { st.sel = {}; if (e.target.checked) st.items.forEach(function (i) { st.sel[i.n] = 1; }); render(); });
  $('fm-crumbs').addEventListener('click', function (e) { var b = e.target.closest('[data-path]'); if (b) load(b.getAttribute('data-path')); });
  $('fm-site').addEventListener('change', function (e) { st.site = e.target.value; load(''); });
  root.addEventListener('click', function (e) {
    var b = e.target.closest('[data-fm]'); if (!b) return;
    var n = b.getAttribute('data-fm');
    if (n === 'clear') { st.sel = {}; render(); return; }
    act(n, n === 'mkdir' || n === 'newfile' ? [] : selected());
  });

  /* ---------- editor ---------- */
  var ed = { path: null, dirty: false }, ta = $('fm-ed-ta'), edDlg = $('fm-ed');
  function edStatus(t) { $('fm-ed-st').textContent = t; }
  function edit(rel) {
    api('get', null, 'p=' + enc(rel)).then(must).then(function (j) {
      ed.path = rel; ed.dirty = false; ta.value = j.content; $('fm-ed-t').textContent = '/' + rel; edStatus('');
      edDlg.showModal(); ta.focus(); ta.setSelectionRange(0, 0); ta.scrollTop = 0;
    }).catch(fail);
  }
  function save() {
    if (!ed.path) return;
    edStatus('A gravar…');
    api('save', { p: ed.path, content: ta.value }).then(must).then(function () {
      ed.dirty = false; var d = new Date(); edStatus('Gravado às ' + two(d.getHours()) + ':' + two(d.getMinutes()) + ':' + two(d.getSeconds()));
      load();
    }).catch(function (e) { edStatus(''); fail(e); });
  }
  function edClose() { if (ed.dirty && !window.confirm('Há alterações por gravar. Fechar sem gravar?')) return; ed.dirty = false; edDlg.close(); }
  ta.addEventListener('input', function () { if (!ed.dirty) { ed.dirty = true; edStatus('Alterações por gravar'); } });
  ta.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
    else if (e.key === 'Tab' && !e.shiftKey) { e.preventDefault(); ta.setRangeText('\t', ta.selectionStart, ta.selectionEnd, 'end'); ta.dispatchEvent(new Event('input')); }
  });
  $('fm-ed-save').addEventListener('click', save);
  $('fm-ed-close').addEventListener('click', edClose);
  $('fm-ed-x').addEventListener('click', edClose);
  edDlg.addEventListener('cancel', function (e) { e.preventDefault(); edClose(); });
  window.addEventListener('beforeunload', function (e) { if (ed.dirty || busy) { e.preventDefault(); e.returnValue = ''; } });

  /* ---------- envios por partes, com retoma ---------- */
  var Q = [], busy = false;
  function hash(s) { var h1 = 0x811c9dc5, h2 = 0x01000193; for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); h1 = Math.imul(h1 ^ c, 16777619) >>> 0; h2 = Math.imul(h2 ^ c, 2246822519) >>> 0; } return ('0000000' + h1.toString(16)).slice(-8) + ('0000000' + h2.toString(16)).slice(-8); }
  function upsSummary() {
    var n = Q.length, ok = Q.filter(function (j) { return j.state === 'ok'; }).length, er = Q.filter(function (j) { return j.state === 'err'; }).length;
    $('fm-ups-sum').textContent = ok + ' de ' + n + ' concluído(s)' + (er ? ', ' + er + ' com erro' : '');
  }
  function upRow(job) {
    var d = document.createElement('div'); d.className = 'up';
    d.innerHTML = '<div class="nm2"><span></span><span>em espera</span></div><div class="bar"><i></i></div>';
    d.querySelector('span').textContent = job.rel; $('fm-ups-list').appendChild(d); return d;
  }
  function upSet(job, pct, txt, cls) {
    job.ui.querySelector('i').style.width = pct + '%';
    job.ui.querySelector('.nm2 span:last-child').textContent = txt;
    if (cls) job.ui.className = 'up ' + cls;
  }
  function enqueue(list) {
    if (!list.length) return;
    var p = st.path, site = st.site, names = {};
    st.items.forEach(function (i) { names[i.n] = 1; });
    var clash = list.filter(function (f) { return names[f.rel.split('/')[0]]; }).length;
    var go = clash ? ask('Substituir ficheiros?', clash + ' ficheiro(s) ou pasta(s) com o mesmo nome já existem nesta pasta. Os ficheiros existentes serão substituídos.', null, 'Substituir', true) : Promise.resolve(true);
    go.then(function (ok) {
      if (!ok) return;
      list.forEach(function (f) {
        var job = { f: f.file, rel: f.rel, dir: p, site: site, ow: !!clash, tries: 0, state: 'wait' };
        job.id = 'u' + hash(site + '|' + p + '|' + f.rel + '|' + f.file.size + '|' + f.file.lastModified);
        job.ui = upRow(job); Q.push(job);
      });
      $('fm-ups').hidden = false; upsSummary(); pump();
    });
  }
  function pump() {
    if (busy) return;
    var job = Q.filter(function (j) { return j.state === 'wait'; })[0];
    if (!job) { upsSummary(); if (job === undefined) load(); return; }
    busy = true; job.state = 'run';
    run(job).then(function () { busy = false; upsSummary(); pump(); });
  }
  function run(job) {
    var b = base(job.site);
    function send(off) {
      var fd = new FormData();
      fd.append('id', job.id); fd.append('p', job.dir); fd.append('name', job.rel);
      fd.append('offset', off); fd.append('total', job.f.size);
      if (job.ow) fd.append('overwrite', '1');
      fd.append('chunk', job.f.slice(off, Math.min(off + CH, job.f.size)), 'chunk');
      return fetch(b + '?a=upload', { method: 'POST', credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, body: fd })
        .then(function (r) { if (r.redirected) { location.reload(); throw new Error('A sessão expirou.'); } return r.json().then(function (j) { return { s: r.status, j: j }; }); });
    }
    function loop(off) {
      upSet(job, job.f.size ? Math.floor(off * 100 / job.f.size) : 0, bytes(off) + ' de ' + bytes(job.f.size));
      return send(off).then(function (res) {
        var j = res.j;
        if (j.ok && j.done) { job.state = 'ok'; upSet(job, 100, 'concluído', 'ok'); return; }
        if (j.ok) { job.tries = 0; return loop(j.size); }
        if (j.exists) { var e = new Error(j.error); e.fatal = true; throw e; }
        if (res.s === 409 && typeof j.size === 'number') return loop(j.size);
        throw new Error(j.error || 'Falha no envio.');
      });
    }
    return fetch(b + '?a=upstat&id=' + job.id, { credentials: 'same-origin', headers: { 'X-MP-Request': '1' }, cache: 'no-store' })
      .then(function (r) { return r.json(); }).then(function (j) { return loop(j.size || 0); })
      .catch(function (e) {
        job.tries++;
        if (!e.fatal && job.tries <= 6) {
          upSet(job, 0, 'a retomar (' + job.tries + ')…');
          return new Promise(function (r) { setTimeout(r, 1500 * job.tries); }).then(function () { return run(job); });
        }
        job.state = 'err'; upSet(job, 100, e.message || 'erro', 'err');
      });
  }
  $('fm-ups-close').addEventListener('click', function () {
    if (busy && !window.confirm('Há envios em curso. Esconder o painel de envios? Os envios continuam.')) return;
    if (!busy) { Q = Q.filter(function (j) { return j.state === 'wait' || j.state === 'run'; }); $('fm-ups-list').innerHTML = ''; }
    $('fm-ups').hidden = true;
  });
  function fromInput(input) {
    var list = Array.prototype.map.call(input.files, function (f) { return { file: f, rel: f.webkitRelativePath || f.name }; });
    input.value = ''; enqueue(list);
  }
  $('fm-upfiles').addEventListener('change', function (e) { fromInput(e.target); });
  $('fm-updir').addEventListener('change', function (e) { fromInput(e.target); });

  var drop = $('fm-drop'), depth = 0;
  function walk(en, pre) {
    if (en.isFile) return new Promise(function (res) { en.file(function (f) { res([{ file: f, rel: pre + f.name }]); }, function () { res([]); }); });
    if (!en.isDirectory) return Promise.resolve([]);
    var rd = en.createReader(), all = [];
    return new Promise(function (res) {
      (function next() {
        rd.readEntries(function (list) {
          if (!list.length) {
            Promise.all(all.map(function (c) { return walk(c, pre + en.name + '/'); })).then(function (a) { res([].concat.apply([], a)); });
          } else { all = all.concat(Array.prototype.slice.call(list)); next(); }
        }, function () { res([]); });
      })();
    });
  }
  drop.addEventListener('dragenter', function (e) { if (e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') >= 0) { depth++; drop.classList.add('over'); } });
  drop.addEventListener('dragover', function (e) { e.preventDefault(); });
  drop.addEventListener('dragleave', function () { if (--depth <= 0) { depth = 0; drop.classList.remove('over'); } });
  drop.addEventListener('drop', function (e) {
    e.preventDefault(); depth = 0; drop.classList.remove('over');
    var dt = e.dataTransfer, items = dt.items;
    if (items && items.length && items[0].webkitGetAsEntry) {
      var entries = [];
      for (var i = 0; i < items.length; i++) { var en = items[i].webkitGetAsEntry(); if (en) entries.push(en); }
      Promise.all(entries.map(function (en) { return walk(en, ''); })).then(function (a) { enqueue([].concat.apply([], a)); });
    } else {
      enqueue(Array.prototype.map.call(dt.files, function (f) { return { file: f, rel: f.name }; }));
    }
  });

  load(root.getAttribute('data-dir') || '');
})();
</script>
<?php endif; ?>
</body>
</html>
MPPANEL
chown -R root:root /opt/minipainel/public
chmod 644 /opt/minipainel/public/index.php

say "A instalar o gestor de ficheiros..."
install -d -o root -g root -m 755 /opt/minipainel/files
cat > /opt/minipainel/files/index.php <<'MPFILES'
<?php
/**
 * IDDigital Hosting v1.8.0 — gestor de ficheiros (API)
 * Corre num pool PHP-FPM próprio de cada site, como o utilizador do site (mp_<site>),
 * preso à pasta /srv/www/<site> por open_basedir. O acesso é protegido pela sessão
 * do painel (auth_request no nginx) e os pedidos de escrita exigem o cabeçalho
 * X-MP-Request, que um formulário de outro site não consegue enviar.
 */
declare(strict_types=1);

const FM_MAX_EDIT = 2097152;   // 2 MB
const FM_ESSENTIAL = ['public_html', 'logs', 'tmp'];

header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; sandbox");

function fm_json(array $d, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fm_fail(int $code, string $m, array $extra = []): void { fm_json(['ok' => false, 'error' => $m] + $extra, $code); }

$site = (string)($_SERVER['MP_FM_SITE'] ?? '');
if (!preg_match('/^[a-z][a-z0-9-]{0,23}$/', $site)) fm_fail(400, 'Site inválido.');
$ROOT = realpath('/srv/www/' . $site);
if ($ROOT === false || !is_dir($ROOT)) fm_fail(404, 'A pasta do site não foi encontrada.');
umask(0027);

/* ---------- caminhos ---------- */
function fm_rel(string $p): string {
    $p = str_replace('\\', '/', $p);
    if (strpos($p, "\0") !== false) fm_fail(400, 'Caminho inválido.');
    $out = [];
    foreach (explode('/', $p) as $seg) {
        if ($seg === '' || $seg === '.') continue;
        if ($seg === '..') fm_fail(400, 'Caminho inválido.');
        if (strlen($seg) > 255) fm_fail(400, 'Nome demasiado longo.');
        $out[] = $seg;
    }
    return implode('/', $out);
}
function fm_join(string $a, string $b): string { return $a === '' ? $b : ($b === '' ? $a : $a . '/' . $b); }
function fm_inside(string $real): bool { global $ROOT; return $real === $ROOT || strpos($real, $ROOT . '/') === 0; }
/* Caminho existente, seguindo ligações simbólicas (para ler e listar) */
function fm_abs(string $rel): string {
    global $ROOT;
    $real = realpath($rel === '' ? $ROOT : $ROOT . '/' . $rel);
    if ($real === false) fm_fail(404, 'Não encontrado: /' . $rel);
    if (!fm_inside($real)) fm_fail(403, 'Fora da pasta do site.');
    return $real;
}
/* Entrada a alterar (não segue a ligação final: apagar uma ligação apaga só a ligação) */
function fm_entry(string $rel, bool $mustExist = true): string {
    global $ROOT;
    if ($rel === '') fm_fail(400, 'Operação não permitida na raiz do site.');
    $parent = realpath(dirname($ROOT . '/' . $rel));
    if ($parent === false || !fm_inside($parent)) fm_fail(403, 'Fora da pasta do site.');
    $abs = $parent . '/' . basename($rel);
    if ($mustExist && !file_exists($abs) && !is_link($abs)) fm_fail(404, 'Não encontrado: /' . $rel);
    return $abs;
}
function fm_name(string $n): string {
    $n = trim($n);
    if ($n === '' || $n === '.' || $n === '..' || strpos($n, '/') !== false || strpos($n, '\\') !== false || strpos($n, "\0") !== false || strlen($n) > 255) {
        fm_fail(400, 'Nome inválido.');
    }
    return $n;
}
function fm_fix(string $abs): void {
    if (is_link($abs)) return;
    @chmod($abs, is_dir($abs) ? 02750 : 0640);
}
function fm_mkdirs(string $abs): void {
    if (is_dir($abs)) return;
    fm_mkdirs(dirname($abs));
    if (!@mkdir($abs) && !is_dir($abs)) fm_fail(500, 'Não foi possível criar a pasta ' . basename($abs) . '.');
    fm_fix($abs);
}
function fm_rrm(string $p): bool {
    if (is_link($p) || !is_dir($p)) return @unlink($p);
    $ok = true;
    foreach ((array)@scandir($p) as $e) {
        if ($e === '.' || $e === '..' || $e === false) continue;
        $ok = fm_rrm($p . '/' . $e) && $ok;
    }
    return @rmdir($p) && $ok;
}
function fm_essential(string $rel): bool { return strpos($rel, '/') === false && in_array($rel, FM_ESSENTIAL, true); }

/* ---------- entrada ---------- */
$a = (string)($_GET['a'] ?? '');
$method = (string)($_SERVER['REQUEST_METHOD'] ?? 'GET');
$in = [];
if ($method === 'POST') {
    if ((string)($_SERVER['HTTP_X_MP_REQUEST'] ?? '') !== '1') fm_fail(403, 'Pedido recusado.');
    $in = $_POST;
    if (stripos((string)($_SERVER['CONTENT_TYPE'] ?? ''), 'application/json') === 0) {
        $j = json_decode((string)file_get_contents('php://input'), true);
        $in = is_array($j) ? $j : [];
    }
}
function in_s(array $in, string $k): string { $v = $in[$k] ?? ''; return is_string($v) || is_int($v) ? (string)$v : ''; }
function in_list(array $in, string $k): array { $v = $in[$k] ?? []; return is_array($v) ? array_values(array_filter($v, 'is_string')) : []; }
function q(string $k): string { $v = $_GET[$k] ?? ''; return is_string($v) ? $v : ''; }

$readOnly = ['list', 'get', 'dl', 'upstat'];
if ($method !== 'POST' && !in_array($a, $readOnly, true)) fm_fail(405, 'Método não permitido.');

switch ($a) {

case 'list':
    $rel = fm_rel(q('p'));
    $dir = fm_abs($rel);
    if (!is_dir($dir)) fm_fail(400, 'Não é uma pasta.');
    $dh = @opendir($dir);
    if ($dh === false) fm_fail(403, 'Sem permissão para ler esta pasta.');
    $items = [];
    while (($e = readdir($dh)) !== false) {
        if ($e === '.' || $e === '..') continue;
        $f = $dir . '/' . $e;
        $st = @lstat($f);
        if ($st === false) continue;
        $link = is_link($f);
        $isDir = is_dir($f);
        $items[] = [
            'n' => $e, 'd' => $isDir, 'l' => $link,
            's' => $isDir ? null : ($link ? @filesize($f) : $st['size']),
            'm' => $st['mtime'], 'p' => sprintf('%04o', $st['mode'] & 07777),
        ];
    }
    closedir($dh);
    usort($items, function ($x, $y) { return $x['d'] === $y['d'] ? strnatcasecmp($x['n'], $y['n']) : ($x['d'] ? -1 : 1); });
    $free = @disk_free_space($dir);
    fm_json(['ok' => true, 'path' => $rel, 'items' => $items, 'free' => $free === false ? null : $free]);

case 'get':
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f)) fm_fail(400, 'Não é um ficheiro.');
    if ((int)filesize($f) > FM_MAX_EDIT) fm_fail(413, 'O ficheiro tem mais de 2 MB; descarrega-o para editar.');
    $c = @file_get_contents($f);
    if ($c === false) fm_fail(403, 'Sem permissão para ler o ficheiro.');
    if (strpos($c, "\0") !== false || !preg_match('//u', $c)) fm_fail(415, 'É um ficheiro binário ou não está em UTF-8; não pode ser editado aqui.');
    fm_json(['ok' => true, 'content' => $c, 'm' => filemtime($f)]);

case 'dl':
    $f = fm_abs(fm_rel(q('p')));
    if (!is_file($f) || !is_readable($f)) fm_fail(404, 'Ficheiro não encontrado.');
    @set_time_limit(0);
    while (ob_get_level() > 0) ob_end_clean();
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . (string)filesize($f));
    header("Content-Disposition: attachment; filename*=UTF-8''" . rawurlencode(basename($f)));
    readfile($f);
    exit;

case 'upstat':
    $id = q('id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $part = $ROOT . '/tmp/.mp-up-' . $id . '.part';
    fm_json(['ok' => true, 'size' => is_file($part) ? filesize($part) : 0]);

case 'mkdir':
case 'newfile':
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $t = $dir . '/' . fm_name(in_s($in, 'name'));
    if (file_exists($t) || is_link($t)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    $ok = $a === 'mkdir' ? @mkdir($t) : (@file_put_contents($t, '') !== false);
    if (!$ok) fm_fail(500, 'Não foi possível criar.');
    fm_fix($t);
    fm_json(['ok' => true]);

case 'rename':
    $p = fm_rel(in_s($in, 'p'));
    $from = fm_name(in_s($in, 'from'));
    $to = fm_name(in_s($in, 'to'));
    if (fm_essential(fm_join($p, $from))) fm_fail(403, 'Esta pasta é essencial para o site e não pode mudar de nome.');
    $src = fm_entry(fm_join($p, $from));
    $dst = fm_entry(fm_join($p, $to), false);
    if (file_exists($dst) || is_link($dst)) fm_fail(409, 'Já existe um ficheiro ou pasta com esse nome.');
    if (!@rename($src, $dst)) fm_fail(500, 'Não foi possível mudar o nome.');
    fm_json(['ok' => true]);

case 'move':
    $p = fm_rel(in_s($in, 'p'));
    $destRel = fm_rel(in_s($in, 'to'));
    $dest = fm_abs($destRel);
    if (!is_dir($dest)) fm_fail(400, 'O destino não é uma pasta.');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial'; continue; }
        $src = fm_entry($rel);
        $real = realpath($src);
        if ($real !== false && is_dir($src) && !is_link($src) && ($dest === $real || strpos($dest . '/', $real . '/') === 0)) { $errors[] = $it . ': não pode ir para dentro de si própria'; continue; }
        $t = $dest . '/' . basename($src);
        if (file_exists($t) || is_link($t)) { $errors[] = $it . ': já existe no destino'; continue; }
        if (!@rename($src, $t)) $errors[] = $it . ': falhou';
    }
    if ($errors) fm_fail(409, "Alguns itens não foram movidos:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'delete':
    $p = fm_rel(in_s($in, 'p'));
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $rel = fm_join($p, fm_name($it));
        if (fm_essential($rel)) { $errors[] = $it . ': pasta essencial do site'; continue; }
        if (!fm_rrm(fm_entry($rel))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível apagar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'save':
    $rel = fm_rel(in_s($in, 'p'));
    $f = fm_entry($rel, false);
    $content = in_s($in, 'content');
    if (strlen($content) > FM_MAX_EDIT) fm_fail(413, 'O conteúdo tem mais de 2 MB.');
    if (is_dir($f)) fm_fail(400, 'É uma pasta.');
    $new = !file_exists($f);
    if (@file_put_contents($f, $content, LOCK_EX) === false) fm_fail(500, 'Não foi possível gravar o ficheiro.');
    if ($new) fm_fix($f);
    clearstatcache(true, $f);
    fm_json(['ok' => true, 'm' => filemtime($f)]);

case 'chmod':
    $p = fm_rel(in_s($in, 'p'));
    $mode = in_s($in, 'mode');
    if (!preg_match('/^[0-7]{3,4}$/', $mode)) fm_fail(400, 'Permissões inválidas (ex.: 640 ou 2750).');
    $errors = [];
    foreach (in_list($in, 'items') as $it) {
        $f = fm_entry(fm_join($p, fm_name($it)));
        if (is_link($f)) continue;
        if (!@chmod($f, octdec($mode))) $errors[] = $it;
    }
    if ($errors) fm_fail(409, "Não foi possível alterar:\n" . implode("\n", $errors));
    fm_json(['ok' => true]);

case 'extract':
    @set_time_limit(0);
    $rel = fm_rel(in_s($in, 'p'));
    $arch = fm_abs($rel);
    if (!is_file($arch)) fm_fail(400, 'Não é um ficheiro.');
    $dest = dirname($arch);
    $sub = trim(in_s($in, 'into'));
    if ($sub !== '') { $dest .= '/' . fm_name($sub); fm_mkdirs($dest); }
    $lower = strtolower($arch);
    $count = 0; $skipped = 0;
    $safeTarget = function (string $name) use ($dest, &$skipped): ?string {
        $name = str_replace('\\', '/', $name);
        $parts = [];
        foreach (explode('/', $name) as $seg) {
            if ($seg === '' || $seg === '.') continue;
            if ($seg === '..' || strpos($seg, "\0") !== false) { $skipped++; return null; }
            $parts[] = $seg;
        }
        return $parts ? $dest . '/' . implode('/', $parts) : null;
    };
    if (substr($lower, -4) === '.zip') {
        if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
        $z = new ZipArchive();
        if ($z->open($arch) !== true) fm_fail(400, 'Não foi possível abrir o ZIP.');
        for ($i = 0; $i < $z->numFiles; $i++) {
            $name = (string)$z->getNameIndex($i);
            $t = $safeTarget($name);
            if ($t === null) continue;
            if (substr($name, -1) === '/') { fm_mkdirs($t); continue; }
            fm_mkdirs(dirname($t));
            if (is_link($t)) @unlink($t);
            $src = $z->getStream($name);
            $dst = @fopen($t, 'wb');
            if ($src === false || $dst === false) { $skipped++; continue; }
            stream_copy_to_stream($src, $dst);
            fclose($src); fclose($dst);
            fm_fix($t);
            $count++;
        }
        $z->close();
    } elseif (preg_match('/\.(tar\.gz|tgz|tar\.bz2|tar)$/', $lower)) {
        if (!class_exists('PharData')) fm_fail(500, 'A extensão phar do PHP não está disponível.');
        try {
            $ph = new PharData($arch);
            $prefix = 'phar://' . $arch . '/';
            foreach (new RecursiveIteratorIterator($ph, RecursiveIteratorIterator::SELF_FIRST) as $entry) {
                $path = (string)$entry->getPathname();
                if (strpos($path, $prefix) !== 0) { $skipped++; continue; }
                $t = $safeTarget(substr($path, strlen($prefix)));
                if ($t === null) continue;
                if ($entry->isDir()) { fm_mkdirs($t); continue; }
                fm_mkdirs(dirname($t));
                if (is_link($t)) @unlink($t);
                if (!@copy($path, $t)) { $skipped++; continue; }
                fm_fix($t);
                $count++;
            }
        } catch (Throwable $e) {
            fm_fail(400, 'Não foi possível ler o arquivo: ' . $e->getMessage());
        }
    } else {
        fm_fail(400, 'Formato não suportado. Usa .zip, .tar, .tar.gz, .tgz ou .tar.bz2.');
    }
    fm_json(['ok' => true, 'count' => $count, 'skipped' => $skipped]);

case 'zip':
    @set_time_limit(0);
    if (!class_exists('ZipArchive')) fm_fail(500, 'A extensão zip do PHP não está disponível.');
    $p = fm_rel(in_s($in, 'p'));
    $dir = fm_abs($p);
    $name = fm_name(in_s($in, 'name'));
    if (strtolower(substr($name, -4)) !== '.zip') $name .= '.zip';
    $target = $dir . '/' . $name;
    if (file_exists($target)) fm_fail(409, 'Já existe um ficheiro com esse nome.');
    $z = new ZipArchive();
    if ($z->open($target, ZipArchive::CREATE) !== true) fm_fail(500, 'Não foi possível criar o ZIP.');
    $added = 0;
    $addPath = function (string $abs, string $local) use (&$addPath, $z, $target, &$added) {
        if ($abs === $target) return;
        if (is_link($abs)) return;
        if (is_dir($abs)) {
            $z->addEmptyDir($local);
            foreach ((array)@scandir($abs) as $e) {
                if ($e === '.' || $e === '..' || $e === false) continue;
                $addPath($abs . '/' . $e, $local . '/' . $e);
            }
        } elseif (is_readable($abs)) {
            $z->addFile($abs, $local);
            $added++;
        }
    };
    foreach (in_list($in, 'items') as $it) {
        $it = fm_name($it);
        $addPath(fm_entry(fm_join($p, $it)), $it);
    }
    if (!$z->close()) fm_fail(500, 'Falha ao gravar o ZIP.');
    fm_fix($target);
    fm_json(['ok' => true, 'name' => $name, 'count' => $added]);

case 'upload':
    @set_time_limit(0);
    $id = in_s($in, 'id');
    if (!preg_match('/^[A-Za-z0-9_-]{8,64}$/', $id)) fm_fail(400, 'Identificador inválido.');
    $offset = (int)in_s($in, 'offset');
    $total = (int)in_s($in, 'total');
    if ($offset < 0 || $total < 0) fm_fail(400, 'Valores inválidos.');
    $dir = fm_abs(fm_rel(in_s($in, 'p')));
    if (!is_dir($dir)) fm_fail(400, 'A pasta de destino não existe.');
    $relName = fm_rel(in_s($in, 'name'));
    if ($relName === '') fm_fail(400, 'Nome inválido.');
    foreach (explode('/', $relName) as $seg) fm_name($seg);
    $part = $ROOT . '/tmp/.mp-up-' . $id . '.part';
    if (!is_dir($ROOT . '/tmp')) fm_fail(500, 'A pasta tmp do site não existe.');
    // limpa envios abandonados há mais de um dia
    if (mt_rand(1, 20) === 1) foreach ((array)glob($ROOT . '/tmp/.mp-up-*.part') as $old) { if (is_string($old) && filemtime($old) < time() - 86400) @unlink($old); }
    clearstatcache(true, $part);
    $have = is_file($part) ? (int)filesize($part) : 0;
    if ($offset !== $have) fm_fail(409, 'Fora de sequência.', ['size' => $have]);
    $chunk = $_FILES['chunk'] ?? null;
    if ($total > 0) {
        if (!is_array($chunk) || (int)($chunk['error'] ?? 1) !== UPLOAD_ERR_OK) fm_fail(400, 'A parte do ficheiro não chegou ao servidor.');
        $src = @fopen((string)$chunk['tmp_name'], 'rb');
        $dst = @fopen($part, 'ab');
        if ($src === false || $dst === false) fm_fail(500, 'Não foi possível gravar a parte do ficheiro.');
        stream_copy_to_stream($src, $dst);
        fclose($src); fclose($dst);
        clearstatcache(true, $part);
        $have = (int)filesize($part);
    } elseif (!is_file($part)) {
        @touch($part);
    }
    if ($have > $total) { @unlink($part); fm_fail(409, 'O tamanho recebido não confere; recomeça o envio.', ['size' => 0]); }
    if ($have < $total) fm_json(['ok' => true, 'size' => $have, 'done' => false]);
    $target = $dir . '/' . $relName;
    fm_mkdirs(dirname($target));
    if (file_exists($target) || is_link($target)) {
        if (in_s($in, 'overwrite') !== '1' || is_dir($target)) { @unlink($part); fm_fail(409, 'Já existe: ' . $relName, ['exists' => true]); }
        @unlink($target);
    }
    if (!@rename($part, $target)) fm_fail(500, 'Não foi possível concluir o envio.');
    fm_fix($target);
    fm_json(['ok' => true, 'size' => $have, 'done' => true]);

default:
    fm_fail(400, 'Ação desconhecida.');
}
MPFILES
chown root:root /opt/minipainel/files/index.php
chmod 644 /opt/minipainel/files/index.php

# ----------------------------------------------------------------------------
# 7. CLI (mpanel) — também usado pelo worker da fila
# ----------------------------------------------------------------------------
say "A instalar o CLI mpanel..."
cat > /usr/local/sbin/mpanel <<'MPCLI'
#!/usr/bin/env bash
# =============================================================================
#  mpanel — IDDigital Hosting CLI v1.8.0
# =============================================================================
set -uo pipefail

MP_VERSION="1.8.0"
CONF=/etc/minipainel/minipainel.conf
[ -r "$CONF" ] || { echo "ERRO: configuração em falta ($CONF)." >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

SITES_DIR=/etc/minipainel/sites
NGX_SITES=/etc/nginx/minipainel/sites
WWW_ROOT=/srv/www
DATA=/var/lib/minipainel
QUEUE=$DATA/queue
RESULTS=$DATA/results
STATE=$DATA/state.json
AUTH=$DATA/auth.json
LOCK=/run/minipainel.lock
PMA_DIR=/opt/minipainel/phpmyadmin
PMA_USER=minipainel-pma
PMA_CONF=/etc/minipainel/pma-config.inc.php
DB_ADMIN=mpadmin

die(){  echo "ERRO: $*" >&2; exit 1; }
warn(){ echo "AVISO: $*" >&2; }

# ---------- validação ----------
valid_site(){ local re='^[a-z][a-z0-9-]{0,23}$'; [[ "$1" =~ $re ]] && [[ "$1" != *- ]]; }
valid_db(){   local re='^[a-z][a-z0-9_]{0,31}$'; [[ "$1" =~ $re ]]; }
valid_pass(){ local re='^[A-Za-z0-9._@%+=:,!#*-]{8,64}$'; [[ "$1" =~ $re ]]; }
valid_port(){ local re='^[0-9]{1,5}$'; [[ "$1" =~ $re ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
gen_pass(){ openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }
port_reserved(){ case " 22 25 53 110 143 443 465 587 993 995 3306 $PANEL_PORT " in *" $1 "*) return 0 ;; esac; return 1; }
port_listening(){ [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]; }
wait_listen(){ local i; for i in $(seq 1 25); do port_listening "$1" && return 0; sleep 0.2; done; return 1; }

# ---------- PHP ----------
php_vv(){ echo "${1/./}"; }
php_pool_dir(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/pool.d"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.d"; fi; }
php_service(){  if [ "$OS_FAMILY" = debian ]; then echo "php$1-fpm"; else echo "php$(php_vv "$1")-php-fpm"; fi; }
php_fpm_bin(){  if [ "$OS_FAMILY" = debian ]; then echo "/usr/sbin/php-fpm$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/sbin/php-fpm"; fi; }
php_fpm_conf(){ if [ "$OS_FAMILY" = debian ]; then echo "/etc/php/$1/fpm/php-fpm.conf"; else echo "/etc/opt/remi/php$(php_vv "$1")/php-fpm.conf"; fi; }
php_cli(){      if [ "$OS_FAMILY" = debian ]; then echo "/usr/bin/php$1"; else echo "/opt/remi/php$(php_vv "$1")/root/usr/bin/php"; fi; }
php_run_dir(){  if [ "$OS_FAMILY" = debian ]; then echo "/run/php"; else echo "/var/opt/remi/php$(php_vv "$1")/run/php-fpm"; fi; }
php_sock(){ echo "$(php_run_dir "$1")/mp-$2.sock"; }
php_installed(){
  local d v
  if [ "$OS_FAMILY" = debian ]; then
    for d in /etc/php/*/fpm/pool.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/php/}"; v="${v%%/*}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  else
    for d in /etc/opt/remi/php*/php-fpm.d; do
      [ -d "$d" ] || continue
      v="${d#/etc/opt/remi/php}"; v="${v%%/*}"; v="${v:0:1}.${v:1}"
      if [ -x "$(php_fpm_bin "$v")" ]; then echo "$v"; fi
    done
  fi | sort -V
}
php_is_installed(){ local v; for v in $(php_installed); do [ "$v" = "$1" ] && return 0; done; return 1; }

# ---------- SELinux / firewall ----------
selinux_on(){ command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; }
se_port_add(){
  # 0 = etiqueta adicionada pelo MiniPainel
  selinux_on || return 1
  semanage port -a -t http_port_t -p tcp "$1" >/dev/null 2>&1 && return 0
  semanage port -m -t http_port_t -p tcp "$1" >/dev/null 2>&1 && return 0
  return 1
}
se_port_del(){ selinux_on || return 0; semanage port -d -p tcp "$1" >/dev/null 2>&1; return 0; }
se_restore(){ if selinux_on; then restorecon -R "$1" >/dev/null 2>&1; fi; return 0; }
fw_open(){
  # 0 = porta aberta agora pelo MiniPainel (não estava aberta)
  local p=$1
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd -q --query-port="$p/tcp" 2>/dev/null && return 1
    firewall-cmd -q --permanent --add-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd -q --add-port="$p/tcp" >/dev/null 2>&1 && return 0
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    [[ "$(ufw status 2>/dev/null)" == *"$p/tcp"* ]] && return 1
    ufw allow "$p/tcp" >/dev/null 2>&1 && return 0
  fi
  return 1
}
fw_close(){
  local p=$1
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd -q --permanent --remove-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd -q --remove-port="$p/tcp" >/dev/null 2>&1
  elif command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$p/tcp" >/dev/null 2>&1
  fi
  return 0
}

# ---------- aplicar configurações ----------
apply_nginx(){
  local out
  if ! out=$(nginx -t 2>&1); then echo "$out" >&2; return 1; fi
  systemctl reload-or-restart nginx >/dev/null 2>&1 || { echo "Falha ao recarregar o nginx." >&2; return 1; }
  return 0
}
apply_php(){
  local v=$1 out
  if ! out=$("$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" 2>&1); then echo "$out" >&2; return 1; fi
  systemctl reload-or-restart "$(php_service "$v")" >/dev/null 2>&1 || { echo "Falha ao recarregar PHP-FPM $v." >&2; return 1; }
  return 0
}

# ---------- registo de sites ----------
site_conf(){ echo "$SITES_DIR/$1.conf"; }
site_exists(){ [ -f "$(site_conf "$1")" ]; }
site_get(){ grep -m1 "^$2=" "$(site_conf "$1")" 2>/dev/null | cut -d= -f2-; }
site_set(){
  local f; f=$(site_conf "$1")
  if grep -q "^$2=" "$f"; then sed -i "s|^$2=.*|$2=$3|" "$f"; else echo "$2=$3" >> "$f"; fi
}
site_names(){ local f; for f in "$SITES_DIR"/*.conf; do [ -f "$f" ] && basename "$f" .conf; done; return 0; }
port_owner(){ local n; for n in $(site_names); do if [ "$(site_get "$n" PORT)" = "$1" ]; then echo "$n"; return 0; fi; done; return 1; }
next_port(){
  local p=${SITE_PORT_START:-8001}
  while port_owner "$p" >/dev/null || port_listening "$p" || port_reserved "$p"; do p=$((p+1)); done
  echo "$p"
}
ngx_file(){ if [ "$(site_get "$1" ENABLED)" = 0 ]; then echo "$NGX_SITES/$1.conf.disabled"; else echo "$NGX_SITES/$1.conf"; fi; }

# ---------- limites por site (valores guardados em /etc/minipainel/sites/<site>.conf) ----------
lim_default(){ case "$1" in MEM) echo 256 ;; UPLOAD) echo 128 ;; EXEC|INPUT_TIME) echo 120 ;; INPUT_VARS) echo 5000 ;; DISPLAY_ERRORS) echo 0 ;; esac; }
lim_range(){ case "$1" in MEM) echo "32 8192" ;; UPLOAD) echo "1 8192" ;; EXEC|INPUT_TIME) echo "5 3600" ;; INPUT_VARS) echo "100 100000" ;; DISPLAY_ERRORS) echo "0 1" ;; esac; }
lim_opt_key(){ case "$1" in --memory) echo MEM ;; --upload) echo UPLOAD ;; --exec) echo EXEC ;; --input-time) echo INPUT_TIME ;; --input-vars) echo INPUT_VARS ;; --display-errors) echo DISPLAY_ERRORS ;; esac; }
lim_get(){ local v; v=$(site_get "$1" "$2"); [ -n "$v" ] || v=$(lim_default "$2"); echo "$v"; }
lim_check(){ local lo hi; read -r lo hi <<<"$(lim_range "$1")"; [ "$2" -ge "$lo" ] && [ "$2" -le "$hi" ]; }

write_pool(){
  local n=$1 v=$2 f
  f="$(php_pool_dir "$v")/mp-$n.conf"
  cat > "$f" <<EOF
; MiniPainel — site $n (gerido pelo mpanel; não editar à mão)
[mp-$n]
user = mp_$n
group = mp_$n
listen = $(php_sock "$v" "$n")
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
pm.max_requests = 500
chdir = /
php_admin_value[open_basedir] = $WWW_ROOT/$n/
php_admin_value[upload_tmp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[sys_temp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[session.save_path] = $WWW_ROOT/$n/tmp
php_admin_value[session.gc_probability] = 1
php_admin_value[session.gc_divisor] = 100
php_admin_value[error_log] = $WWW_ROOT/$n/logs/php-error.log
php_admin_flag[log_errors] = on
php_value[memory_limit] = $(lim_get "$n" MEM)M
php_value[upload_max_filesize] = $(lim_get "$n" UPLOAD)M
php_value[post_max_size] = $(lim_get "$n" UPLOAD)M
php_value[max_execution_time] = $(lim_get "$n" EXEC)
php_value[max_input_time] = $(lim_get "$n" INPUT_TIME)
php_value[max_input_vars] = $(lim_get "$n" INPUT_VARS)
php_flag[display_errors] = $([ "$(lim_get "$n" DISPLAY_ERRORS)" = 1 ] && echo on || echo off)
EOF
  chmod 644 "$f"
}

write_nginx(){
  local n=$1 p=$2 v=$3 dest=$4 l6="" up rt
  if [ "${IPV6:-0}" = 1 ]; then l6="    listen [::]:$p;"; fi
  up=$(lim_get "$n" UPLOAD)
  rt=$(( $(lim_get "$n" EXEC) + 30 )); [ "$rt" -lt 300 ] && rt=300
  cat > "$dest" <<EOF
# MiniPainel — site $n (gerido pelo mpanel; não editar à mão)
server {
    listen $p;
$l6
    server_name _;
    root $WWW_ROOT/$n/public_html;
    index index.php index.html index.htm;
    client_max_body_size ${up}M;
    access_log /var/log/nginx/mp-$n.access.log;
    error_log  /var/log/nginx/mp-$n.error.log;

    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        if (!-f \$document_root\$fastcgi_script_name) { return 404; }
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass unix:$(php_sock "$v" "$n");
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout ${rt}s;
    }
}
EOF
  chmod 644 "$dest"
}

# O nginx pertence ao grupo de cada site (mp_<site>): lê os ficheiros do site,
# enquanto os sites continuam isolados entre si.
web_join(){
  local g="mp_$1"
  getent group "$g" >/dev/null 2>&1 || return 0
  id -nG "$WEB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" && return 0
  gpasswd -a "$WEB_USER" "$g" >/dev/null 2>&1 || usermod -aG "$g" "$WEB_USER" >/dev/null 2>&1
  return 0
}

# ---------- gestor de ficheiros: pool por site, como mp_<site>, na versão de PHP do painel ----------
fm_pool_file(){ echo "$(php_pool_dir "$PANEL_PHP")/mp-fm-$1.conf"; }
write_fm_pool(){
  local n=$1 f
  f=$(fm_pool_file "$n")
  cat > "$f" <<EOF
; MiniPainel — gestor de ficheiros do site $n (corre como mp_$n; gerido pelo mpanel)
[mp-fm-$n]
user = mp_$n
group = mp_$n
listen = $(php_run_dir "$PANEL_PHP")/mp-fm-$n.sock
listen.owner = $WEB_USER
listen.group = $WEB_GROUP
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 30s
request_terminate_timeout = 0
php_admin_value[open_basedir] = $WWW_ROOT/$n/:/opt/minipainel/files/
php_admin_value[upload_tmp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[sys_temp_dir] = $WWW_ROOT/$n/tmp
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 72M
php_admin_value[memory_limit] = 256M
php_value[max_execution_time] = 900
php_admin_value[max_input_time] = 900
php_admin_value[error_log] = $WWW_ROOT/$n/logs/ficheiros-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF
  chmod 644 "$f"
}

cmd_fm_sync(){
  local n v f
  for v in $(php_installed); do
    [ "$v" = "$PANEL_PHP" ] && continue
    for f in "$(php_pool_dir "$v")"/mp-fm-*.conf; do
      [ -f "$f" ] || continue
      rm -f "$f"; apply_php "$v" >/dev/null 2>&1
    done
  done
  for n in $(site_names); do
    id "mp_$n" >/dev/null 2>&1 || continue
    web_join "$n"
    write_fm_pool "$n"
  done
  for f in "$(php_pool_dir "$PANEL_PHP")"/mp-fm-*.conf; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .conf); n=${n#mp-fm-}
    site_exists "$n" || rm -f "$f"
  done
  apply_php "$PANEL_PHP" || die "Configuração do PHP-FPM $PANEL_PHP inválida depois de configurar o gestor de ficheiros."
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  echo "Gestor de ficheiros configurado para $(site_names | wc -l) site(s)."
  return 0
}

cmd_stats(){
  local f=/var/lib/minipainel/stats/live.json
  [ -s "$f" ] || die "Ainda não há dados. Verifica: systemctl status minipainel-stats"
  jq -r '"CPU \(.cpu)%   Memória \(.mem.pct)%   Swap \(.swap.pct)%   Disco \(.disk.pct)%",
         "Carga \(.load | map(tostring) | join(" "))   Rede ↓ \(.net.rx / 1000000 * 100 | floor / 100) Mb/s   ↑ \(.net.tx / 1000000 * 100 | floor / 100) Mb/s",
         (.sites | to_entries[] | "  \(.key): CPU \(.value.cpu)%   RAM \(.value.rss / 1024 | floor) MB")' "$f"
  return 0
}

site_rollback(){
  local n=$1 v=$2 p=$3 se=$4
  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" "$(php_pool_dir "$v")/mp-$n.conf" "$SITES_DIR/$n.conf" "$(fm_pool_file "$n")"
  apply_nginx >/dev/null 2>&1
  apply_php "$v" >/dev/null 2>&1
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" >/dev/null 2>&1; fi
  sleep 1
  pkill -u "mp_$n" >/dev/null 2>&1
  userdel "mp_$n" >/dev/null 2>&1
  if getent group "mp_$n" >/dev/null 2>&1; then groupdel "mp_$n" >/dev/null 2>&1; fi
  rm -rf "${WWW_ROOT:?}/${n:?}"
  if [ "$se" = 1 ]; then se_port_del "$p"; fi
  return 0
}

# ---------- comandos: sites ----------
cmd_site_list(){
  local n
  printf '%-24s %-6s %-5s %-11s %s\n' SITE PORTA PHP ESTADO PASTA
  for n in $(site_names); do
    printf '%-24s %-6s %-5s %-11s %s\n' "$n" "$(site_get "$n" PORT)" "$(site_get "$n" PHP)" \
      "$([ "$(site_get "$n" ENABLED)" = 1 ] && echo ativo || echo desativado)" "$WWW_ROOT/$n/public_html"
  done
  return 0
}

cmd_site_add(){
  local n="${1:-}" port="" v="$DEFAULT_PHP" key val lo hi re='^[0-9]{1,6}$'
  local -A lims=()
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 || shift ;;
      --php)  v="${2:-}";    shift 2 || shift ;;
      --memory|--upload|--exec|--input-time|--input-vars|--display-errors)
        key=$(lim_opt_key "$1"); val="${2:-}"; shift 2 || shift
        [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
        if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
        lims[$key]=$val ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  valid_site "$n" || die "Nome inválido. Usa minúsculas, números e '-', a começar por letra (máx. 24)."
  site_exists "$n" && die "O site '$n' já existe."
  id "mp_$n" >/dev/null 2>&1 && die "O utilizador de sistema mp_$n já existe."
  [ -e "$WWW_ROOT/$n" ] && die "A pasta $WWW_ROOT/$n já existe (ficheiros mantidos de um site apagado?)."
  php_is_installed "$v" || die "PHP $v não está instalado. Disponíveis: $(php_installed | tr '\n' ' ')"
  if [ -n "$port" ]; then
    valid_port "$port" || die "Porta inválida: $port"
    port_reserved "$port" && die "A porta $port está reservada."
    port_owner "$port" >/dev/null && die "A porta $port já é usada pelo site '$(port_owner "$port")'."
    port_listening "$port" && die "A porta $port já está em uso por outro serviço."
  else
    port=$(next_port)
  fi

  local u="mp_$n" d="$WWW_ROOT/$n" se=0 fw=0
  useradd -r -U -M -d "$d" -s "$NOLOGIN" -c "MiniPainel site $n" "$u" || die "Não foi possível criar o utilizador $u."
  web_join "$n"
  install -d -o "$u" -g "$u" -m 2750 "$d" "$d/public_html"
  install -d -o "$u" -g "$u" -m 700 "$d/logs" "$d/tmp"
  cat > "$d/public_html/index.html" <<EOF
<!doctype html>
<html lang="pt-PT"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$n</title>
<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;font:16px/1.5 system-ui,sans-serif;background:#eaeef2;color:#16222e}div{text-align:center;padding:24px}h1{margin:0 0 8px}p{margin:0;color:#4a5a6a}</style></head>
<body><div><h1>$n</h1><p>Site ativo com PHP $v. Substitui este ficheiro em $d/public_html.</p></div></body></html>
EOF
  chown "$u:$u" "$d/public_html/index.html"
  chmod 640 "$d/public_html/index.html"

  cat > "$SITES_DIR/$n.conf" <<EOF
NAME=$n
PORT=$port
PHP=$v
ENABLED=1
SE_PORT=0
FW_PORT=0
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
  chmod 600 "$SITES_DIR/$n.conf"
  for key in "${!lims[@]}"; do site_set "$n" "$key" "${lims[$key]}"; done

  write_pool "$n" "$v"
  write_fm_pool "$n"
  write_nginx "$n" "$port" "$v" "$NGX_SITES/$n.conf"
  se_restore "$d"
  if se_port_add "$port"; then se=1; fi
  site_set "$n" SE_PORT "$se"

  if ! apply_php "$v" || { [ "$PANEL_PHP" != "$v" ] && ! apply_php "$PANEL_PHP"; }; then
    site_rollback "$n" "$v" "$port" "$se"
    die "Configuração PHP-FPM inválida; nada foi alterado."
  fi
  if ! apply_nginx || ! wait_listen "$port"; then
    site_rollback "$n" "$v" "$port" "$se"
    die "O nginx não conseguiu servir na porta $port; nada foi alterado."
  fi
  if fw_open "$port"; then fw=1; fi
  site_set "$n" FW_PORT "$fw"

  echo "Site '$n' criado na porta $port com PHP $v."
  echo "Pasta: $d/public_html"
  return 0
}

cmd_site_del(){
  local n="${1:-}" keep=0
  [ $# -gt 0 ] && shift
  [ "${1:-}" = "--keep-files" ] && keep=1
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local v p se fw
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); se=$(site_get "$n" SE_PORT); fw=$(site_get "$n" FW_PORT)

  rm -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"
  apply_nginx || warn "Verifica o nginx (nginx -t)."
  rm -f "$(php_pool_dir "$v")/mp-$n.conf" "$(fm_pool_file "$n")"
  apply_php "$v" || warn "Verifica o PHP-FPM $v."
  if [ "$PANEL_PHP" != "$v" ]; then apply_php "$PANEL_PHP" || warn "Verifica o PHP-FPM $PANEL_PHP."; fi
  rm -f "/var/lib/minipainel/stats/traffic/$n.csv" "/var/lib/minipainel/stats/traffic/$n.pos"
  rm -rf "/etc/cron.d/minipainel-$n" "${CRON_DIR:?}/$n" "$CRON_DIR/$n.json"; touch /etc/cron.d 2>/dev/null
  if [ -s "$DBMAP" ]; then jq --arg s "$n" 'with_entries(select(.value != $s))' "$DBMAP" > "$DBMAP.tmp" && mv -f "$DBMAP.tmp" "$DBMAP"; fi
  sleep 1
  pkill -u "mp_$n" >/dev/null 2>&1
  userdel "mp_$n" >/dev/null 2>&1 || warn "Não foi possível remover o utilizador mp_$n."
  if getent group "mp_$n" >/dev/null 2>&1; then groupdel "mp_$n" >/dev/null 2>&1; fi

  if [ "$keep" = 1 ]; then
    chown -R root:root "$WWW_ROOT/$n" 2>/dev/null
  else
    rm -rf "${WWW_ROOT:?}/${n:?}"
  fi
  if [ "$se" = 1 ]; then se_port_del "$p"; fi
  if [ "$fw" = 1 ]; then fw_close "$p"; fi
  rm -f "$SITES_DIR/$n.conf"

  if [ "$keep" = 1 ]; then echo "Site '$n' apagado. Ficheiros mantidos em $WWW_ROOT/$n."; else echo "Site '$n' apagado."; fi
  return 0
}

cmd_site_php(){
  local n="${1:-}" nv="${2:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  php_is_installed "$nv" || die "PHP $nv não está instalado."
  local ov p dest
  ov=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  [ "$ov" = "$nv" ] && die "O site '$n' já usa PHP $nv."

  write_pool "$n" "$nv"
  if ! apply_php "$nv"; then
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao configurar PHP $nv; nada foi alterado."
  fi
  write_nginx "$n" "$p" "$nv" "$dest"
  if ! apply_nginx; then
    write_nginx "$n" "$p" "$ov" "$dest"; apply_nginx >/dev/null 2>&1
    rm -f "$(php_pool_dir "$nv")/mp-$n.conf"; apply_php "$nv" >/dev/null 2>&1
    die "Falha ao aplicar no nginx; nada foi alterado."
  fi
  rm -f "$(php_pool_dir "$ov")/mp-$n.conf"
  apply_php "$ov" || warn "Verifica o PHP-FPM $ov."
  site_set "$n" PHP "$nv"
  cron_write_site "$n"
  echo "Site '$n' passou de PHP $ov para PHP $nv."
  return 0
}

cmd_site_toggle(){
  local n="${1:-}" want="$2"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local cur p; cur=$(site_get "$n" ENABLED); p=$(site_get "$n" PORT)
  if [ "$want" = 1 ]; then
    [ "$cur" = 1 ] && die "O site '$n' já está ativo."
    port_listening "$p" && die "A porta $p está agora ocupada por outro serviço."
    mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf" || die "Configuração nginx do site em falta."
    if ! apply_nginx || ! wait_listen "$p"; then
      mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled"; apply_nginx >/dev/null 2>&1
      die "O nginx não conseguiu servir na porta $p; o site continua desativado."
    fi
    site_set "$n" ENABLED 1
    echo "Site '$n' ativado."
  else
    [ "$cur" = 0 ] && die "O site '$n' já está desativado."
    mv -f "$NGX_SITES/$n.conf" "$NGX_SITES/$n.conf.disabled" || die "Configuração nginx do site em falta."
    if ! apply_nginx; then
      mv -f "$NGX_SITES/$n.conf.disabled" "$NGX_SITES/$n.conf"; apply_nginx >/dev/null 2>&1
      die "Falha ao desativar; o site continua ativo."
    fi
    site_set "$n" ENABLED 0
    echo "Site '$n' desativado."
  fi
  return 0
}

cmd_site_fixperms(){
  local n="${1:-}"
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  local d="$WWW_ROOT/$n/public_html" u="mp_$n"
  [ -d "$d" ] || die "Pasta em falta: $d"
  web_join "$n"
  chown "$u:$u" "$WWW_ROOT/$n"; chmod 2750 "$WWW_ROOT/$n"
  chown -R "$u:$u" "$d"
  find "$d" -type d -exec chmod 2750 {} +
  find "$d" -type f -exec chmod 640 {} +
  se_restore "$d"
  apply_nginx >/dev/null 2>&1
  echo "Permissões corrigidas em $d (dono e grupo $u; o nginx lê através do grupo do site)."
  return 0
}

show_limits(){
  local n=$1
  printf 'Limites do site %s\n' "$n"
  printf '  memory_limit          %s MB\n' "$(lim_get "$n" MEM)"
  printf '  upload / post máximo  %s MB\n' "$(lim_get "$n" UPLOAD)"
  printf '  max_execution_time    %s s\n'  "$(lim_get "$n" EXEC)"
  printf '  max_input_time        %s s\n'  "$(lim_get "$n" INPUT_TIME)"
  printf '  max_input_vars        %s\n'    "$(lim_get "$n" INPUT_VARS)"
  printf '  display_errors        %s\n'    "$([ "$(lim_get "$n" DISPLAY_ERRORS)" = 1 ] && echo on || echo off)"
}

cmd_site_limits(){
  local n="${1:-}"
  [ $# -gt 0 ] && shift
  valid_site "$n" && site_exists "$n" || die "O site '$n' não existe."
  if [ $# -eq 0 ]; then show_limits "$n"; return 0; fi

  local -A nv=()
  local key val re='^[0-9]{1,6}$' lo hi
  while [ $# -gt 0 ]; do
    case "$1" in
      --memory)         key=MEM ;;
      --upload)         key=UPLOAD ;;
      --exec)           key=EXEC ;;
      --input-time)     key=INPUT_TIME ;;
      --input-vars)     key=INPUT_VARS ;;
      --display-errors) key=DISPLAY_ERRORS ;;
      *) die "Opção desconhecida: $1" ;;
    esac
    val="${2:-}"
    shift 2 2>/dev/null || shift
    [[ "$val" =~ $re ]] || die "Valor inválido para $key: '$val'"
    if ! lim_check "$key" "$val"; then read -r lo hi <<<"$(lim_range "$key")"; die "$key tem de estar entre $lo e $hi."; fi
    nv[$key]=$val
  done

  local f bak v p dest
  f=$(site_conf "$n"); bak="$f.bak"
  cp -p "$f" "$bak" || die "Não foi possível guardar uma cópia da configuração do site."
  for key in "${!nv[@]}"; do site_set "$n" "$key" "${nv[$key]}"; done
  v=$(site_get "$n" PHP); p=$(site_get "$n" PORT); dest=$(ngx_file "$n")
  write_pool "$n" "$v"
  write_nginx "$n" "$p" "$v" "$dest"
  if ! apply_php "$v" || ! apply_nginx; then
    mv -f "$bak" "$f"
    write_pool "$n" "$v"; write_nginx "$n" "$p" "$v" "$dest"
    apply_php "$v" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    die "Não foi possível aplicar os limites; foram repostos os anteriores."
  fi
  rm -f "$bak"
  echo "Limites do site '$n' atualizados."
  show_limits "$n"
  return 0
}

# ---------- comandos: bases de dados ----------
db_q(){ mysql -uroot -N -B -e "$1"; }
db_exec(){ printf '%s\n' "$1" | mysql -uroot -N -B; }
db_exists(){ [ "$(db_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$1'" 2>/dev/null)" = 1 ]; }
dbuser_exists(){ local c; c=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$1'" 2>/dev/null); [ -n "$c" ] && [ "$c" != 0 ]; }
db_reserved(){ case " mysql information_schema performance_schema sys mpadmin " in *" $1 "*) return 0 ;; esac; return 1; }
db_sizes(){
  db_q "SELECT s.schema_name, ROUND(COALESCE(SUM(t.data_length+t.index_length),0)/1048576,2)
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema=s.schema_name
        WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys')
        GROUP BY s.schema_name ORDER BY s.schema_name" 2>/dev/null
}

cmd_db_list(){
  local n s
  printf '%-34s %s\n' "BASE DE DADOS" "TAMANHO (MB)"
  while IFS=$'\t' read -r n s; do [ -n "$n" ] && printf '%-34s %s\n' "$n" "$s"; done < <(db_sizes)
  return 0
}

cmd_db_add(){
  local n="${1:-}" pw="" dsite=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --site) dsite="${2:-}"; shift 2 || shift ;;
      *) pw="$1"; shift ;;
    esac
  done
  if [ -n "$dsite" ]; then valid_site "$dsite" && site_exists "$dsite" || die "O site '$dsite' não existe."; fi
  valid_db "$n" || die "Nome inválido. Usa minúsculas, números e '_', a começar por letra (máx. 32)."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" && die "A base de dados '$n' já existe."
  dbuser_exists "$n" && die "O utilizador MariaDB '$n' já existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  local ng="${n//_/\\_}"
  if ! db_exec "CREATE DATABASE \`$n\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$n'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$ng\`.* TO '$n'@'localhost';
FLUSH PRIVILEGES;"; then
    db_exec "DROP DATABASE IF EXISTS \`$n\`; DROP USER IF EXISTS '$n'@'localhost';" >/dev/null 2>&1
    die "Falha ao criar a base de dados '$n'."
  fi
  [ -n "$dsite" ] && dbmap_set "$n" "$dsite"
  printf 'Base de dados criada.\nServidor:      localhost (porta 3306)\nBase de dados: %s\nUtilizador:    %s\nPassword:      %s\n' "$n" "$n" "$pw"
  [ -n "$dsite" ] && echo "Associada ao site $dsite."
  return 0
}

cmd_db_del(){
  local n="${1:-}"
  valid_db "$n" || die "Nome inválido."
  db_reserved "$n" && die "Nome reservado: $n"
  db_exists "$n" || die "A base de dados '$n' não existe."
  db_exec "DROP DATABASE \`$n\`; DROP USER IF EXISTS '$n'@'localhost'; FLUSH PRIVILEGES;" || die "Falha ao apagar '$n'."
  dbmap_set "$n" ""
  echo "Base de dados '$n' e utilizador '$n' apagados."
  return 0
}

cmd_db_passwd(){
  local n="${1:-}" pw="${2:-}"
  valid_db "$n" || die "Nome inválido."
  dbuser_exists "$n" || die "O utilizador MariaDB '$n' não existe."
  if [ -z "$pw" ]; then pw=$(gen_pass 20)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  db_exec "ALTER USER '$n'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password."
  printf 'Password alterada.\nUtilizador: %s\nPassword:   %s\n' "$n" "$pw"
  return 0
}

# ---------- extensões PHP opcionais (por versão) ----------
# nome|sufixo Debian/Ubuntu (php<ver>-X)|sufixos Remi, alternativas separadas por vírgula (php<vv>-X)|descrição
ext_catalog(){
  cat <<'EOF'
apcu|apcu|php-pecl-apcu|Cache de dados em memória (APCu)
gmp|gmp|php-gmp|Aritmética de precisão arbitrária
igbinary|igbinary|php-pecl-igbinary|Serialização binária rápida
imagick|imagick|php-pecl-imagick-im7,php-pecl-imagick|Tratamento de imagens com ImageMagick
imap|imap|php-imap,php-pecl-imap|Acesso a caixas de correio IMAP
ldap|ldap|php-ldap|Autenticação LDAP e Active Directory
memcached|memcached|php-pecl-memcached|Cliente Memcached
mongodb|mongodb|php-pecl-mongodb|Cliente MongoDB
pgsql|pgsql|php-pgsql|Ligação a PostgreSQL
redis|redis|php-pecl-redis6,php-pecl-redis5|Cliente Redis
ssh2|ssh2|php-pecl-ssh2|Ligações SSH e SFTP
tidy|tidy|php-tidy|Limpeza e correção de HTML
xdebug|xdebug|php-pecl-xdebug3,php-pecl-xdebug|Depuração; só para desenvolvimento (torna o PHP mais lento)
yaml|yaml|php-pecl-yaml|Leitura e escrita de YAML
EOF
}
ext_known(){ local re='^[a-z0-9_]{2,20}$'; [[ "$1" =~ $re ]] && [ -n "$(ext_catalog | grep -m1 "^$1|")" ]; }
ext_pkgs(){
  local line en deb remi ed a
  line=$(ext_catalog | grep -m1 "^$1|")
  [ -n "$line" ] || return 1
  IFS='|' read -r en deb remi ed <<<"$line"
  if [ "$OS_FAMILY" = debian ]; then
    echo "php$2-$deb"
  else
    local IFS=,
    for a in $remi; do echo "php$(php_vv "$2")-$a"; done
  fi
}
PKG_CACHE=""
pkg_cache_load(){
  if [ "$OS_FAMILY" = debian ]; then
    PKG_CACHE=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | awk '$2=="installed"{print $1}')
  else
    PKG_CACHE=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null)
  fi
}
pkg_has(){ [[ $'\n'"$PKG_CACHE"$'\n' == *$'\n'"$1"$'\n'* ]]; }
ext_installed_pkg(){ local c; for c in $(ext_pkgs "$1" "$2"); do if pkg_has "$c"; then echo "$c"; return 0; fi; done; return 1; }
sys_pkg_install(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1" && return 0
    apt-get -o DPkg::Lock::Timeout=180 update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q --no-install-recommends "$1"
  else
    dnf install -y -q "$1"
  fi
}
sys_pkg_remove(){
  if [ "$OS_FAMILY" = debian ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 remove -y -q "$1"
  else
    dnf remove -y -q "$1"
  fi
}

cmd_ext_list(){
  local v="${1:-}" vs x en d
  if [ -n "$v" ]; then php_is_installed "$v" || die "PHP $v não está instalado."; vs="$v"; else vs=$(php_installed); fi
  pkg_cache_load
  for v in $vs; do
    echo "PHP $v"
    while IFS='|' read -r en _ _ d; do
      if ext_installed_pkg "$en" "$v" >/dev/null; then x=instalada; else x=-; fi
      printf '  %-11s %-10s %s\n' "$en" "$x" "$d"
    done < <(ext_catalog)
  done
  return 0
}

cmd_ext_add(){
  local v="${1:-}" x="${2:-}" p out okp=""
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x (usa 'mpanel ext-list')."
  pkg_cache_load
  ext_installed_pkg "$x" "$v" >/dev/null && die "A extensão $x já está instalada no PHP $v."
  for p in $(ext_pkgs "$x" "$v"); do
    if out=$(sys_pkg_install "$p" 2>&1); then okp=$p; break; fi
  done
  if [ -z "$okp" ]; then
    echo "$out" | tail -n 4 >&2
    die "Não foi possível instalar $x para o PHP $v (pacote indisponível nesta distribuição?)."
  fi
  apply_php "$v" || die "A extensão foi instalada, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x instalada no PHP $v ($okp)."
  return 0
}

cmd_ext_del(){
  local v="${1:-}" x="${2:-}" p others out
  php_is_installed "$v" || die "PHP $v não está instalado."
  ext_known "$x" || die "Extensão desconhecida: $x"
  pkg_cache_load
  p=$(ext_installed_pkg "$x" "$v") || die "A extensão $x não está instalada no PHP $v."
  if [ "$OS_FAMILY" = debian ]; then
    others=$(apt-get -s remove "$p" 2>/dev/null | awk -v p="$p" '/^Remv /{ if ($2 != p) printf "%s ", $2 }')
  else
    others=$(rpm -e --test "$p" 2>&1 | awk '/is needed by/{ printf "%s ", $NF }')
  fi
  if [ -n "${others// /}" ]; then
    die "Remover $x também removeria: $others. Remove primeiro essas extensões ou mantém $x."
  fi
  out=$(sys_pkg_remove "$p" 2>&1) || { echo "$out" | tail -n 4 >&2; die "Não foi possível remover $x do PHP $v."; }
  apply_php "$v" || die "A extensão foi removida, mas o PHP-FPM $v não recarregou. Verifica: $(php_fpm_bin "$v") -t"
  echo "Extensão $x removida do PHP $v."
  return 0
}

# ---------- phpMyAdmin e conta de administração ----------
pma_version(){ if [ -f "$PMA_DIR/.mp-version" ]; then cat "$PMA_DIR/.mp-version"; fi; }
pma_write_config(){
  if [ ! -s "$PMA_CONF" ]; then
    cat > "$PMA_CONF" <<EOF
<?php
/* MiniPainel — configuração do phpMyAdmin (copiada para $PMA_DIR em cada atualização) */
declare(strict_types=1);
\$cfg['blowfish_secret'] = '$(gen_pass 32)';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false;
\$cfg['TempDir'] = '/var/lib/minipainel-pma/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['VersionCheck'] = false;
\$cfg['SendErrorReports'] = 'never';
\$cfg['LoginCookieValidity'] = 7200;
\$cfg['DefaultLang'] = 'pt';
EOF
  fi
  chown root:"$PMA_USER" "$PMA_CONF"
  chmod 640 "$PMA_CONF"
}

# Garante que o config.inc.php existe e é legível pelo pool do phpMyAdmin
pma_fix_config(){
  [ -d "$PMA_DIR" ] || return 0
  pma_write_config
  cp -p "$PMA_CONF" "$PMA_DIR/config.inc.php"
  chown root:"$PMA_USER" "$PMA_DIR/config.inc.php"
  chmod 640 "$PMA_DIR/config.inc.php"
  se_restore "$PMA_DIR/config.inc.php"
}

cmd_pma_update(){
  local force=0 latest cur tmp url want got
  [ "${1:-}" = "--force" ] && force=1
  id "$PMA_USER" >/dev/null 2>&1 || die "Utilizador $PMA_USER em falta; volta a correr o instalador."
  latest=$(curl -fsSL --max-time 30 https://www.phpmyadmin.net/home_page/version.txt 2>/dev/null | head -n1 | tr -d '\r')
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Não foi possível obter a versão do phpMyAdmin (sem acesso a phpmyadmin.net?)."
  cur=$(pma_version)
  if [ "$cur" = "$latest" ] && [ "$force" = 0 ]; then
    pma_fix_config
    echo "O phpMyAdmin já está na versão mais recente ($cur)."
    return 0
  fi
  tmp=$(mktemp -d /var/tmp/mp-pma.XXXXXX) || die "Não foi possível criar pasta temporária."
  url="https://files.phpmyadmin.net/phpMyAdmin/$latest/phpMyAdmin-$latest-all-languages.tar.gz"
  if ! curl -fsSL --max-time 600 -o "$tmp/pma.tgz" "$url" || ! curl -fsSL --max-time 30 -o "$tmp/pma.sha256" "$url.sha256"; then
    rm -rf "$tmp"; die "Falha no download do phpMyAdmin $latest."
  fi
  want=$(awk '{print $1; exit}' "$tmp/pma.sha256")
  got=$(sha256sum "$tmp/pma.tgz" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then rm -rf "$tmp"; die "O SHA-256 do phpMyAdmin $latest não confere; nada foi alterado."; fi
  mkdir "$tmp/x"
  if ! tar xzf "$tmp/pma.tgz" -C "$tmp/x" --strip-components=1 || [ ! -f "$tmp/x/index.php" ]; then
    rm -rf "$tmp"; die "O pacote do phpMyAdmin não é válido; nada foi alterado."
  fi
  rm -rf "$tmp/x/setup" "$tmp/x/examples" "$tmp/x/test"
  pma_write_config
  cp -p "$PMA_CONF" "$tmp/x/config.inc.php"
  echo "$latest" > "$tmp/x/.mp-version"
  chown -R root:root "$tmp/x"
  find "$tmp/x" -type d -exec chmod 755 {} +
  find "$tmp/x" -type f -exec chmod 644 {} +
  chown root:"$PMA_USER" "$tmp/x/config.inc.php"; chmod 640 "$tmp/x/config.inc.php"
  rm -rf "$PMA_DIR.new" "$PMA_DIR.old"
  mv "$tmp/x" "$PMA_DIR.new" || { rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao copiar o phpMyAdmin."; }
  if [ -d "$PMA_DIR" ]; then mv "$PMA_DIR" "$PMA_DIR.old"; fi
  if ! mv "$PMA_DIR.new" "$PMA_DIR"; then
    if [ -d "$PMA_DIR.old" ]; then mv "$PMA_DIR.old" "$PMA_DIR"; fi
    rm -rf "$tmp" "$PMA_DIR.new"; die "Falha ao instalar o phpMyAdmin; a versão anterior foi reposta."
  fi
  se_restore "$PMA_DIR"
  rm -rf "$PMA_DIR.old" "$tmp"
  if [ -n "$cur" ]; then echo "phpMyAdmin atualizado de $cur para $latest."; else echo "phpMyAdmin $latest instalado."; fi
  return 0
}

cmd_db_admin_passwd(){
  local pw="${1:-}"
  if [ -z "$pw" ]; then pw=$(gen_pass 24)
  else valid_pass "$pw" || die "Password inválida: 8 a 64 caracteres (letras, números e . _ @ % + = : , ! # * -)."; fi
  if dbuser_exists "$DB_ADMIN"; then
    db_exec "ALTER USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" || die "Falha ao alterar a password de $DB_ADMIN."
    echo "Password da conta de administração alterada."
  else
    db_exec "CREATE USER '$DB_ADMIN'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON *.* TO '$DB_ADMIN'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" || { db_exec "DROP USER IF EXISTS '$DB_ADMIN'@'localhost';" >/dev/null 2>&1; die "Falha ao criar a conta $DB_ADMIN."; }
    echo "Conta de administração criada (acesso a todas as bases de dados, só a partir de localhost)."
  fi
  printf 'Utilizador: %s\nPassword: %s\n' "$DB_ADMIN" "$pw"
  return 0
}

# ---------- comandos: sistema ----------
cmd_php_list(){
  local v n c
  printf '%-8s %-10s %-6s %s\n' VERSAO ESTADO SITES ""
  for v in $(php_installed); do
    c=0
    for n in $(site_names); do [ "$(site_get "$n" PHP)" = "$v" ] && c=$((c+1)); done
    printf '%-8s %-10s %-6s %s\n' "$v" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" "$c" \
      "$([ "$v" = "$DEFAULT_PHP" ] && echo '(predefinida)')"
  done
  return 0
}

cmd_status(){
  local v
  printf '%-26s %s\n' nginx "$(systemctl is-active nginx 2>/dev/null)"
  printf '%-26s %s\n' mariadb "$(systemctl is-active mariadb 2>/dev/null)"
  for v in $(php_installed); do
    printf '%-26s %s\n' "$(php_service "$v")" "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)"
  done
  printf '%-26s %s\n' minipainel-worker.path "$(systemctl is-active minipainel-worker.path 2>/dev/null)"
  echo
  echo "Painel: https://<IP-do-servidor>:$PANEL_PORT   PHP predefinido: $DEFAULT_PHP   Sites: $(site_names | wc -l)"
  return 0
}

cmd_service(){
  local id="${1:-}" act="${2:-}" unit name v="" out label
  case "$act" in
    reload) label=recarregado ;; restart) label=reiniciado ;; start) label=iniciado ;; stop) label=parado ;;
    *) die "Ação inválida: usa reload, restart, start ou stop." ;;
  esac
  case "$id" in
    nginx)   unit=nginx;   name=nginx ;;
    mariadb) unit=mariadb; name=MariaDB ;;
    php-*)   v="${id#php-}"; php_is_installed "$v" || die "PHP $v não está instalado."
             unit=$(php_service "$v"); name="PHP-FPM $v" ;;
    *) die "Serviço desconhecido: $id (nginx, mariadb ou php-X.Y)." ;;
  esac
  if [ "$act" = stop ]; then
    [ "$id" = nginx ] && die "Parar o nginx deixaria o painel inacessível. Usa restart."
    [ "$id" = mariadb ] && die "Parar o MariaDB deixaria todos os sites sem base de dados. Usa restart."
    [ "$v" = "$PANEL_PHP" ] && die "O PHP $v é usado pelo próprio painel e não pode ser parado."
  fi
  [ "$id" = mariadb ] && [ "$act" = reload ] && die "O MariaDB não suporta recarregar. Usa restart."
  if [ "$act" = reload ] && ! systemctl is-active --quiet "$unit"; then die "$name não está a correr. Usa start."; fi
  if [ "$act" != stop ]; then
    if [ "$id" = nginx ]; then
      out=$(nginx -t 2>&1) || { echo "$out" >&2; die "Configuração do nginx inválida; nada foi feito."; }
    elif [ -n "$v" ]; then
      out=$("$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" 2>&1) || { echo "$out" >&2; die "Configuração do PHP-FPM $v inválida; nada foi feito."; }
    fi
  fi
  systemctl "$act" "$unit" >/dev/null 2>&1 || die "Falha ao executar '$act' em $unit (ver: journalctl -u $unit -n 30)."
  if [ "$act" != stop ]; then
    sleep 1
    systemctl is-active --quiet "$unit" || die "$name não ficou ativo (ver: journalctl -u $unit -n 30)."
  fi
  echo "$name $label."
  [ "$act" = stop ] && echo "Volta a arrancar automaticamente no próximo reinício do servidor."
  return 0
}

# ---------- firewall: ligações e bloqueio de IPs (nftables, tabela própria) ----------
FW_BLOCKS=/etc/minipainel/blocks.list   # ip|expira (epoch, 0 = permanente)|criado|origem|motivo
FW_ALLOW=/etc/minipainel/allow.list     # um IP ou rede por linha
FW_CONF=/etc/minipainel/firewall.conf   # AUTO, LIMIT, DURATION
FW_STATE=$DATA/stats/fw.json
FW_ADMIN=$DATA/logs/admin-ips.json      # IPs de onde o painel foi usado (escrito pelo painel)

fw_has_nft(){ command -v nft >/dev/null 2>&1; }
fw_ip_valid(){
  local re4='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
  local re6='^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'
  if [[ "$1" =~ $re4 ]]; then
    local o x; IFS=. read -ra o <<<"${1%%/*}"
    for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
    return 0
  fi
  [[ "$1" =~ $re6 ]]
}
fw_fam(){ if [[ "$1" == *:* ]]; then echo 6; else echo 4; fi; }
fw_prefix(){ if [[ "$1" == */* ]]; then echo "${1#*/}"; elif [[ "$1" == *:* ]]; then echo 128; else echo 32; fi; }
ip2int(){ local a b c d; IFS=. read -r a b c d <<<"${1%%/*}"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
in_cidr4(){ # ip cidr
  local bits mask; bits=$(fw_prefix "$2")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$1") & mask )) -eq $(( $(ip2int "$2") & mask )) ]
}
fw_overlap(){ # a b — verdadeiro se uma rede contém a outra (IPv6: só igualdade exata)
  local a=$1 b=$2
  [ "$(fw_fam "$a")" = "$(fw_fam "$b")" ] || return 1
  if [ "$(fw_fam "$a")" = 4 ]; then in_cidr4 "${a%%/*}" "$b" || in_cidr4 "${b%%/*}" "$a"; return; fi
  [ "${a%%/*}" = "${b%%/*}" ]
}
fw_protected_list(){
  echo 127.0.0.1; echo ::1
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$'
  [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}'
  if [ -s "$FW_ADMIN" ]; then
    jq -r --argjson lim $(( EPOCHSECONDS - 7 * 86400 )) 'to_entries[] | select(.value > $lim) | .key' "$FW_ADMIN" 2>/dev/null
  fi
  return 0
}
fw_conf_get(){ local v; v=$(grep -m1 "^$1=" "$FW_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
fw_secs(){
  local re='^[0-9]{1,7}[smhd]?$'
  case "$1" in perm|permanente|0) echo 0; return 0 ;; esac
  [[ "$1" =~ $re ]] || return 1
  case "$1" in
    *s) echo "${1%s}" ;; *m) echo $(( ${1%m} * 60 )) ;; *h) echo $(( ${1%h} * 3600 )) ;; *d) echo $(( ${1%d} * 86400 )) ;; *) echo "$1" ;;
  esac
}
fw_init(){
  fw_has_nft || die "O nftables (nft) não está instalado."
  nft list table inet minipainel >/dev/null 2>&1 && return 0
  nft -f - <<'NFT' || die "Não foi possível criar a tabela nftables do painel."
table inet minipainel {
  set block4 { type ipv4_addr; flags interval, timeout; }
  set block6 { type ipv6_addr; flags interval, timeout; }
  chain input {
    type filter hook input priority -10; policy accept;
    ip saddr @block4 drop
    ip6 saddr @block6 drop
  }
}
NFT
}
fw_nft_add(){ # ip segundos
  local set el="$1"
  set="block$(fw_fam "$1")"
  [ "$2" -gt 0 ] && el="$1 timeout ${2}s"
  nft delete element inet minipainel "$set" "{ $1 }" >/dev/null 2>&1
  nft add element inet minipainel "$set" "{ $el }"
}
fw_nft_del(){ nft delete element inet minipainel "block$(fw_fam "$1")" "{ $1 }" >/dev/null 2>&1; return 0; }
fw_list_set(){ # reescreve a lista sem a linha do IP indicado e sem expirados
  local skip=$1 tmp="$FW_BLOCKS.tmp"
  [ -f "$FW_BLOCKS" ] || : > "$FW_BLOCKS"
  awk -F'|' -v s="$skip" -v now="$EPOCHSECONDS" '$1 != s && ($2 == 0 || $2 > now)' "$FW_BLOCKS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$FW_BLOCKS"
}
fw_write_state(){
  local blocks allow nftok=false
  fw_has_nft && nft list table inet minipainel >/dev/null 2>&1 && nftok=true
  blocks=$( [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
      jq -cn --arg ip "$ip" --arg ex "$ex" --arg cr "$cr" --arg by "$by" --arg rs "$rs" '{ip:$ip, exp:($ex|tonumber), created:($cr|tonumber), by:$by, reason:$rs}'
    done | jq -cs '.')
  allow=$( [ -f "$FW_ALLOW" ] && grep -v '^\s*\(#\|$\)' "$FW_ALLOW" | awk '{print $1}' | jq -R . | jq -cs '.')
  jq -n --argjson b "${blocks:-[]}" --argjson a "${allow:-[]}" --argjson nft "$nftok" \
    --arg on "$(fw_conf_get AUTO 0)" --arg lim "$(fw_conf_get LIMIT 150)" --arg dur "$(fw_conf_get DURATION 3600)" \
    '{nft:$nft, auto:{on:($on=="1"), limit:($lim|tonumber), duration:($dur|tonumber)}, blocks:$b, allow:$a}' > "$FW_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$FW_STATE.tmp" && chmod 640 "$FW_STATE.tmp" && mv -f "$FW_STATE.tmp" "$FW_STATE"
  return 0
}

cmd_block(){
  local ip="${1:-}" dur="24h" reason="" by="manual" extra="" secs exp p
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) dur="${2:-}"; shift 2 || shift ;;
      --reason) reason="${2:-}"; shift 2 || shift ;;
      --by) by="${2:-}"; shift 2 || shift ;;
      --protect) extra="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ "$(fw_fam "$ip")" = 4 ] && [ "$(fw_prefix "$ip")" -lt 8 ]; then die "Rede demasiado grande (mínimo /8)."; fi
  if [ "$(fw_fam "$ip")" = 6 ] && [ "$(fw_prefix "$ip")" -lt 32 ]; then die "Rede demasiado grande (mínimo /32)."; fi
  case "$by" in manual|auto) ;; *) by=manual ;; esac
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur (ex.: 3600s, 1h, 24h, 7d ou perm)."
  reason=$(printf '%s' "$reason" | tr -d '|\r\n' | cut -c1-80)
  p=$( { fw_protected_list; if [ -n "$extra" ] && fw_ip_valid "$extra"; then echo "$extra"; fi; } | sort -u | while read -r q; do
         if [ -n "$q" ] && fw_ip_valid "$q" && fw_overlap "$ip" "$q"; then echo "$q"; break; fi
       done )
  [ -z "$p" ] || die "Não é possível bloquear $ip: abrange $p, que está protegido (este servidor, IP de confiança ou IP de onde usas o painel)."
  fw_init
  fw_nft_add "$ip" "$secs" || die "O nftables recusou o bloqueio de $ip."
  exp=0; [ "$secs" -gt 0 ] && exp=$(( EPOCHSECONDS + secs ))
  fw_list_set "$ip"
  echo "$ip|$exp|$EPOCHSECONDS|$by|$reason" >> "$FW_BLOCKS"
  ss -K dst "$ip" >/dev/null 2>&1
  fw_write_state
  if [ "$secs" -gt 0 ]; then echo "$ip bloqueado até $(date -d "@$exp" '+%d/%m/%Y %H:%M'). Ligações abertas cortadas."
  else echo "$ip bloqueado permanentemente. Ligações abertas cortadas."; fi
  return 0
}
cmd_unblock(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  fw_has_nft && fw_nft_del "$ip"
  fw_list_set "$ip"
  fw_write_state
  echo "$ip desbloqueado."
  return 0
}
cmd_block_list(){
  printf '%-40s %-17s %-8s %s\n' "IP / REDE" "EXPIRA" "ORIGEM" "MOTIVO"
  [ -f "$FW_BLOCKS" ] && awk -F'|' -v now="$EPOCHSECONDS" '$2 == 0 || $2 > now' "$FW_BLOCKS" | while IFS='|' read -r ip ex cr by rs; do
    printf '%-40s %-17s %-8s %s\n' "$ip" "$([ "$ex" = 0 ] && echo permanente || date -d "@$ex" '+%d/%m/%Y %H:%M')" "$by" "$rs"
  done
  return 0
}
cmd_allow_add(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  touch "$FW_ALLOW"; chmod 600 "$FW_ALLOW"
  grep -qxF "$ip" "$FW_ALLOW" || echo "$ip" >> "$FW_ALLOW"
  if [ -f "$FW_BLOCKS" ] && cut -d'|' -f1 "$FW_BLOCKS" | grep -qxF "$ip"; then fw_has_nft && fw_nft_del "$ip"; fw_list_set "$ip"; fi
  fw_write_state
  echo "$ip adicionado aos IPs de confiança (nunca é bloqueado)."
  return 0
}
cmd_allow_del(){
  local ip="${1:-}"
  fw_ip_valid "$ip" || die "IP ou rede inválida: $ip"
  if [ -f "$FW_ALLOW" ]; then grep -vxF "$ip" "$FW_ALLOW" > "$FW_ALLOW.tmp"; mv -f "$FW_ALLOW.tmp" "$FW_ALLOW"; fi
  [ -f "$FW_ALLOW" ] && grep -qxF "$ip" "$FW_ALLOW" && die "Não foi possível remover $ip."
  chmod 600 "$FW_ALLOW" 2>/dev/null
  fw_write_state
  echo "$ip removido dos IPs de confiança."
  return 0
}
cmd_fw_auto(){
  local on="${1:-}" lim dur secs re='^[0-9]{1,6}$'
  case "$on" in on|1) on=1 ;; off|0) on=0 ;; *) die "Usa: mpanel fw-auto on|off [--limit N] [--duration 1h]" ;; esac
  shift
  lim=$(fw_conf_get LIMIT 150); dur=$(fw_conf_get DURATION 3600)
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) lim="${2:-}"; shift 2 || shift ;;
      --duration) dur="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$lim" =~ $re ]] && [ "$lim" -ge 10 ] || die "O limite tem de ser um número igual ou superior a 10."
  secs=$(fw_secs "$dur") || die "Duração inválida: $dur"
  [ "$secs" -gt 0 ] || die "O bloqueio automático tem de ter duração (não pode ser permanente)."
  printf 'AUTO=%s\nLIMIT=%s\nDURATION=%s\n' "$on" "$lim" "$secs" > "$FW_CONF"; chmod 644 "$FW_CONF"
  fw_write_state
  if [ "$on" = 1 ]; then echo "Bloqueio automático ativo: IPs com mais de $lim ligações abertas ficam bloqueados durante $(( secs / 60 )) min."
  else echo "Bloqueio automático desativado."; fi
  return 0
}
cmd_fw_restore(){
  local ip ex cr by rs left
  fw_has_nft || { warn "O nftables não está instalado."; return 0; }
  nft delete table inet minipainel >/dev/null 2>&1
  fw_init
  fw_list_set ""
  [ -f "$FW_BLOCKS" ] && while IFS='|' read -r ip ex cr by rs; do
    left=0; [ "$ex" != 0 ] && left=$(( ex - EPOCHSECONDS ))
    [ "$ex" != 0 ] && [ "$left" -le 0 ] && continue
    fw_nft_add "$ip" "$left" >/dev/null 2>&1 || warn "Não foi possível repor o bloqueio de $ip."
  done < "$FW_BLOCKS"
  fw_write_state
  echo "Bloqueios repostos: $( [ -f "$FW_BLOCKS" ] && wc -l < "$FW_BLOCKS" || echo 0)."
  return 0
}
cmd_conn_list(){
  local f=$DATA/stats/conns.json ip="${1:-}"
  [ -s "$f" ] || die "Ainda não há dados. Verifica: systemctl status minipainel-stats"
  if [ -n "$ip" ]; then
    jq -r --arg ip "$ip" '.ips[] | select(.ip == $ip) | "\(.ip): \(.n) ligações (\(.syn) em espera)", (.ports | to_entries[] | "  porta \(.key): \(.value)")' "$f"
  else
    jq -r '"Ligações abertas: \(.total)   IPs distintos: \(.distinct)   Em espera (SYN): \(.syn)", (.ips[:30][] | "  \(.n)\t\(.ip)\t" + (.ports | to_entries | map("\(.key)(\(.value))") | join(" ")))' "$f"
  fi
  return 0
}

# ---------- tarefas agendadas (cron) por site, como o utilizador do site ----------
CRON_DIR=/etc/minipainel/cron          # <site>.json (definições) e <site>/<id>.sh (comandos)
cron_json(){ echo "$CRON_DIR/$1.json"; }
cron_valid_when(){
  local w="$1" f re='^(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/[0-9]+)?(,(\*|[0-9A-Za-z]+(-[0-9A-Za-z]+)?)(/[0-9]+)?)*$'
  case "$w" in @hourly|@daily|@weekly|@monthly|@yearly|@annually) return 0 ;; esac
  local -a parts; read -ra parts <<<"$w"
  [ ${#parts[@]} -eq 5 ] || return 1
  for f in "${parts[@]}"; do [[ "$f" =~ $re ]] || return 1; done
  return 0
}
cron_valid_cmd(){ [ -n "$1" ] && [ ${#1} -le 2000 ] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\r'* ]]; }
cron_load(){ local f; f=$(cron_json "$1"); if [ -s "$f" ]; then cat "$f"; else echo '[]'; fi; }
cron_save(){ # site json
  local f; f=$(cron_json "$1")
  install -d -m 755 "$CRON_DIR"
  printf '%s\n' "$2" | jq '.' > "$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}
cron_write_site(){ # gera /etc/cron.d/minipainel-<site>, os scripts e o php da versão do site
  local n=$1 u="mp_$1" j sd cf v id
  sd="$CRON_DIR/$n"; cf="/etc/cron.d/minipainel-$n"
  id "$u" >/dev/null 2>&1 || return 0
  j=$(cron_load "$n")
  install -d -o root -g "$u" -m 750 "$sd" "$sd/bin"
  v=$(site_get "$n" PHP)
  [ -n "$v" ] && ln -sfn "$(php_cli "$v")" "$sd/bin/php"
  find "$sd" -maxdepth 1 -name '*.sh' -type f | while read -r f; do
    id=$(basename "$f" .sh)
    [ "$(printf '%s' "$j" | jq --arg id "$id" 'map(select(.id == $id)) | length')" = 0 ] && rm -f "$f"
  done
  printf '%s' "$j" | jq -c '.[]' | while read -r row; do
    id=$(jq -r '.id' <<<"$row")
    { printf '#!/bin/sh\n# IDDigital Hosting — tarefa %s do site %s (gerido pelo painel)\n' "$id" "$n"; jq -r '.cmd' <<<"$row"; } > "$sd/$id.sh"
    chown root:"$u" "$sd/$id.sh"; chmod 750 "$sd/$id.sh"
  done
  if [ "$(printf '%s' "$j" | jq 'map(select(.on)) | length')" = 0 ]; then
    rm -f "$cf"
  else
    {
      printf '# IDDigital Hosting — tarefas agendadas do site %s (gerado pelo painel; não editar à mão)\n' "$n"
      printf 'SHELL=/bin/sh\nPATH=/usr/local/bin:/usr/bin:/bin\nMAILTO=""\n'
      printf '%s' "$j" | jq -r --arg u "$u" --arg n "$n" '.[] | select(.on) | "\(.when) \($u) /usr/local/sbin/mpanel-cron \($n) \(.id)"'
    } > "$cf.tmp" && chmod 644 "$cf.tmp" && mv -f "$cf.tmp" "$cf"
  fi
  touch /etc/cron.d 2>/dev/null
  return 0
}
cron_need(){ valid_site "$1" && site_exists "$1" || die "O site '$1' não existe."; }
cron_need_id(){ local re='^[a-f0-9]{8}$'; [[ "$2" =~ $re ]] || die "Identificador inválido: $2"
  [ "$(cron_load "$1" | jq --arg id "$2" 'map(select(.id == $id)) | length')" = 1 ] || die "A tarefa $2 não existe no site $1."; }

cmd_cron_list(){
  local n f
  printf '%-10s %-12s %-6s %-20s %s\n' ID SITE ESTADO QUANDO COMANDO
  for n in $(site_names); do
    [ -z "${1:-}" ] || [ "$1" = "$n" ] || continue
    cron_load "$n" | jq -r --arg n "$n" '.[] | [.id, $n, (if .on then "ativa" else "pausa" end), .when, .cmd] | @tsv' |
      while IFS=$'\t' read -r i s e w c; do printf '%-10s %-12s %-6s %-20s %s\n' "$i" "$s" "$e" "$w" "$c"; done
  done
  return 0
}
cron_parse(){ # define WHEN CMD LABEL ON a partir das opções
  while [ $# -gt 0 ]; do
    case "$1" in
      --when) WHEN="${2:-}"; shift 2 || shift ;;
      --cmd) CMD="${2:-}"; shift 2 || shift ;;
      --label) LABEL="${2:-}"; shift 2 || shift ;;
      --off) ON=false; shift ;;
      --on) ON=true; shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
}
cmd_cron_add(){
  local n="${1:-}" id j WHEN="" CMD="" LABEL="" ON=true
  [ $# -gt 0 ] && shift
  cron_need "$n"; cron_parse "$@"
  cron_valid_when "$WHEN" || die "Periodicidade inválida: '$WHEN' (5 campos: minuto hora dia mês dia-da-semana)."
  cron_valid_cmd "$CMD" || die "Comando inválido (obrigatório, numa só linha, até 2000 caracteres)."
  LABEL=$(printf '%s' "$LABEL" | tr -d '\r\n' | cut -c1-80)
  id=$(openssl rand -hex 4)
  j=$(cron_load "$n" | jq --arg id "$id" --arg w "$WHEN" --arg c "$CMD" --arg d "$LABEL" --argjson on "$ON" --arg t "$EPOCHSECONDS" \
      '. + [{id:$id, when:$w, cmd:$c, desc:$d, on:$on, created:($t|tonumber)}]')
  cron_save "$n" "$j"; cron_write_site "$n"
  echo "Tarefa $id criada no site $n ($WHEN)."
  return 0
}
cmd_cron_edit(){
  local n="${1:-}" id="${2:-}" j cur WHEN CMD LABEL ON
  cron_need "$n"; cron_need_id "$n" "$id"; shift 2
  cur=$(cron_load "$n" | jq -c --arg id "$id" '.[] | select(.id == $id)')
  WHEN=$(jq -r '.when' <<<"$cur"); CMD=$(jq -r '.cmd' <<<"$cur"); LABEL=$(jq -r '.desc' <<<"$cur"); ON=$(jq -r '.on' <<<"$cur")
  cron_parse "$@"
  cron_valid_when "$WHEN" || die "Periodicidade inválida: '$WHEN'."
  cron_valid_cmd "$CMD" || die "Comando inválido (obrigatório, numa só linha, até 2000 caracteres)."
  LABEL=$(printf '%s' "$LABEL" | tr -d '\r\n' | cut -c1-80)
  j=$(cron_load "$n" | jq --arg id "$id" --arg w "$WHEN" --arg c "$CMD" --arg d "$LABEL" --argjson on "$ON" \
      'map(if .id == $id then .when = $w | .cmd = $c | .desc = $d | .on = $on else . end)')
  cron_save "$n" "$j"; cron_write_site "$n"
  echo "Tarefa $id atualizada."
  return 0
}
cmd_cron_toggle(){
  local n="${1:-}" id="${2:-}" on=$3 j
  cron_need "$n"; cron_need_id "$n" "$id"
  j=$(cron_load "$n" | jq --arg id "$id" --argjson on "$on" 'map(if .id == $id then .on = $on else . end)')
  cron_save "$n" "$j"; cron_write_site "$n"
  if [ "$on" = true ]; then echo "Tarefa $id ativada."; else echo "Tarefa $id em pausa."; fi
  return 0
}
cmd_cron_del(){
  local n="${1:-}" id="${2:-}" j
  cron_need "$n"; cron_need_id "$n" "$id"
  j=$(cron_load "$n" | jq --arg id "$id" 'map(select(.id != $id))')
  cron_save "$n" "$j"; cron_write_site "$n"
  rm -f "$WWW_ROOT/$n/logs/cron-$id.log" "$WWW_ROOT/$n/logs/cron-$id.status" "$WWW_ROOT/$n/tmp/.cron-$id.lock"
  echo "Tarefa $id apagada."
  return 0
}
cmd_cron_run(){
  local n="${1:-}" id="${2:-}" st i s1 out
  cron_need "$n"; cron_need_id "$n" "$id"
  cron_write_site "$n"
  st="$WWW_ROOT/$n/logs/cron-$id.status"
  [ -L "$st" ] && rm -f "$st"
  s1=$(cat "$st" 2>/dev/null)
  setsid runuser -u "mp_$n" -- /usr/local/sbin/mpanel-cron "$n" "$id" >/dev/null 2>&1 < /dev/null &
  for i in $(seq 1 40); do
    sleep 0.5
    out=$(cat "$st" 2>/dev/null)
    if [ -n "$out" ] && [ "$out" != "$s1" ] && [[ "$out" != *running* ]]; then
      echo "Tarefa $id executada; terminou com código ${out##* }."
      if [ ! -L "$WWW_ROOT/$n/logs/cron-$id.log" ]; then echo "Últimas linhas:"; tail -n 12 "$WWW_ROOT/$n/logs/cron-$id.log" 2>/dev/null | grep -v '^=== '; fi
      return 0
    fi
  done
  echo "Tarefa $id iniciada; ainda está a correr. O resultado aparece no painel dentro de um minuto."
  return 0
}
cmd_cron_sync(){
  local n f
  install -d -m 755 "$CRON_DIR"
  for n in $(site_names); do cron_write_site "$n"; done
  for f in /etc/cron.d/minipainel-*; do
    [ -f "$f" ] || continue
    n=${f#/etc/cron.d/minipainel-}; site_exists "$n" || rm -f "$f"
  done
  echo "Tarefas agendadas sincronizadas."
  return 0
}
cron_state_json(){ # todas as tarefas, para o painel
  local n
  for n in $(site_names); do cron_load "$n" | jq -c --arg n "$n" '.[] | . + {site:$n}'; done | jq -cs '.'
}

# ---------- associação de bases de dados a sites ----------
DBMAP=/etc/minipainel/dbmap.json
dbmap_load(){ if [ -s "$DBMAP" ]; then cat "$DBMAP"; else echo '{}'; fi; }
dbmap_set(){ # db site|""
  local j; j=$(dbmap_load | jq --arg d "$1" --arg s "$2" 'if $s == "" then del(.[$d]) else .[$d] = $s end')
  printf '%s\n' "$j" > "$DBMAP.tmp" && chmod 600 "$DBMAP.tmp" && mv -f "$DBMAP.tmp" "$DBMAP"
}
dbs_of_site(){ dbmap_load | jq -r --arg s "$1" 'to_entries[] | select(.value == $s) | .key'; }
cmd_db_link(){
  local d="${1:-}" s="${2:-}"
  valid_db "$d" && db_exists "$d" || die "A base de dados '$d' não existe."
  if [ "$s" = none ] || [ -z "$s" ]; then dbmap_set "$d" ""; echo "Base de dados $d já não está associada a nenhum site."; return 0; fi
  valid_site "$s" && site_exists "$s" || die "O site '$s' não existe."
  dbmap_set "$d" "$s"
  echo "Base de dados $d associada ao site $s (entra nos backups do site)."
  return 0
}

# ---------- backups (local + destinos remotos via rclone) ----------
BK_DIR=/var/backups/minipainel
BK_CONF=/etc/minipainel/backup.conf
BK_RCLONE=/etc/minipainel/rclone.conf
BK_REMOTES=/etc/minipainel/backup-remotes.json   # [{name,type,root}]
BK_STATE=$DATA/stats/backup.json
BK_LOCK=/run/minipainel-backup.lock
bk_conf(){ local v; v=$(grep -m1 "^$1=" "$BK_CONF" 2>/dev/null | cut -d= -f2-); echo "${v:-$2}"; }
bk_remotes(){ if [ -s "$BK_REMOTES" ]; then cat "$BK_REMOTES"; else echo '[]'; fi; }
bk_rc(){ rclone --config "$BK_RCLONE" "$@"; }
bk_remote_root(){ bk_remotes | jq -r --arg n "$1" '.[] | select(.name == $n) | .root'; }
bk_host(){ hostname -s 2>/dev/null || echo servidor; }
bk_gz(){ if command -v pigz >/dev/null 2>&1; then echo "pigz -6"; else echo "gzip -6"; fi; }
bk_status(){ # running: texto do passo ou vazio
  local f=$DATA/stats/backup-run.json
  if [ -n "${1:-}" ]; then jq -n --arg s "$1" --arg t "$EPOCHSECONDS" '{step:$s, since:($t|tonumber)}' > "$f.tmp" && chown root:"$PANEL_SYSUSER" "$f.tmp" && chmod 640 "$f.tmp" && mv -f "$f.tmp" "$f"
  else rm -f "$f"; fi
}
bk_write_state(){
  local sets total
  sets=$(find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -c '.' "$m" 2>/dev/null; done | jq -cs 'sort_by(-.created)')
  total=$(du -sb "$BK_DIR" 2>/dev/null | awk '{print $1}')
  jq -n --argjson sets "${sets:-[]}" --argjson rem "$(bk_remotes)" --arg total "${total:-0}" \
     --arg en "$(bk_conf ENABLED 1)" --arg time "$(bk_conf TIME 03:00)" --arg kd "$(bk_conf KEEP_DAILY 7)" --arg kw "$(bk_conf KEEP_WEEKLY 4)" \
     --arg km "$(bk_conf KEEP_MONTHLY 3)" --arg r "$(bk_conf REMOTE '')" --argjson last "$(cat "$DATA/stats/backup-last.json" 2>/dev/null || echo null)" \
     '{conf:{enabled:($en=="1"), time:$time, keep_daily:($kd|tonumber), keep_weekly:($kw|tonumber), keep_monthly:($km|tonumber), remote:$r},
       remotes:$rem, sets:$sets, total:($total|tonumber), last:$last}' > "$BK_STATE.tmp" \
    && chown root:"$PANEL_SYSUSER" "$BK_STATE.tmp" && chmod 640 "$BK_STATE.tmp" && mv -f "$BK_STATE.tmp" "$BK_STATE"
  return 0
}
bk_cron_apply(){
  local t h m
  t=$(bk_conf TIME 03:00); h=$((10#${t%%:*})); m=$((10#${t##*:}))
  if [ "$(bk_conf ENABLED 1)" = 1 ]; then
    printf '# IDDigital Hosting — backups automáticos (gerado pelo painel)\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nMAILTO=""\n%d %d * * * root /usr/local/sbin/mpanel backup-run --auto >/dev/null 2>&1\n' "$m" "$h" > /etc/cron.d/minipainel-backup
    chmod 644 /etc/cron.d/minipainel-backup
  else
    rm -f /etc/cron.d/minipainel-backup
  fi
  touch /etc/cron.d 2>/dev/null
  return 0
}

# Cria um conjunto: $1 = site | _bd | _sistema ; $2 = auto|manual|pre-restauro ; imprime o id
bk_make(){
  local s=$1 type=$2 id dir gz d u files=false dbs="[]" size rc
  id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"
  [ -e "$dir" ] && { sleep 1; id=$(date '+%Y%m%d-%H%M%S'); dir="$BK_DIR/$s/$id"; }
  install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR" "$BK_DIR/$s"
  install -d -m 700 "$dir.part"
  gz=$(bk_gz)
  if [ "$s" = _sistema ]; then
    bk_status "Configuração do sistema"
    tar -C / -czf "$dir.part/sistema.tar.gz" --ignore-failed-read etc/minipainel etc/nginx/minipainel etc/cron.d var/lib/minipainel/auth.json 2>/dev/null
    files=true
  elif [ "$s" != _bd ]; then
    bk_status "Ficheiros de $s"
    tar -C "$WWW_ROOT" --exclude="$s/tmp" -I "$gz" -cpf "$dir.part/ficheiros.tar.gz" "$s"; rc=$?
    [ "$rc" -le 1 ] || { rm -rf "$dir.part"; echo "ERRO: falhou a cópia dos ficheiros de $s (tar $rc)." >&2; return 1; }
    install -d -m 700 "$dir.part/config"
    cp -p "$SITES_DIR/$s.conf" "$dir.part/config/site.conf" 2>/dev/null
    cp -p "$CRON_DIR/$s.json" "$dir.part/config/cron.json" 2>/dev/null
    files=true
  fi
  local list=""
  if [ "$s" = _bd ]; then
    list=$(db_sizes | awk '{print $1}' | while read -r d; do [ -n "$d" ] && [ "$d" != "$DB_ADMIN" ] && [ -z "$(dbmap_load | jq -r --arg d "$d" '.[$d] // empty')" ] && echo "$d"; done)
  elif [ "$s" != _sistema ]; then
    list=$(dbs_of_site "$s")
  fi
  for d in $list; do
    db_exists "$d" || continue
    bk_status "Base de dados $d"
    mysqldump -uroot --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$d" 2>"$dir.part/.err" | $gz > "$dir.part/bd-$d.sql.gz"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then echo "ERRO: falhou a cópia da base de dados $d: $(head -c 300 "$dir.part/.err")" >&2; rm -rf "$dir.part"; return 1; fi
    u=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
    if [ "$u" = 1 ]; then
      { db_q "SHOW CREATE USER '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; db_q "SHOW GRANTS FOR '$d'@'localhost'" 2>/dev/null | sed 's/$/;/'; } > "$dir.part/bd-$d.user.sql"
    fi
    dbs=$(jq -c --arg d "$d" '. + [$d]' <<<"$dbs")
  done
  rm -f "$dir.part/.err"
  size=$(du -sb "$dir.part" | awk '{print $1}')
  jq -n --arg s "$s" --arg id "$id" --arg t "$type" --arg c "$EPOCHSECONDS" --arg sz "$size" --argjson f "$files" --argjson dbs "$dbs" \
        --arg v "$MP_VERSION" --arg php "$( [ -f "$SITES_DIR/$s.conf" ] && site_get "$s" PHP)" \
        '{site:$s, id:$id, type:$t, created:($c|tonumber), size:($sz|tonumber), files:$f, dbs:$dbs, version:$v, php:$php, remote:""}' > "$dir.part/manifest.json"
  chown -R root:"$PANEL_SYSUSER" "$dir.part"; find "$dir.part" -type f -exec chmod 640 {} +; chmod 750 "$dir.part"; [ -d "$dir.part/config" ] && chmod 750 "$dir.part/config"
  mv "$dir.part" "$dir"
  echo "$id"
}
bk_upload(){ # site id remote
  local s=$1 id=$2 r=$3 root
  root=$(bk_remote_root "$r"); [ -n "$root" ] || { echo "Destino remoto '$r' não existe." >&2; return 1; }
  bk_status "Envio de $s para $r"
  bk_rc copy "$BK_DIR/$s/$id" "$r:$root/$(bk_host)/$s/$id" --transfers 2 2>&1 | tail -n 3 >&2
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
  jq --arg r "$r" '.remote = $r' "$BK_DIR/$s/$id/manifest.json" > "$BK_DIR/$s/$id/manifest.tmp" && mv -f "$BK_DIR/$s/$id/manifest.tmp" "$BK_DIR/$s/$id/manifest.json"
  chown root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id/manifest.json"; chmod 640 "$BK_DIR/$s/$id/manifest.json"
}
# Retenção avô-pai-filho: lê ids (AAAAMMDD-HHMMSS) no stdin e imprime os que devem ser apagados
bk_gfs(){
  local kd kw km
  kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3)
  sort -r | while read -r id; do
    [ -n "$id" ] || continue
    echo "$id $(date -d "${id:0:8}" '+%G%V' 2>/dev/null || echo 0)"
  done | awk -v kd="$kd" -v kw="$kw" -v km="$km" '
    { id = $1; day = substr(id, 1, 8); wk = $2; mo = substr(id, 1, 6); keep = 0
      if (!(day in D) && nd < kd) { D[day] = 1; nd++; keep = 1 }
      if (!(wk in W) && nw < kw) { W[wk] = 1; nw++; keep = 1 }
      if (!(mo in M) && nm < km) { M[mo] = 1; nm++; keep = 1 }
      if (!keep) print id }'
}
bk_prune_local(){ # site
  local s=$1 id
  [ -d "$BK_DIR/$s" ] || return 0
  for id in $(for m in "$BK_DIR/$s"/*/manifest.json; do [ -f "$m" ] && jq -r 'select(.type == "auto") | .id' "$m"; done | bk_gfs); do
    rm -rf "${BK_DIR:?}/$s/$id"
  done
  find "$BK_DIR/$s" -maxdepth 1 -name '*.part' -mmin +720 -exec rm -rf {} + 2>/dev/null
}
bk_prune_remote(){ # site remote
  local s=$1 r=$2 root id
  root=$(bk_remote_root "$r"); [ -n "$root" ] || return 0
  for id in $(bk_rc lsf --dirs-only "$r:$root/$(bk_host)/$s" 2>/dev/null | tr -d '/' | grep -E '^[0-9]{8}-[0-9]{6}$' | bk_gfs); do
    bk_rc purge "$r:$root/$(bk_host)/$s/$id" >/dev/null 2>&1
  done
}

cmd_backup_run(){
  local auto=0 only="" remote="" s id ok=0 fail=0 msgs="" t0 used r
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --site) only="${2:-}"; shift 2 || shift ;;
      --remote) remote="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  exec 8>"$BK_LOCK"; flock -n 8 || die "Já está a decorrer um backup."
  used=$(df -P "$(dirname "$BK_DIR")" | awk 'NR==2{gsub("%","",$5); print $5}')
  if [ "${used:-0}" -ge 90 ]; then
    jq -n --arg t "$EPOCHSECONDS" '{ts:($t|tonumber), ok:false, msg:"Backup cancelado: o disco está acima de 90% de ocupação.", duration:0}' > "$DATA/stats/backup-last.json"
    bk_write_state; die "Backup cancelado: o disco está acima de 90% de ocupação."
  fi
  [ "$auto" = 1 ] && remote=$(bk_conf REMOTE '')
  t0=$EPOCHSECONDS
  local targets
  if [ -n "$only" ]; then
    case "$only" in _bd|_sistema) ;; *) valid_site "$only" && site_exists "$only" || die "O site '$only' não existe." ;; esac
    targets=$only
  else
    targets="$(site_names) _bd _sistema"
  fi
  local errf; errf=$(mktemp)
  for s in $targets; do
    : > "$errf"
    if id=$(bk_make "$s" "$([ "$auto" = 1 ] && echo auto || echo manual)" 2>"$errf"); then
      ok=$((ok + 1))
      if [ -n "$remote" ]; then
        bk_upload "$s" "$id" "$remote" 2>>"$errf" || { fail=$((fail + 1)); msgs+="$s: falhou o envio para $remote ($(tail -n 1 "$errf" | head -c 200)). "; }
      fi
      if [ "$auto" = 1 ]; then bk_prune_local "$s"; [ -n "$remote" ] && bk_prune_remote "$s" "$remote"; fi
    else
      fail=$((fail + 1)); msgs+="$s: $(tr '\n' ' ' < "$errf" | head -c 300) "
    fi
  done
  rm -f "$errf"
  bk_status ""
  jq -n --arg t "$EPOCHSECONDS" --arg d "$(( EPOCHSECONDS - t0 ))" --argjson ok "$([ "$fail" = 0 ] && echo true || echo false)" \
        --arg m "$( [ "$fail" = 0 ] && echo "$ok conjunto(s) guardado(s)${remote:+ e enviados para $remote}." || echo "$ok guardado(s), $fail com erro. $msgs")" \
        '{ts:($t|tonumber), ok:$ok, msg:$m, duration:($d|tonumber)}' > "$DATA/stats/backup-last.json"
  chown root:"$PANEL_SYSUSER" "$DATA/stats/backup-last.json"; chmod 640 "$DATA/stats/backup-last.json"
  bk_write_state
  if [ "$fail" = 0 ]; then echo "Backup concluído: $ok conjunto(s) em $(( EPOCHSECONDS - t0 ))s${remote:+, enviados para $remote}."; return 0; fi
  echo "Backup com erros: $msgs" >&2; return 1
}
cmd_backup_start(){ # lança em segundo plano (usado pelo painel)
  [ -n "$(flock -n "$BK_LOCK" true 2>&1 || echo busy)" ] && die "Já está a decorrer um backup."
  setsid /usr/local/sbin/mpanel backup-run "$@" >/dev/null 2>&1 < /dev/null &
  echo "Backup iniciado em segundo plano. O progresso aparece na página Backups."
  return 0
}
bk_need_set(){ # site id -> garante cópia local (vai buscar ao destino remoto se for preciso)
  local s=$1 id=$2 re='^[0-9]{8}-[0-9]{6}$' r root
  [[ "$id" =~ $re ]] || die "Identificador de backup inválido: $id"
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido: $s" ;; esac
  [ -f "$BK_DIR/$s/$id/manifest.json" ] && return 0
  r=$(bk_conf REMOTE ''); [ -n "$r" ] || die "O backup $id de $s não existe localmente."
  root=$(bk_remote_root "$r")
  bk_rc copy "$r:$root/$(bk_host)/$s/$id" "$BK_DIR/$s/$id" >/dev/null 2>&1 && [ -f "$BK_DIR/$s/$id/manifest.json" ] || die "O backup $id de $s não existe localmente nem em $r."
  chown -R root:"$PANEL_SYSUSER" "$BK_DIR/$s/$id"
}
cmd_bk_restore(){
  local s="${1:-}" id="${2:-}" what=all dir m d f uexists tmp pre="" created=0 port php
  [ $# -ge 2 ] && shift 2
  [ "${1:-}" = "--what" ] && what="${2:-all}"
  case "$what" in all|files|db) ;; *) die "Use --what all|files|db" ;; esac
  [ "$s" = _sistema ] && die "A configuração do sistema não é reposta pelo painel; extrai sistema.tar.gz manualmente se precisares."
  bk_need_set "$s" "$id"
  dir="$BK_DIR/$s/$id"; m="$dir/manifest.json"
  if [ "$s" != _bd ]; then
    if ! site_exists "$s"; then
      [ "$what" = db ] && die "O site $s não existe; repõe tudo (--what all) para o recriar."
      port=$(grep -m1 '^PORT=' "$dir/config/site.conf" 2>/dev/null | cut -d= -f2); php=$(jq -r '.php' "$m")
      php_is_installed "$php" || php=$DEFAULT_PHP
      if port_owner "$port" >/dev/null || port_listening "$port"; then port=""; fi
      ( cmd_site_add "$s" ${port:+--port "$port"} --php "$php" ) >/dev/null || die "Não foi possível recriar o site $s."
      created=1
      grep -E '^(MEM|UPLOAD|EXEC|INPUT_TIME|INPUT_VARS|DISPLAY_ERRORS)=' "$dir/config/site.conf" 2>/dev/null | while IFS='=' read -r k v; do site_set "$s" "$k" "$v"; done
      write_pool "$s" "$(site_get "$s" PHP)"; write_nginx "$s" "$(site_get "$s" PORT)" "$(site_get "$s" PHP)" "$(ngx_file "$s")"
      apply_php "$(site_get "$s" PHP)" >/dev/null 2>&1; apply_nginx >/dev/null 2>&1
    else
      pre=$(bk_make "$s" pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
    fi
  else
    pre=$(bk_make _bd pre-restauro 2>/dev/null) || die "Não foi possível criar a cópia de segurança antes de repor; nada foi alterado."
  fi
  if [ "$what" != db ] && [ "$s" != _bd ]; then
    tmp="$WWW_ROOT/.restauro-$s-$$"; mkdir -p "$tmp"
    tar -C "$tmp" -xzpf "$dir/ficheiros.tar.gz" "$s/public_html" || { rm -rf "$tmp"; die "Falhou a extração dos ficheiros."; }
    [ -d "$tmp/$s/public_html" ] || { rm -rf "$tmp"; die "O backup não contém public_html."; }
    mv "$WWW_ROOT/$s/public_html" "$WWW_ROOT/$s/.public_html.antes-$id" && mv "$tmp/$s/public_html" "$WWW_ROOT/$s/public_html" || {
      [ -d "$WWW_ROOT/$s/.public_html.antes-$id" ] && mv "$WWW_ROOT/$s/.public_html.antes-$id" "$WWW_ROOT/$s/public_html"; rm -rf "$tmp"; die "Falhou a substituição dos ficheiros; nada foi alterado."; }
    chown -R "mp_$s:mp_$s" "$WWW_ROOT/$s/public_html"; chmod 2750 "$WWW_ROOT/$s/public_html"
    se_restore "$WWW_ROOT/$s/public_html"
    rm -rf "$tmp" "$WWW_ROOT/$s/.public_html.antes-$id"
    if [ "$what" = all ] && [ -f "$dir/config/cron.json" ]; then cp "$dir/config/cron.json" "$CRON_DIR/$s.json"; chmod 600 "$CRON_DIR/$s.json"; cron_write_site "$s"; fi
  fi
  if [ "$what" != files ]; then
    for f in "$dir"/bd-*.sql.gz; do
      [ -f "$f" ] || continue
      d=${f##*/bd-}; d=${d%.sql.gz}; valid_db "$d" || continue
      db_exec "DROP DATABASE IF EXISTS \`$d\`; CREATE DATABASE \`$d\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || die "Falhou a recriação da base de dados $d."
      gzip -dc "$f" | mysql -uroot "$d" || die "Falhou a importação de $d${pre:+ (o estado anterior está no backup $pre)}."
      uexists=$(db_q "SELECT COUNT(*) FROM mysql.user WHERE User='$d' AND Host='localhost'" 2>/dev/null)
      if [ "$uexists" = 0 ] && [ -f "$dir/bd-$d.user.sql" ]; then mysql -uroot < "$dir/bd-$d.user.sql" 2>/dev/null; db_exec "FLUSH PRIVILEGES;"; fi
      [ "$s" != _bd ] && dbmap_set "$d" "$s"
    done
  fi
  bk_write_state
  echo "Backup $id de $s reposto ($what).${pre:+ O estado anterior ficou guardado no backup $pre.}$([ "$created" = 1 ] && echo " O site foi recriado.")"
  return 0
}
cmd_bk_delete(){
  local s="${1:-}" id="${2:-}" re='^[0-9]{8}-[0-9]{6}$'
  [[ "$id" =~ $re ]] || die "Identificador inválido."
  case "$s" in _bd|_sistema) ;; *) valid_site "$s" || die "Site inválido." ;; esac
  [ -d "$BK_DIR/$s/$id" ] || die "O backup $id de $s não existe."
  rm -rf "${BK_DIR:?}/$s/$id"; bk_write_state
  echo "Backup $id de $s apagado (cópia local)."
  return 0
}
cmd_bk_conf(){
  local en tm kd kw km r re_t='^([01][0-9]|2[0-3]):[0-5][0-9]$' re_n='^[0-9]{1,3}$'
  en=$(bk_conf ENABLED 1); tm=$(bk_conf TIME 03:00); kd=$(bk_conf KEEP_DAILY 7); kw=$(bk_conf KEEP_WEEKLY 4); km=$(bk_conf KEEP_MONTHLY 3); r=$(bk_conf REMOTE '')
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) en=1; shift ;; --off) en=0; shift ;;
      --time) tm="${2:-}"; shift 2 || shift ;;
      --daily) kd="${2:-}"; shift 2 || shift ;;
      --weekly) kw="${2:-}"; shift 2 || shift ;;
      --monthly) km="${2:-}"; shift 2 || shift ;;
      --remote) r="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  [[ "$tm" =~ $re_t ]] || die "Hora inválida: $tm (HH:MM)."
  for v in "$kd" "$kw" "$km"; do [[ "$v" =~ $re_n ]] || die "Retenção inválida: $v"; done
  [ "$kd" -ge 1 ] || die "Guarda pelo menos 1 backup diário."
  [ "$r" = none ] && r=""
  [ -z "$r" ] || [ -n "$(bk_remote_root "$r")" ] || die "O destino remoto '$r' não existe."
  printf 'ENABLED=%s\nTIME=%s\nKEEP_DAILY=%s\nKEEP_WEEKLY=%s\nKEEP_MONTHLY=%s\nREMOTE=%s\n' "$en" "$tm" "$kd" "$kw" "$km" "$r" > "$BK_CONF"; chmod 600 "$BK_CONF"
  bk_cron_apply; bk_write_state
  if [ "$en" = 1 ]; then echo "Backups automáticos todos os dias às $tm (guarda $kd diários, $kw semanais e $km mensais)${r:+, com cópia em $r}."
  else echo "Backups automáticos desativados."; fi
  return 0
}
cmd_bk_remote_add(){ # nome tipo opções...
  local n="${1:-}" t="${2:-}" root="" host="" port=22 user="" pass="" key="" prov=Other ep="" reg="" ak="" sk="" bucket="" raw="" re='^[a-z][a-z0-9-]{1,23}$'
  [ $# -ge 2 ] && shift 2
  [[ "$n" =~ $re ]] || die "Nome inválido (minúsculas, números e '-', 2 a 24 caracteres)."
  command -v rclone >/dev/null 2>&1 || die "O rclone não está instalado."
  [ -z "$(bk_remote_root "$n")" ] || die "Já existe um destino chamado $n."
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="${2:-}"; shift 2 || shift ;; --port) port="${2:-}"; shift 2 || shift ;;
      --user) user="${2:-}"; shift 2 || shift ;; --pass) pass="${2:-}"; shift 2 || shift ;;
      --key) key="${2:-}"; shift 2 || shift ;; --path) root="${2:-}"; shift 2 || shift ;;
      --provider) prov="${2:-}"; shift 2 || shift ;; --endpoint) ep="${2:-}"; shift 2 || shift ;;
      --region) reg="${2:-}"; shift 2 || shift ;; --access) ak="${2:-}"; shift 2 || shift ;;
      --secret) sk="${2:-}"; shift 2 || shift ;; --bucket) bucket="${2:-}"; shift 2 || shift ;;
      --config) raw="${2:-}"; shift 2 || shift ;;
      *) die "Opção desconhecida: $1" ;;
    esac
  done
  touch "$BK_RCLONE"; chmod 600 "$BK_RCLONE"
  case "$t" in
    sftp)
      [ -n "$host" ] && [ -n "$user" ] || die "Indica o servidor e o utilizador."
      [ -n "$pass" ] || [ -n "$key" ] || die "Indica a password ou a chave privada."
      local args=(host="$host" port="$port" user="$user" shell_type=unix)
      [ -n "$pass" ] && args+=(pass="$(rclone obscure "$pass")")
      if [ -n "$key" ]; then install -d -m 700 /etc/minipainel/rclone-keys; printf '%s\n' "$key" | sed 's/\\n/\n/g' > "/etc/minipainel/rclone-keys/$n.key"; chmod 600 "/etc/minipainel/rclone-keys/$n.key"; args+=(key_file="/etc/minipainel/rclone-keys/$n.key"); fi
      bk_rc config create "$n" sftp "${args[@]}" --non-interactive >/dev/null || die "O rclone recusou a configuração."
      root=${root:-backups} ;;
    s3)
      [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$bucket" ] || die "Indica a chave de acesso, a chave secreta e o bucket."
      local args=(provider="$prov" access_key_id="$ak" secret_access_key="$sk" no_check_bucket=true)
      [ -n "$ep" ] && args+=(endpoint="$ep"); [ -n "$reg" ] && args+=(region="$reg")
      bk_rc config create "$n" s3 "${args[@]}" --non-interactive >/dev/null || die "O rclone recusou a configuração."
      root="$bucket${root:+/$root}" ;;
    rclone)
      [ -n "$raw" ] || die "Cola a secção de configuração do rclone."
      raw=$(printf '%s' "$raw" | sed 's/\\n/\n/g')
      printf '%s\n' "$raw" | grep -q "^\[$n\]$" || die "A configuração tem de começar por [$n]."
      grep -q "^\[$n\]$" "$BK_RCLONE" && die "Já existe [$n] na configuração do rclone."
      printf '\n%s\n' "$raw" >> "$BK_RCLONE"
      root=${root:-iddigital-hosting} ;;
    *) die "Tipo inválido: usa sftp, s3 ou rclone." ;;
  esac
  jq --arg n "$n" --arg t "$t" --arg r "$root" '. + [{name:$n, type:$t, root:$r}]' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && chmod 600 "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  bk_write_state
  echo "Destino $n ($t) adicionado. Usa 'Testar' para confirmar o acesso."
  return 0
}
cmd_bk_remote_test(){
  local n="${1:-}" root f
  root=$(bk_remote_root "$n"); [ -n "$root" ] || die "O destino $n não existe."
  local errf; errf=$(mktemp)
  f="teste-$(bk_host)-$EPOCHSECONDS.txt"
  echo "IDDigital Hosting: teste de escrita" | bk_rc rcat "$n:$root/$f" 2>"$errf" || { head -c 400 "$errf" >&2; rm -f "$errf"; die "Não foi possível escrever em $n:$root."; }
  bk_rc deletefile "$n:$root/$f" >/dev/null 2>&1; rm -f "$errf"
  echo "Destino $n acessível: escrita e remoção em $root funcionaram."
  return 0
}
cmd_bk_remote_del(){
  local n="${1:-}"
  [ -n "$(bk_remote_root "$n")" ] || die "O destino $n não existe."
  bk_rc config delete "$n" >/dev/null 2>&1; rm -f "/etc/minipainel/rclone-keys/$n.key"
  jq --arg n "$n" 'map(select(.name != $n))' <<<"$(bk_remotes)" > "$BK_REMOTES.tmp" && mv -f "$BK_REMOTES.tmp" "$BK_REMOTES"
  [ "$(bk_conf REMOTE '')" = "$n" ] && sed -i 's/^REMOTE=.*/REMOTE=/' "$BK_CONF"
  bk_write_state
  echo "Destino $n removido (os backups já enviados para lá não foram apagados)."
  return 0
}
cmd_bk_init(){ install -d -o root -g "$PANEL_SYSUSER" -m 750 "$BK_DIR"; bk_cron_apply; bk_write_state; echo "Backups configurados."; return 0; }
cmd_bk_list(){
  local s="${1:-}"
  printf '%-12s %-16s %-13s %-10s %-8s %s\n' SITE ID TIPO TAMANHO REMOTO "BASES DE DADOS"
  find "$BK_DIR" -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null | while read -r m; do jq -r '[.site, .id, .type, (.size|tostring), (if .remote == "" then "-" else .remote end), (.dbs | join(","))] | @tsv' "$m"; done |
    sort -k2,2r | while IFS=$'\t' read -r a b c d e f; do [ -z "$s" ] || [ "$s" = "$a" ] || continue; printf '%-12s %-16s %-13s %-10s %-8s %s\n' "$a" "$b" "$c" "$(numfmt --to=iec "$d" 2>/dev/null || echo "$d")" "$e" "$f"; done
  return 0
}

write_auth(){
  local u=$1 hsh=$2
  jq -n --arg u "$u" --arg h "$hsh" '{user:$u,hash:$h}' > "$AUTH.tmp" || return 1
  chown root:"$PANEL_SYSUSER" "$AUTH.tmp"; chmod 640 "$AUTH.tmp"
  mv -f "$AUTH.tmp" "$AUTH"
}

cmd_passwd(){
  local p1 p2 rnd=0 h
  if [ "${1:-}" = "--random" ]; then
    rnd=1; p1=$(gen_pass 16)
  else
    [ -t 0 ] || die "Sem terminal interativo; usa 'mpanel passwd --random'."
    read -rsp "Nova password do painel: " p1; echo
    read -rsp "Repetir: " p2; echo
    [ "$p1" = "$p2" ] || die "As passwords não coincidem."
    [ ${#p1} -ge 10 ] || die "A password tem de ter pelo menos 10 caracteres."
  fi
  h=$(printf '%s' "$p1" | "$(php_cli "$PANEL_PHP")" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);')
  [[ "$h" == '$2y$'* ]] || die "Falha ao gerar o hash da password."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada (utilizador: $PANEL_USER)."
  if [ "$rnd" = 1 ]; then echo "Nova password: $p1"; fi
  return 0
}

cmd_panel_hash(){
  local h="${1:-}" re='^\$2y\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
  [[ "$h" =~ $re ]] || die "Hash inválido."
  write_auth "$PANEL_USER" "$h" || die "Falha ao gravar a password."
  echo "Password do painel alterada."
  return 0
}

write_state(){
  local n v st sites phps dbs
  sites=$(for n in $(site_names); do
      jq -cn --arg name "$n" --arg port "$(site_get "$n" PORT)" --arg php "$(site_get "$n" PHP)" \
        --arg en "$(site_get "$n" ENABLED)" --arg root "$WWW_ROOT/$n/public_html" \
        --arg mem "$(lim_get "$n" MEM)" --arg up "$(lim_get "$n" UPLOAD)" --arg ex "$(lim_get "$n" EXEC)" \
        --arg it "$(lim_get "$n" INPUT_TIME)" --arg iv "$(lim_get "$n" INPUT_VARS)" --arg de "$(lim_get "$n" DISPLAY_ERRORS)" \
        '{name:$name, port:($port|tonumber), php:$php, enabled:($en=="1"), root:$root,
          limits:{memory:($mem|tonumber), upload:($up|tonumber), exec:($ex|tonumber),
                  input_time:($it|tonumber), input_vars:($iv|tonumber), display_errors:($de=="1")}}'
    done | jq -cs '.')
  pkg_cache_load
  phps=$(for v in $(php_installed); do
      local exts mods en ed inst
      st=$(systemctl is-active "$(php_service "$v")" 2>/dev/null)
      exts=$(while IFS='|' read -r en _ _ ed; do
          inst=false; ext_installed_pkg "$en" "$v" >/dev/null && inst=true
          jq -cn --arg n "$en" --arg d "$ed" --argjson i "$inst" '{name:$n, desc:$d, installed:$i}'
        done < <(ext_catalog) | jq -cs '.')
      mods=$("$(php_cli "$v")" -m 2>/dev/null | grep -v -e '^\[' -e '^$' | sort -fu | jq -R . | jq -cs '.')
      jq -cn --arg v "$v" --arg s "$st" --argjson e "${exts:-[]}" --argjson m "${mods:-[]}" \
        '{version:$v, active:($s=="active"), extensions:$e, modules:$m}'
    done | jq -cs '.')
  local svcs host ip os up disk ram load cpus pmav dbadm=false
  pmav=$(pma_version)
  dbuser_exists "$DB_ADMIN" && dbadm=true
  svcs=$( {
      jq -cn --arg s "$(systemctl is-active nginx 2>/dev/null)" '{id:"nginx", name:"nginx", unit:"nginx", active:($s=="active")}'
      jq -cn --arg s "$(systemctl is-active mariadb 2>/dev/null)" '{id:"mariadb", name:"MariaDB", unit:"mariadb", active:($s=="active")}'
      for v in $(php_installed); do
        jq -cn --arg v "$v" --arg u "$(php_service "$v")" --arg s "$(systemctl is-active "$(php_service "$v")" 2>/dev/null)" --arg p "$PANEL_PHP" \
          '{id:("php-"+$v), name:("PHP-FPM "+$v), unit:$u, active:($s=="active"), panel:($v==$p), version:$v}'
      done
    } | jq -cs '.')
  host=$(hostname 2>/dev/null)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
  disk=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo 2>/dev/null)
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  cpus=$(nproc 2>/dev/null)
  dbs=$(db_sizes | while IFS=$'\t' read -r n v; do
      [ -n "$n" ] && jq -cn --arg n "$n" --arg s "$v" --arg site "$(dbmap_load | jq -r --arg d "$n" '.[$d] // ""')" '{name:$n, size_mb:($s|tonumber), site:$site}'
    done | jq -cs '.')
  jq -n --argjson sites "${sites:-[]}" --argjson php "${phps:-[]}" --argjson dbs "${dbs:-[]}" --argjson svcs "${svcs:-[]}" \
    --arg host "$host" --arg ip "$ip" --arg os "$os" --arg up "${up:-0}" --arg disk "${disk:-0}" --arg ram "${ram:-0}" \
    --arg load "${load:-0}" --arg cpus "${cpus:-1}" --arg pport "$PANEL_PORT" --arg pphp "$PANEL_PHP" \
    --arg pmav "$pmav" --argjson dbadm "$dbadm" --arg dbadmu "$DB_ADMIN" --argjson crons "$(cron_state_json)" \
    --arg defphp "$DEFAULT_PHP" --arg gen "$(date '+%Y-%m-%d %H:%M:%S')" --arg ver "$MP_VERSION" \
    --arg ng "$(systemctl is-active nginx 2>/dev/null)" --arg db "$(systemctl is-active mariadb 2>/dev/null)" \
    '{version:$ver, generated:$gen, default_php:$defphp, php:$php, sites:$sites, databases:$dbs,
      services:{nginx:($ng=="active"), mariadb:($db=="active")}, service_list:$svcs,
      pma:{installed:($pmav!=""), version:$pmav}, db_admin:{user:$dbadmu, exists:$dbadm}, crons:$crons,
      system:{hostname:$host, ip:$ip, os:$os, uptime:($up|tonumber), disk:($disk|tonumber), ram:($ram|tonumber),
              load:$load, cpus:($cpus|tonumber), panel_port:($pport|tonumber), panel_php:$pphp}}' > "$STATE.tmp" || { rm -f "$STATE.tmp"; return 1; }
  chown root:"$PANEL_SYSUSER" "$STATE.tmp"; chmod 640 "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
}

write_result(){
  local id=$1 rc=$2 msg=$3 okv=false
  [ "$rc" -eq 0 ] && okv=true
  jq -n --arg id "$id" --argjson ok "$okv" --arg msg "$msg" '{id:$id, ok:$ok, msg:$msg}' > "$RESULTS/.$id.tmp"
  chown root:"$PANEL_SYSUSER" "$RESULTS/.$id.tmp"; chmod 640 "$RESULTS/.$id.tmp"
  mv -f "$RESULTS/.$id.tmp" "$RESULTS/$id.json"
}

# Processa a fila do painel (chamado pelo minipainel-worker.service)
cmd_worker(){
  local f id action out rc re='^[a-f0-9]{16}$'
  local -a files args
  shopt -s nullglob
  find "$RESULTS" -type f -mmin +30 -delete 2>/dev/null
  find "$DATA/tmp" -type f -mmin +60 -delete 2>/dev/null
  while :; do
    files=("$QUEUE"/*.json)
    [ ${#files[@]} -eq 0 ] && break
    for f in "${files[@]}"; do
      id=$(jq -r '.id // empty' "$f" 2>/dev/null)
      action=$(jq -r '.action // empty' "$f" 2>/dev/null)
      mapfile -t args < <(jq -r '(.args // []) | .[] | tostring' "$f" 2>/dev/null)
      rm -f "$f"
      [[ "$id" =~ $re ]] || continue
      case "$action" in
        site-add|site-del|site-php|site-enable|site-disable|site-fixperms|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|db-link|pma-update|panel-passwd-hash|service|block|unblock|allow-add|allow-del|fw-auto|cron-add|cron-edit|cron-del|cron-on|cron-off|cron-run|backup-start|bk-restore|bk-delete|bk-conf|bk-remote-add|bk-remote-test|bk-remote-del|refresh)
          out=$(dispatch "$action" "${args[@]}" 2>&1); rc=$? ;;
        *)
          out="Ação não permitida."; rc=1 ;;
      esac
      if ! write_state 2>/dev/null; then
        out="${out:+$out
}AVISO: não foi possível gerar o estado do painel (corre 'mpanel state' no servidor para ver o erro)."
        [ "$rc" -eq 0 ] && [ "$action" = refresh ] && rc=1
      fi
      write_result "$id" "$rc" "$out"
    done
  done
  return 0
}

usage(){
  cat <<'EOF'
IDDigital Hosting — CLI v1.8.0 (mpanel)
Uso: mpanel <comando> [argumentos]

Sites
  site-list
  site-add <nome> [--port N] [--php X.Y] [opções de limites, ver site-limits]
  site-del <nome> [--keep-files]
  site-php <nome> <X.Y>
  site-enable <nome>
  site-disable <nome>
  site-fixperms <nome>
  site-limits <nome>                       mostra os limites
  site-limits <nome> [--memory MB] [--upload MB] [--exec S]
                     [--input-time S] [--input-vars N] [--display-errors 0|1]

Extensões PHP (por versão; afetam todos os sites dessa versão)
  ext-list [X.Y]
  ext-add <X.Y> <extensão>
  ext-del <X.Y> <extensão>

Bases de dados (utilizador com o mesmo nome, acesso por localhost)
  db-list
  db-add <nome> [password]
  db-del <nome>
  db-passwd <nome> [password]
  db-admin-passwd [password]   cria ou muda a conta de administração (mpadmin)

phpMyAdmin (https://IP:PORTA-DO-PAINEL/phpmyadmin/, requer sessão no painel)
  pma-update [--force]         instala ou atualiza para a versão oficial mais recente

Serviços
  service <nginx|mariadb|php-X.Y> <reload|restart|start|stop>
  stats                 utilização atual do servidor e de cada site

Backups (local em /var/backups/minipainel + destinos remotos via rclone)
  backup-run [--site <site>|_bd|_sistema] [--remote <destino>]   faz backup agora
  bk-list [site]
  bk-restore <site>|_bd <id> [--what all|files|db]   repõe (faz antes um backup do estado atual)
  bk-delete <site> <id>
  bk-conf [--on|--off] [--time 03:00] [--daily 7] [--weekly 4] [--monthly 3] [--remote <destino>|none]
  bk-remote-add <nome> sftp --host H --user U --pass P [--port 22] [--path pasta]
  bk-remote-add <nome> s3 --access A --secret S --bucket B [--endpoint E] [--region R] [--provider Other]
  bk-remote-add <nome> rclone --config "[nome]\ntype = drive\n..."
  bk-remote-test <nome> | bk-remote-del <nome>
  db-link <base-de-dados> <site>|none   associa uma base de dados a um site (entra nos backups dele)

Tarefas agendadas (cron; correm como o utilizador do site)
  cron-list [site]
  cron-add <site> --when "*/5 * * * *" --cmd "php /srv/www/<site>/public_html/cron.php" [--label texto] [--off]
  cron-edit <site> <id> [--when ...] [--cmd ...] [--label ...]
  cron-on|cron-off|cron-run|cron-del <site> <id>
  cron-sync                            regenera os ficheiros de /etc/cron.d

Ligações e firewall (bloqueio em todas as portas, incluindo SSH)
  conn-list [ip]                       ligações abertas por IP
  block <ip|rede> [--for 1h|24h|7d|perm] [--reason texto]
  unblock <ip|rede>
  block-list
  allow-add <ip|rede> | allow-del <ip|rede>   IPs de confiança (nunca bloqueados)
  fw-auto on|off [--limit N] [--duration 1h]  bloqueio automático por excesso de ligações
  fw-restore                           repõe a tabela nftables e os bloqueios

Gestor de ficheiros
  fm-sync               recria os processos do gestor de ficheiros de todos os sites

Sistema
  php-list
  status
  passwd [--random]     muda a password do painel
  state                 regenera o estado lido pelo painel
EOF
}

dispatch(){
  local c="$1"; shift
  case "$c" in
    site-list)         cmd_site_list ;;
    site-add)          cmd_site_add "$@" ;;
    site-del)          cmd_site_del "$@" ;;
    site-php)          cmd_site_php "$@" ;;
    site-enable)       cmd_site_toggle "${1:-}" 1 ;;
    site-disable)      cmd_site_toggle "${1:-}" 0 ;;
    site-fixperms)     cmd_site_fixperms "$@" ;;
    site-limits)       cmd_site_limits "$@" ;;
    ext-list)          cmd_ext_list "$@" ;;
    ext-add)           cmd_ext_add "$@" ;;
    ext-del)           cmd_ext_del "$@" ;;
    db-list)           cmd_db_list ;;
    db-add)            cmd_db_add "$@" ;;
    db-del)            cmd_db_del "$@" ;;
    db-passwd)         cmd_db_passwd "$@" ;;
    db-admin-passwd)   cmd_db_admin_passwd "$@" ;;
    pma-update)        cmd_pma_update "$@" ;;
    php-list)          cmd_php_list ;;
    service)           cmd_service "$@" ;;
    stats)             cmd_stats ;;
    conn-list)         cmd_conn_list "$@" ;;
    block)             cmd_block "$@" ;;
    unblock)           cmd_unblock "$@" ;;
    block-list)        cmd_block_list ;;
    allow-add)         cmd_allow_add "$@" ;;
    allow-del)         cmd_allow_del "$@" ;;
    fw-auto)           cmd_fw_auto "$@" ;;
    fw-restore)        cmd_fw_restore ;;
    cron-list)         cmd_cron_list "$@" ;;
    cron-add)          cmd_cron_add "$@" ;;
    cron-edit)         cmd_cron_edit "$@" ;;
    cron-del)          cmd_cron_del "$@" ;;
    cron-on)           cmd_cron_toggle "${1:-}" "${2:-}" true ;;
    cron-off)          cmd_cron_toggle "${1:-}" "${2:-}" false ;;
    cron-run)          cmd_cron_run "$@" ;;
    cron-sync)         cmd_cron_sync ;;
    db-link)           cmd_db_link "$@" ;;
    backup-start)      cmd_backup_start "$@" ;;
    bk-list)           cmd_bk_list "$@" ;;
    bk-restore)        cmd_bk_restore "$@" ;;
    bk-delete)         cmd_bk_delete "$@" ;;
    bk-conf)           cmd_bk_conf "$@" ;;
    bk-init)           cmd_bk_init ;;
    bk-remote-add)     cmd_bk_remote_add "$@" ;;
    bk-remote-test)    cmd_bk_remote_test "$@" ;;
    bk-remote-del)     cmd_bk_remote_del "$@" ;;
    fm-sync)           cmd_fm_sync ;;
    status)            cmd_status ;;
    passwd)            cmd_passwd "$@" ;;
    panel-passwd-hash) cmd_panel_hash "$@" ;;
    state|refresh)     return 0 ;;
    *)                 die "Comando desconhecido: $c (usa 'mpanel help')." ;;
  esac
}

# ---------- main ----------
cmd="${1:-help}"
case "$cmd" in
  help|-h|--help)       usage; exit 0 ;;
  version|-v|--version) echo "IDDigital Hosting $MP_VERSION (MiniPainel)"; exit 0 ;;
esac
[ "$(id -u)" -eq 0 ] || die "Tem de ser executado como root."
# o backup usa o seu próprio bloqueio, para não impedir as outras operações do painel
if [ "$cmd" = backup-run ]; then shift; cmd_backup_run "$@"; exit $?; fi
exec 9>"$LOCK"
flock -w 300 9 || die "Outra operação do painel está em curso."

if [ "$cmd" = worker ]; then cmd_worker; exit 0; fi

dispatch "$@"; rc=$?
if [ "$rc" -eq 0 ]; then
  case "$cmd" in
    site-add|site-del|site-php|site-enable|site-disable|site-limits|ext-add|ext-del|db-add|db-del|db-passwd|db-admin-passwd|pma-update|service|cron-add|cron-edit|cron-del|cron-on|cron-off|state|refresh)
      write_state || { echo "ERRO: não foi possível gerar o estado do painel ($STATE)." >&2; rc=1; } ;;
  esac
fi
exit "$rc"
MPCLI
chmod 750 /usr/local/sbin/mpanel

# ----------------------------------------------------------------------------
# 8. Worker (fila do painel) e logrotate
# ----------------------------------------------------------------------------
say "A configurar o worker..."
cat > /etc/systemd/system/minipainel-worker.service <<'EOF'
[Unit]
Description=IDDigital Hosting - processa as tarefas do painel
After=network.target mariadb.service nginx.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mpanel worker
TimeoutStartSec=1800
EOF
cat > /etc/systemd/system/minipainel-worker.path <<'EOF'
[Unit]
Description=IDDigital Hosting - vigia a fila de tarefas do painel

[Path]
DirectoryNotEmpty=/var/lib/minipainel/queue
Unit=minipainel-worker.service

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-worker.path >/dev/null 2>&1
systemctl restart minipainel-worker.path

say "A instalar o recolhedor de estatísticas..."
install -d -o root -g minipainel -m 750 /var/lib/minipainel/stats /var/lib/minipainel/stats/traffic
cat > /usr/local/sbin/mpanel-stats <<'MPSTATS'
#!/usr/bin/env bash
# =============================================================================
#  mpanel-stats — recolhedor de estatísticas do IDDigital Hosting v1.8.0
#  Lê o /proc a cada 5 s e grava:
#    live.json        valores atuais (servidor e por site)
#    hist-1m.csv      médias por minuto   (24 h)
#    hist-10m.csv     médias por 10 min   (7 dias)
#    hist-1h.csv      médias por hora     (30 dias)
#    sites.json       disco (de hora a hora) e tráfego das últimas 24 h por site
#    traffic/<site>.csv  pedidos e bytes por hora (30 dias), lidos dos logs do nginx
#  Colunas do histórico: ts,cpu,mem,swap,disk (em décimas de %),load (x100),rx,tx (bit/s)
# =============================================================================
set -uo pipefail
# shellcheck source=/dev/null
. /etc/minipainel/minipainel.conf 2>/dev/null

DIR=/var/lib/minipainel/stats
TDIR=$DIR/traffic
SITES_DIR=/etc/minipainel/sites
WWW_ROOT=/srv/www
GRP=${PANEL_SYSUSER:-minipainel}
INTERVAL=5
TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
NCPU=$(nproc 2>/dev/null || echo 1)

install -d -o root -g "$GRP" -m 750 "$DIR" "$TDIR"

perm(){ chown root:"$GRP" "$1" 2>/dev/null; chmod 640 "$1" 2>/dev/null; return 0; }
put(){ local tmp="$1.tmp"; printf '%s\n' "$2" > "$tmp" && perm "$tmp" && mv -f "$tmp" "$1"; }
d10(){ printf '%d.%d' $(( $1 / 10 )) $(( $1 % 10 )); }
trim(){ local f=$1 max=$2 n; n=$(wc -l < "$f" 2>/dev/null || echo 0); if [ "$n" -gt $(( max + 30 )) ]; then tail -n "$max" "$f" > "$f.tmp" && perm "$f.tmp" && mv -f "$f.tmp" "$f"; fi; }
site_names(){ local f; for f in "$SITES_DIR"/*.conf; do [ -f "$f" ] && basename "$f" .conf; done; return 0; }

read_cpu(){
  local l; read -r l < /proc/stat
  # shellcheck disable=SC2086
  set -- $l; shift
  local idle=$(( $4 + ${5:-0} )) tot=0 x
  for x in "$@"; do tot=$(( tot + x )); done
  tot=$(( tot - ${9:-0} - ${10:-0} ))
  echo "$tot $idle"
}
read_mem(){ awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2}END{printf "%d %d %d %d\n", t, t-a, st, st-sf}' /proc/meminfo; }
read_disk(){ df -Pk / 2>/dev/null | awk 'NR==2{print $2, $3, $4}'; }
read_net(){ awk 'NR>2{sub(/:/," "); if ($1 != "lo") { rx += $2; tx += $10 }} END{printf "%.0f %.0f\n", rx, tx}' /proc/net/dev; }

# ---------- CPU e memória por site (processos dos utilizadores mp_<site>) ----------
declare -A PREV_TICKS=() SITE_CPU=() SITE_RSS=()
sample_sites(){
  local dtus=$1 first=$2 pid user rss site t
  local -A cur=() owner=()
  local -a files=()
  SITE_CPU=(); SITE_RSS=()
  while read -r pid user rss; do
    [[ "$user" == mp_* ]] || continue
    site=${user#mp_}
    SITE_RSS[$site]=$(( ${SITE_RSS[$site]:-0} + rss ))
    owner[$pid]=$site
    files+=("/proc/$pid/stat")
  done < <(ps -eo pid=,user:40=,rss= 2>/dev/null)
  if [ ${#files[@]} -gt 0 ]; then
    while read -r pid t; do
      [ -n "${owner[$pid]:-}" ] || continue
      cur[$pid]=$t
      site=${owner[$pid]}
      if [ "$first" = 0 ]; then
        if [ -n "${PREV_TICKS[$pid]:-}" ]; then t=$(( t - ${PREV_TICKS[$pid]} )); fi
        [ "$t" -lt 0 ] && t=0
        SITE_CPU[$site]=$(( ${SITE_CPU[$site]:-0} + t ))
      fi
    done < <(awk '{ n = split(FILENAME, a, "/"); p = a[3]; sub(/^.*\) /, ""); print p, $12 + $13 }' "${files[@]}" 2>/dev/null)
  fi
  PREV_TICKS=()
  for pid in "${!cur[@]}"; do PREV_TICKS[$pid]=${cur[$pid]}; done
  # ticks -> décimas de % da capacidade total do servidor
  local v
  for site in "${!SITE_CPU[@]}"; do
    v=${SITE_CPU[$site]}
    v=$(( v * 1000 * 1000000 / (TCK * dtus * NCPU) ))
    [ "$v" -gt 1000 ] && v=1000
    SITE_CPU[$site]=$v
  done
}

# ---------- tráfego por site (leitura incremental dos logs do nginx) ----------
update_traffic(){
  local n log pos ino size oino off req bytes hour now
  now=$EPOCHSECONDS; hour=$(( now / 3600 * 3600 ))
  for n in $(site_names); do
    log=/var/log/nginx/mp-$n.access.log
    pos=$TDIR/$n.pos
    [ -f "$log" ] || continue
    ino=$(stat -c %i "$log" 2>/dev/null) || continue
    size=$(stat -c %s "$log" 2>/dev/null) || continue
    if [ ! -f "$pos" ]; then echo "$ino $size" > "$pos"; continue; fi
    read -r oino off < "$pos"
    if [ "$oino" != "$ino" ] || [ "$size" -lt "${off:-0}" ]; then off=0; fi
    if [ "$size" -gt "$off" ]; then
      read -r req bytes < <(tail -c +$(( off + 1 )) "$log" 2>/dev/null | head -c $(( size - off )) |
        awk '{ n++; if (match($0, /" [0-9][0-9][0-9] [0-9]+ /)) { split(substr($0, RSTART + 2, RLENGTH - 3), f, " "); b += f[2] } } END { printf "%d %.0f\n", n, b }')
      if [ "${req:-0}" -gt 0 ]; then
        [ -f "$TDIR/$n.csv" ] || { : > "$TDIR/$n.csv"; perm "$TDIR/$n.csv"; }
        awk -F, -v h="$hour" -v r="$req" -v b="$bytes" 'BEGIN{OFS=","}
          { rows[NR] = $0; last = $1 }
          END {
            if (NR > 0 && last == h) { split(rows[NR], x, ","); rows[NR] = h "," (x[2] + r) "," sprintf("%.0f", x[3] + b); m = NR }
            else { m = NR + 1; rows[m] = h "," r "," b }
            s = (m > 720) ? m - 719 : 1
            for (i = s; i <= m; i++) print rows[i]
          }' "$TDIR/$n.csv" > "$TDIR/$n.csv.tmp" && perm "$TDIR/$n.csv.tmp" && mv -f "$TDIR/$n.csv.tmp" "$TDIR/$n.csv"
      fi
    fi
    echo "$ino $size" > "$pos"
  done
}

# ---------- disco por site (de hora a hora) ----------
declare -A SITE_DISK=()
update_disk(){
  local n b
  SITE_DISK=()
  for n in $(site_names); do
    b=$(nice -n 19 timeout 300 du -sb "$WWW_ROOT/$n" 2>/dev/null | awk '{print $1}')
    SITE_DISK[$n]=${b:-0}
  done
}

write_sites_json(){
  local n r b since o="" sep=""
  since=$(( EPOCHSECONDS - 86400 ))
  for n in $(site_names); do
    r=0; b=0
    if [ -f "$TDIR/$n.csv" ]; then
      read -r r b < <(awk -F, -v s="$since" '$1 >= s - 3599 { r += $2; b += $3 } END { printf "%d %.0f\n", r, b }' "$TDIR/$n.csv")
    fi
    o+="$sep\"$n\":{\"disk\":${SITE_DISK[$n]:-0},\"req24\":${r:-0},\"bytes24\":${b:-0}}"
    sep=","
  done
  put "$DIR/sites.json" "{\"ts\":$EPOCHSECONDS,\"disk_ts\":$DISK_TS,\"sites\":{$o}}"
}

aggregate(){ # origem destino início fim máximo
  tail -n 200 "$1" 2>/dev/null | awk -F, -v s="$3" -v e="$4" '
    $1 >= s && $1 < e { n++; for (i = 2; i <= 8; i++) a[i] += $i }
    END { if (n) { printf "%d", s; for (i = 2; i <= 8; i++) printf ",%.0f", a[i] / n; print "" } }' >> "$2"
  perm "$2"; trim "$2" "$5"
}

# ---------- ligações abertas (só às portas em escuta neste servidor) ----------
declare -A FW_RECENT=()
FW_AUTO=0; FW_LIMIT=150; FW_DUR=3600
read_fw_conf(){
  local f=/etc/minipainel/firewall.conf
  FW_AUTO=$(grep -m1 '^AUTO=' "$f" 2>/dev/null | cut -d= -f2); FW_AUTO=${FW_AUTO:-0}
  FW_LIMIT=$(grep -m1 '^LIMIT=' "$f" 2>/dev/null | cut -d= -f2); FW_LIMIT=${FW_LIMIT:-150}
  FW_DUR=$(grep -m1 '^DURATION=' "$f" 2>/dev/null | cut -d= -f2); FW_DUR=${FW_DUR:-3600}
}
sample_conns(){
  local lp raw tot syn dist ips c ip k
  lp=$(ss -Htln 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | sort -u | tr '\n' ' ')
  raw=$(ss -Htna 2>/dev/null | awk -v lp=" $lp " '
    BEGIN { n = split(lp, L, " "); for (i = 1; i <= n; i++) if (L[i] != "") lport[L[i]] = 1 }
    $1 == "ESTAB" || $1 == "SYN-RECV" {
      k = split($4, a, ":"); p = a[k]
      if (!(p in lport)) next
      ip = $5; sub(/:[0-9]+$/, "", ip); gsub(/[\[\]]/, "", ip); sub(/^::ffff:/, "", ip); sub(/%.*/, "", ip)
      if (ip == "127.0.0.1" || ip == "::1") next
      cnt[ip]++; if ($1 == "SYN-RECV") syn[ip]++
      pc[ip, p]++
    }
    END {
      for (key in pc) { split(key, q, SUBSEP); ports[q[1]] = ports[q[1]] (ports[q[1]] == "" ? "" : ",") q[2] ":" pc[key] }
      for (ip in cnt) printf "%d\t%s\t%d\t%s\n", cnt[ip], ip, syn[ip] + 0, ports[ip]
    }')
  read -r tot syn dist < <(printf '%s\n' "$raw" | awk -F'\t' 'NF >= 2 { t += $1; s += $3; n++ } END { print t + 0, s + 0, n + 0 }')
  ips=$(printf '%s\n' "$raw" | grep -v '^$' | sort -t$'\t' -k1,1nr | head -n 500 | awk -F'\t' '
    BEGIN { printf "[" }
    { m = split($4, P, ","); ps = ""; for (i = 1; i <= m; i++) { split(P[i], kv, ":"); ps = ps (i > 1 ? "," : "") "\"" kv[1] "\":" kv[2] }
      printf "%s{\"ip\":\"%s\",\"n\":%d,\"syn\":%d,\"ports\":{%s}}", (NR > 1 ? "," : ""), $2, $1, $3, ps }
    END { printf "]" }')
  put "$DIR/conns.json" "{\"ts\":$EPOCHSECONDS,\"total\":${tot:-0},\"syn\":${syn:-0},\"distinct\":${dist:-0},\"ips\":${ips:-[]}}"
  # bloqueio automático
  if [ "$FW_AUTO" = 1 ] && [ -x /usr/local/sbin/mpanel ]; then
    for k in "${!FW_RECENT[@]}"; do [ "${FW_RECENT[$k]}" -lt "$EPOCHSECONDS" ] && unset "FW_RECENT[$k]"; done
    while IFS=$'\t' read -r c ip _ _; do
      [ -n "$ip" ] || continue
      [ "$c" -gt "$FW_LIMIT" ] || break
      [ -n "${FW_RECENT[$ip]:-}" ] && continue
      FW_RECENT[$ip]=$(( EPOCHSECONDS + 300 ))
      ( timeout 90 /usr/local/sbin/mpanel block "$ip" --for "${FW_DUR}s" --by auto --reason "Automático: $c ligações abertas" >/dev/null 2>&1 & )
    done < <(printf '%s\n' "$raw" | grep -v '^$' | sort -t$'\t' -k1,1nr)
  fi
}
fw_selfheal(){
  command -v nft >/dev/null 2>&1 || return 0
  [ -s /etc/minipainel/blocks.list ] || [ -f /etc/minipainel/firewall.conf ] || return 0
  nft list table inet minipainel >/dev/null 2>&1 || ( timeout 90 /usr/local/sbin/mpanel fw-restore >/dev/null 2>&1 & )
}

# ---------- último resultado das tarefas agendadas ----------
update_crons(){
  local n f id a b c t o="" sep="" re_n='^[0-9]+$' re_c='^(running|[0-9]+)$'
  for n in $(site_names); do
    for f in "$WWW_ROOT/$n"/logs/cron-*.status; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      id=${f##*/cron-}; id=${id%.status}
      [[ "$id" =~ ^[a-f0-9]{8}$ ]] || continue
      read -r a b c < "$f"
      [[ "$a" =~ $re_n ]] && [[ "$b" =~ $re_n ]] && [[ "$c" =~ $re_c ]] || continue
      t='""'
      if [ -f "$WWW_ROOT/$n/logs/cron-$id.log" ] && [ ! -L "$WWW_ROOT/$n/logs/cron-$id.log" ]; then
        t=$(tail -n 20 "$WWW_ROOT/$n/logs/cron-$id.log" 2>/dev/null | cut -c1-500 | jq -Rs .)
      fi
      o+="$sep\"$n:$id\":{\"start\":$a,\"end\":$b,\"rc\":\"$c\",\"tail\":$t}"; sep=","
    done
  done
  put "$DIR/crons.json" "{\"ts\":$EPOCHSECONDS,\"runs\":{$o}}"
}

# ---------- ciclo principal ----------
for f in hist-1m.csv hist-10m.csv hist-1h.csv; do [ -f "$DIR/$f" ] || : > "$DIR/$f"; perm "$DIR/$f"; done
read -r p_tot p_idle <<<"$(read_cpu)"
read -r p_rx p_tx <<<"$(read_net)"
p_t=${EPOCHREALTIME/./}
first=1
cur_min=$(( EPOCHSECONDS / 60 ))
acc_n=0; a_cpu=0; a_mem=0; a_swap=0; a_disk=0; a_load=0; a_rx=0; a_tx=0
DISK_TS=0; last_hour=-1
sample_sites 1 1
first=0
read_fw_conf

while :; do
  sleep "$INTERVAL"
  now_t=${EPOCHREALTIME/./}
  dtus=$(( now_t - p_t )); [ "$dtus" -le 0 ] && dtus=1
  read -r tot idle <<<"$(read_cpu)"
  dtot=$(( tot - p_tot )); didle=$(( idle - p_idle ))
  cpu=0; [ "$dtot" -gt 0 ] && cpu=$(( (dtot - didle) * 1000 / dtot ))
  [ "$cpu" -lt 0 ] && cpu=0
  read -r mt mu st su <<<"$(read_mem)"
  mem=0; [ "${mt:-0}" -gt 0 ] && mem=$(( mu * 1000 / mt ))
  swap=0; [ "${st:-0}" -gt 0 ] && swap=$(( su * 1000 / st ))
  read -r dk_t dk_u dk_a <<<"$(read_disk)"
  disk=0; [ $(( ${dk_u:-0} + ${dk_a:-0} )) -gt 0 ] && disk=$(( dk_u * 1000 / (dk_u + dk_a) ))
  read -r l1 l5 l15 _ < /proc/loadavg
  load=$(( 10#${l1/./} ))
  read -r rx tx <<<"$(read_net)"
  rxb=$(( (rx - p_rx) * 8 * 1000000 / dtus )); [ "$rxb" -lt 0 ] && rxb=0
  txb=$(( (tx - p_tx) * 8 * 1000000 / dtus )); [ "$txb" -lt 0 ] && txb=0
  sample_sites "$dtus" "$first"

  sj=""; sep=""
  for s in $(site_names); do
    sj+="$sep\"$s\":{\"cpu\":$(d10 "${SITE_CPU[$s]:-0}"),\"rss\":${SITE_RSS[$s]:-0}}"; sep=","
  done
  printf -v tz '%(%z)T' -1
  put "$DIR/live.json" "{\"ts\":$EPOCHSECONDS,\"tz\":\"$tz\",\"cpus\":$NCPU,\"cpu\":$(d10 "$cpu"),\"mem\":{\"pct\":$(d10 "$mem"),\"used\":$mu,\"total\":$mt},\"swap\":{\"pct\":$(d10 "$swap"),\"used\":$su,\"total\":$st},\"disk\":{\"pct\":$(d10 "$disk"),\"used\":${dk_u:-0},\"total\":${dk_t:-0}},\"load\":[$l1,$l5,$l15],\"net\":{\"rx\":$rxb,\"tx\":$txb},\"sites\":{$sj}}"

  sample_conns
  acc_n=$(( acc_n + 1 )); a_cpu=$(( a_cpu + cpu )); a_mem=$(( a_mem + mem )); a_swap=$(( a_swap + swap ))
  a_disk=$(( a_disk + disk )); a_load=$(( a_load + load )); a_rx=$(( a_rx + rxb )); a_tx=$(( a_tx + txb ))

  m=$(( EPOCHSECONDS / 60 ))
  if [ "$m" -ne "$cur_min" ]; then
    ts=$(( cur_min * 60 ))
    echo "$ts,$(( a_cpu / acc_n )),$(( a_mem / acc_n )),$(( a_swap / acc_n )),$(( a_disk / acc_n )),$(( a_load / acc_n )),$(( a_rx / acc_n )),$(( a_tx / acc_n ))" >> "$DIR/hist-1m.csv"
    trim "$DIR/hist-1m.csv" 1440
    if [ $(( m / 10 )) -ne $(( cur_min / 10 )) ]; then
      s10=$(( cur_min / 10 * 600 )); aggregate "$DIR/hist-1m.csv" "$DIR/hist-10m.csv" "$s10" $(( s10 + 600 )) 1008
    fi
    if [ $(( m / 60 )) -ne $(( cur_min / 60 )) ]; then
      s60=$(( cur_min / 60 * 3600 )); aggregate "$DIR/hist-1m.csv" "$DIR/hist-1h.csv" "$s60" $(( s60 + 3600 )) 720
    fi
    update_traffic
    read_fw_conf
    fw_selfheal
    update_crons
    h=$(( EPOCHSECONDS / 3600 ))
    if [ "$h" -ne "$last_hour" ]; then update_disk; DISK_TS=$EPOCHSECONDS; last_hour=$h; fi
    write_sites_json
    acc_n=0; a_cpu=0; a_mem=0; a_swap=0; a_disk=0; a_load=0; a_rx=0; a_tx=0
    cur_min=$m
  fi
  p_tot=$tot; p_idle=$idle; p_rx=$rx; p_tx=$tx; p_t=$now_t; first=0
done
MPSTATS
chmod 750 /usr/local/sbin/mpanel-stats
cat > /etc/systemd/system/minipainel-stats.service <<'EOF'
[Unit]
Description=IDDigital Hosting - recolha de estatísticas e ligações
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mpanel-stats
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-stats.service >/dev/null 2>&1
systemctl restart minipainel-stats.service

say "A configurar as tarefas agendadas (cron)..."
if [ "$OS_FAMILY" = debian ]; then CRON_SVC=cron; else CRON_SVC=crond; fi
systemctl enable --now "$CRON_SVC" >/dev/null 2>&1 || warn "Não foi possível ativar o serviço $CRON_SVC."
install -d -m 755 /etc/minipainel/cron
cat > /usr/local/sbin/mpanel-cron <<'MPCRON'
#!/usr/bin/env bash
# =============================================================================
#  mpanel-cron — IDDigital Hosting v1.8.0
#  Executa uma tarefa agendada de um site. Corre como o utilizador do site
#  (mp_<site>), chamado pelo cron a partir de /etc/cron.d/minipainel-<site>.
#  Não deixa sobrepor execuções e regista a saída em logs/cron-<id>.log.
# =============================================================================
set -uo pipefail
site="${1:-}"; id="${2:-}"
re_s='^[a-z][a-z0-9-]{0,23}$'; re_i='^[a-f0-9]{8}$'
[[ "$site" =~ $re_s ]] && [[ "$id" =~ $re_i ]] || { echo "Parâmetros inválidos." >&2; exit 2; }
[ "$(id -un)" = "mp_$site" ] || { echo "Tem de correr como mp_$site." >&2; exit 2; }
d=/srv/www/$site
s=/etc/minipainel/cron/$site/$id.sh
log=$d/logs/cron-$id.log
st=$d/logs/cron-$id.status
[ -r "$s" ] || { echo "Tarefa não encontrada: $id" >&2; exit 2; }
umask 027
exec 9>"$d/tmp/.cron-$id.lock"
if ! flock -n 9; then
  printf '=== %s — ignorada: a execução anterior ainda não terminou ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
  exit 0
fi
start=$(date +%s)
printf '%s 0 running\n' "$start" > "$st"
printf '=== %s ===\n' "$(date '+%d/%m/%Y %H:%M:%S')" >> "$log"
export PATH="/etc/minipainel/cron/$site/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d"
cd "$d/public_html" 2>/dev/null || cd "$d" || exit 1
/bin/sh "$s" >> "$log" 2>&1 9>&-
rc=$?
end=$(date +%s)
printf '%s %s %s\n' "$start" "$end" "$rc" > "$st"
printf '=== terminou com código %s em %ss ===\n' "$rc" "$(( end - start ))" >> "$log"
if [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
fi
exit "$rc"
MPCRON
chown root:root /usr/local/sbin/mpanel-cron
chmod 755 /usr/local/sbin/mpanel-cron

say "A configurar os backups..."
install -d -o root -g minipainel -m 750 /var/backups/minipainel
if [ ! -f /etc/minipainel/backup.conf ]; then
  printf 'ENABLED=1\nTIME=03:00\nKEEP_DAILY=7\nKEEP_WEEKLY=4\nKEEP_MONTHLY=3\nREMOTE=\n' > /etc/minipainel/backup.conf
  chmod 600 /etc/minipainel/backup.conf
fi

say "A configurar a firewall de ligações (nftables)..."
[ -f /etc/minipainel/firewall.conf ] || printf 'AUTO=0\nLIMIT=150\nDURATION=3600\n' > /etc/minipainel/firewall.conf
touch /etc/minipainel/blocks.list /etc/minipainel/allow.list
chmod 600 /etc/minipainel/blocks.list /etc/minipainel/allow.list
cat > /etc/systemd/system/minipainel-firewall.service <<'EOF'
[Unit]
Description=IDDigital Hosting - bloqueios de IPs (nftables)
After=network-pre.target nftables.service firewalld.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mpanel fw-restore

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable minipainel-firewall.service >/dev/null 2>&1 || true

cat > /etc/logrotate.d/minipainel <<'EOF'
/srv/www/*/logs/*.log /var/lib/minipainel/logs/*.log /var/lib/minipainel-pma/logs/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
EOF

# ----------------------------------------------------------------------------
# 9. Password do painel (apenas na primeira instalação)
# ----------------------------------------------------------------------------
ADMIN_PASS=""
if [ ! -s /var/lib/minipainel/auth.json ]; then
  ADMIN_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  HASH="$(printf '%s' "$ADMIN_PASS" | "$(php_cli "$PANEL_PHP")" -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);')"
  [[ "$HASH" == '$2y$'* ]] || die "Falha ao gerar a password do painel."
  jq -n --arg u "$PANEL_USER" --arg h "$HASH" '{user:$u,hash:$h}' > /var/lib/minipainel/auth.json
  chown root:minipainel /var/lib/minipainel/auth.json
  chmod 640 /var/lib/minipainel/auth.json
fi

# ----------------------------------------------------------------------------
# 10. SELinux e firewall
# ----------------------------------------------------------------------------
if selinux_on; then
  say "A configurar SELinux..."
  setsebool -P httpd_can_network_connect=1 httpd_can_network_connect_db=1 || warn "Não foi possível ajustar os booleanos SELinux."
  se_fc(){ semanage fcontext -a -t "$1" "$2" 2>/dev/null || semanage fcontext -m -t "$1" "$2" 2>/dev/null || true; }
  se_fc httpd_sys_rw_content_t "/srv/www(/.*)?"
  se_fc httpd_sys_content_t    "/opt/minipainel(/.*)?"
  se_fc httpd_sys_rw_content_t "/var/lib/minipainel(/.*)?"
  se_fc cert_t                 "/etc/minipainel/ssl(/.*)?"
  se_fc httpd_sys_rw_content_t "/var/lib/minipainel-pma(/.*)?"
  se_fc httpd_sys_content_t    "/var/backups/minipainel(/.*)?"
  install -d -o root -g minipainel -m 750 /var/backups/minipainel
  restorecon -R /srv/www /opt/minipainel /var/lib/minipainel /var/lib/minipainel-pma /etc/minipainel/ssl || true
  semanage port -a -t http_port_t -p tcp "$PANEL_PORT" 2>/dev/null \
    || semanage port -m -t http_port_t -p tcp "$PANEL_PORT" 2>/dev/null || true
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd -q --permanent --add-port="$PANEL_PORT/tcp" || true
  firewall-cmd -q --add-port="$PANEL_PORT/tcp" || true
  ok "Porta $PANEL_PORT aberta no firewalld."
elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
  ufw allow "$PANEL_PORT/tcp" >/dev/null || true
  ok "Porta $PANEL_PORT aberta no ufw."
fi

# ----------------------------------------------------------------------------
# 10b. phpMyAdmin e conta de administração do MariaDB
# ----------------------------------------------------------------------------
say "A instalar o phpMyAdmin..."
if /usr/local/sbin/mpanel pma-update; then ok "phpMyAdmin pronto."
else warn "phpMyAdmin não instalado agora. Tenta mais tarde com: mpanel pma-update"; fi

DBADMIN_PASS=""
if [ "$(mysql -uroot -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='mpadmin'" 2>/dev/null)" = 0 ]; then
  DBADMIN_OUT="$(/usr/local/sbin/mpanel db-admin-passwd 2>/dev/null || true)"
  DBADMIN_PASS="$(printf '%s\n' "$DBADMIN_OUT" | awk -F': *' '/^Password:/{print $2; exit}')"
  if [ -n "$DBADMIN_PASS" ]; then ok "Conta de administração MariaDB criada (mpadmin)."; else warn "Não foi possível criar a conta mpadmin (usa: mpanel db-admin-passwd)."; fi
fi

# ----------------------------------------------------------------------------
# 11. Arranque dos serviços
# ----------------------------------------------------------------------------
say "A arrancar serviços..."
for v in $ALL_PHP; do
  "$(php_fpm_bin "$v")" -t -y "$(php_fpm_conf "$v")" >/dev/null 2>&1 || die "Configuração do PHP-FPM $v inválida ($(php_fpm_bin "$v") -t)."
  systemctl enable "$(php_service "$v")" >/dev/null 2>&1 || true
  systemctl reload-or-restart "$(php_service "$v")"
done
nginx -t >/dev/null 2>&1 || { nginx -t; die "Configuração do nginx inválida."; }
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload-or-restart nginx

/usr/local/sbin/mpanel fm-sync || warn "Não foi possível configurar o gestor de ficheiros (mpanel fm-sync)."
/usr/local/sbin/mpanel fw-restore >/dev/null || warn "Não foi possível ativar a firewall de ligações (mpanel fw-restore)."
/usr/local/sbin/mpanel cron-sync >/dev/null || warn "Não foi possível sincronizar as tarefas agendadas (mpanel cron-sync)."
/usr/local/sbin/mpanel bk-init >/dev/null || warn "Não foi possível configurar os backups (mpanel bk-init)."
/usr/local/sbin/mpanel state || warn "Não foi possível gerar o estado inicial (mpanel state)."

# ----------------------------------------------------------------------------
# Resumo
# ----------------------------------------------------------------------------
SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$SRV_IP" ] || SRV_IP="IP-do-servidor"

if [ -n "$ADMIN_PASS" ]; then
  umask 077
  cat > /root/minipainel-credenciais.txt <<EOF
IDDigital Hosting v$MP_VERSION
Painel:     https://$SRV_IP:$PANEL_PORT  (ou https://localhost:$PANEL_PORT)
Utilizador: $PANEL_USER
Password:   $ADMIN_PASS
EOF
fi
if [ -n "$DBADMIN_PASS" ]; then
  umask 077
  cat >> /root/minipainel-credenciais.txt <<EOF

phpMyAdmin: https://$SRV_IP:$PANEL_PORT/phpmyadmin/  (requer sessão no painel)
MariaDB admin: mpadmin
Password:      $DBADMIN_PASS
EOF
fi

echo
echo "=============================================================="
echo " IDDigital Hosting v$MP_VERSION instalado"
echo "=============================================================="
echo " Painel:      https://$SRV_IP:$PANEL_PORT"
echo "              https://localhost:$PANEL_PORT"
echo "              (certificado autoassinado: aceita o aviso do browser)"
if [ -n "$ADMIN_PASS" ]; then
  echo " Utilizador:  $PANEL_USER"
  echo " Password:    $ADMIN_PASS"
  echo " Guardado em: /root/minipainel-credenciais.txt"
else
  echo " Credenciais: mantidas (mudar com: mpanel passwd)"
fi
echo " phpMyAdmin:  https://$SRV_IP:$PANEL_PORT/phpmyadmin/ (com sessão no painel)"
if [ -n "$DBADMIN_PASS" ]; then
  echo " MariaDB:     mpadmin / $DBADMIN_PASS (acesso a todas as bases)"
fi
echo " PHP:         $ALL_PHP(predefinido $DEFAULT_PHP)"
echo " Sites:       /srv/www/<site>/public_html  ->  http://$SRV_IP:<porta>"
echo " Ficheiros:   no painel, página Ficheiros (envios grandes por partes)"
echo " Recursos:    no painel, página Recursos (systemctl status minipainel-stats)"
echo " Backups:     todos os dias às 03:00 em /var/backups/minipainel (página Backups)"
echo " CLI:         mpanel help"
echo "=============================================================="
