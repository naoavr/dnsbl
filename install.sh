#!/usr/bin/env bash
# =============================================================================
# instalar-dnsbl-v2.2.sh
# Instala TUDO numa só VM/container: o site de gestão (backoffice) e o
# servidor DNS da lista (rbldnsd), ambos no mesmo nome, ex.: dnsbl.3rhost.pt
#
#   https://dnsbl.3rhost.pt              → site de gestão
#   58.39.118.92.dnsbl.3rhost.pt (DNS)   → consulta da lista pelos nós ISPmanager
#
# O que faz:
#   1. instala nginx, PHP-FPM (com SQLite e zip), rbldnsd e ferramentas
#   2. instala a plataforma DNSBL v1.5 (incluída neste script)
#   3. cria o administrador e configura a zona
#   4. o backoffice escreve a zona diretamente para o rbldnsd (sem sincronização)
#   5. configura o rbldnsd para responder à lista E ao endereço do site
#   6. cron das tarefas automáticas, firewall local e testes
#   7. agente SSL: os certificados gerem-se no backoffice (Sistema → Certificado SSL)
#
# Sistemas: Debian 11+, Ubuntu 20.04+, AlmaLinux/Rocky/RHEL 8 e 9
#
# Uso (como root):
#   bash instalar-dnsbl-v2.2.sh              instalação (pergunta os dados)
#   bash instalar-dnsbl-v2.2.sh --remover    remove serviços e configuração
#
# Pode ser executado várias vezes. Os dados e a configuração são sempre mantidos;
# se a plataforma incluída for mais recente do que a instalada, o código é atualizado
# (com cópia de segurança da versão anterior).
# =============================================================================
set -u

VERSAO="2.2"
DOMINIO=""
NS_NOME=""
IP_PUBLICO=""
IP_ESCUTA=""
ADMIN=""
MODO="instalar"

DIR_SITE="/var/www/dnsbl"
DIR_DNS="/var/lib/rbldnsd"
SERVICO_DNS="rbldnsd-dnsbl"
UNIT_DNS="/etc/systemd/system/${SERVICO_DNS}.service"
CRON="/etc/cron.d/dnsbl"
ESTADO="/etc/dnsbl-instalacao.conf"
AGENTE="/usr/local/lib/dnsbl/ssl-agente.php"
DIR_ACME="/var/lib/dnsbl-acme"

# ---------- saída ----------
if [ -t 1 ]; then
    C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_AV=$'\e[33m'; C_T=$'\e[1m'; C_0=$'\e[0m'
else
    C_OK=""; C_ERR=""; C_AV=""; C_T=""; C_0=""
fi
passo() { echo; echo "${C_T}==> $*${C_0}"; }
ok()    { echo "    ${C_OK}✔${C_0} $*"; }
aviso() { echo "    ${C_AV}!${C_0} $*"; }
erro()  { echo; echo "${C_ERR}✘ ERRO:${C_0} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ssl)     echo "Os certificados SSL gerem-se agora no site: Sistema → Certificado SSL."; exit 0 ;;
        --remover) MODO="remover"; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) erro "Opção desconhecida: $1 (use --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || erro "Este script tem de ser executado como root."
command -v systemctl >/dev/null 2>&1 || erro "É necessário systemd."
[ -r /etc/os-release ] || erro "Não foi possível identificar o sistema operativo."
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
    *rhel*|*centos*|*fedora*|*almalinux*|*rocky*) FAMILIA="rhel" ;;
    *debian*|*ubuntu*)                             FAMILIA="debian" ;;
    *) erro "Sistema não suportado: ${PRETTY_NAME:-desconhecido}" ;;
esac

instalar_pacotes() {
    if [ "$FAMILIA" = "rhel" ]; then
        dnf -y -q install "$@" >/dev/null 2>&1
    else
        DEBIAN_FRONTEND=noninteractive apt-get -y -q install "$@" >/dev/null 2>&1
    fi
}

# Utilizador do PHP-FPM e serviço
detetar_php() {
    if [ "$FAMILIA" = "debian" ]; then
        PHP_FPM="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1)"
        PHP_FPM="${PHP_FPM%.service}"
        PHP_USER="www-data"
        PHP_VER="${PHP_FPM#php}"; PHP_VER="${PHP_VER%-fpm}"
        PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
        NGINX_CONF="/etc/nginx/sites-available/dnsbl.conf"
    else
        PHP_FPM="php-fpm"
        PHP_USER="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/php-fpm.d/www.conf 2>/dev/null)"
        PHP_USER="${PHP_USER:-apache}"
        PHP_SOCK="/run/php-fpm/www.sock"
        NGINX_CONF="/etc/nginx/conf.d/dnsbl.conf"
    fi
}

# ---------- remoção ----------
if [ "$MODO" = "remover" ]; then
    passo "A remover a DNSBL"
    systemctl disable --now "$SERVICO_DNS" >/dev/null 2>&1
    systemctl disable --now dnsbl-ssl.path dnsbl-ssl-estado.timer >/dev/null 2>&1
    rm -f "$UNIT_DNS" "$CRON" /etc/nginx/sites-enabled/dnsbl.conf /etc/nginx/sites-available/dnsbl.conf /etc/nginx/conf.d/dnsbl.conf \
          /etc/systemd/system/dnsbl-ssl.path /etc/systemd/system/dnsbl-ssl.service \
          /etc/systemd/system/dnsbl-ssl-estado.service /etc/systemd/system/dnsbl-ssl-estado.timer "$AGENTE"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reload nginx >/dev/null 2>&1
    ok "Serviço DNS, cron e configuração do nginx removidos"
    aviso "Mantidos: $DIR_SITE (código e base de dados), $DIR_DNS, /etc/dnsbl e /etc/letsencrypt (certificados) e os pacotes."
    exit 0
fi

echo "${C_T}Instalação da DNSBL (site de gestão + servidor DNS) — v${VERSAO}${C_0}"

# ---------- dados ----------
perguntar() {
    local var="$1" texto="$2" pred="${3:-}" valor
    while [ -z "${!var}" ]; do
        if [ -n "$pred" ]; then
            read -r -p "    $texto [$pred]: " valor
            valor="${valor:-$pred}"
        else
            read -r -p "    $texto: " valor
        fi
        printf -v "$var" '%s' "$valor"
    done
}

[ -r "$ESTADO" ] && . "$ESTADO"
passo "Configuração"
IP_DETETADO="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
SUG_DOMINIO="${DOMINIO:-dnsbl.3rhost.pt}"; DOMINIO=""
perguntar DOMINIO "Endereço do site e nome da lista" "$SUG_DOMINIO"
DOMINIO="${DOMINIO,,}"
[[ "$DOMINIO" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || erro "Nome inválido: $DOMINIO"
PAI="${DOMINIO#*.}"
SUG_NS="${NS_NOME:-ns-bl1.${PAI}}"; NS_NOME=""
perguntar NS_NOME "Nome do servidor de nomes (criado na zona ${PAI})" "$SUG_NS"
SUG_ESC="${IP_ESCUTA:-$IP_DETETADO}"; IP_ESCUTA=""
perguntar IP_ESCUTA "IP local onde o DNS vai escutar" "$SUG_ESC"
SUG_PUB="${IP_PUBLICO:-$IP_ESCUTA}"; IP_PUBLICO=""
perguntar IP_PUBLICO "IP público deste servidor (se houver NAT, o IP de fora)" "$SUG_PUB"
for ip in "$IP_ESCUTA" "$IP_PUBLICO"; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || erro "IP inválido: $ip"
done
ip -4 addr show | grep -q "inet ${IP_ESCUTA}/" || erro "O IP $IP_ESCUTA não está configurado nesta máquina."

SUG_ADMIN="${ADMIN:-admin}"; ADMIN=""
perguntar ADMIN "Utilizador administrador do site" "$SUG_ADMIN"
[[ "$ADMIN" =~ ^[a-zA-Z0-9._-]{3,32}$ ]] || erro "Utilizador inválido (3 a 32 caracteres: letras, números, ponto, hífen ou _)."
SENHA=""
while [ -z "$SENHA" ]; do
    read -r -s -p "    Palavra-passe (mínimo 10 caracteres; Enter mantém a atual numa reinstalação): " S1; echo
    if [ -z "$S1" ] && [ -f "$DIR_SITE/data/dnsbl.sqlite" ]; then SENHA="-"; break; fi
    [ "${#S1}" -ge 10 ] || { aviso "Tem de ter pelo menos 10 caracteres."; continue; }
    read -r -s -p "    Repetir palavra-passe: " S2; echo
    [ "$S1" = "$S2" ] || { aviso "As palavras-passe não coincidem."; continue; }
    SENHA="$S1"
done
ok "Site e lista em $DOMINIO; DNS em ${IP_ESCUTA}:53 (público ${IP_PUBLICO})"

# ---------- portas ----------
passo "A verificar as portas"
porta53_ocupada() {
    # Coluna 4 do «ss -H -lnu»: endereço local (ex.: 91.209.16.23:53, 0.0.0.0:53, *:53)
    ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "^(${IP_ESCUTA//./\\.}|0\.0\.0\.0|\*|\[::\]):53$"
}
mostrar_porta53() {
    echo "      O que está a usar a porta 53:"
    ss -H -lnup 2>/dev/null | awk '$4 ~ /:53$/' | sed 's/^/        /'
}
if porta53_ocupada && ! systemctl is-active --quiet "$SERVICO_DNS"; then
    mostrar_porta53
    erro "A porta 53 em $IP_ESCUTA já está ocupada por outro serviço (ver acima). Desative-o e volte a correr o script."
fi
if ss -H -lntp 2>/dev/null | awk '{print $4}' | grep -Eq ':(80)$'; then
    ss -H -lntp | grep -q nginx || { ss -H -lntp | grep -E ':80 ' | sed 's/^/      /'; erro "A porta 80 está ocupada por outro servidor web (ver acima)."; }
fi
ok "Portas 53 e 80 disponíveis"

# ---------- pacotes ----------
passo "A instalar pacotes (pode demorar alguns minutos)"
if [ "$FAMILIA" = "rhel" ]; then
    instalar_pacotes epel-release
    if dnf -q module list php >/dev/null 2>&1; then
        dnf -y -q module reset php >/dev/null 2>&1
        dnf -y -q module enable php:8.2 >/dev/null 2>&1 || dnf -y -q module enable php:8.1 >/dev/null 2>&1
    fi
    instalar_pacotes nginx php-fpm php-cli php-pdo php-mbstring php-process curl cronie bind-utils iproute unzip tar \
        || erro "Falhou a instalação do nginx/PHP."
    instalar_pacotes certbot || aviso "certbot indisponível: os certificados Let's Encrypt não vão funcionar."
    systemctl enable --now certbot-renew.timer >/dev/null 2>&1
    instalar_pacotes php-pecl-zip || instalar_pacotes php-zip || aviso "Extensão PHP zip indisponível: as atualizações pelo backoffice não vão funcionar."
    systemctl enable --now crond >/dev/null 2>&1
else
    apt-get -q update >/dev/null 2>&1
    instalar_pacotes nginx php-fpm php-cli php-sqlite3 php-mbstring php-zip curl cron dnsutils iproute2 unzip tar \
        || erro "Falhou a instalação do nginx/PHP."
    instalar_pacotes certbot || aviso "certbot indisponível: os certificados Let's Encrypt não vão funcionar."
    systemctl enable --now cron >/dev/null 2>&1
fi
detetar_php
[ -n "$PHP_FPM" ] || erro "PHP-FPM não encontrado depois da instalação."
php -r 'exit(version_compare(PHP_VERSION, "8.0.0", ">=") ? 0 : 1);' || erro "É necessário PHP 8.0 ou superior (instalado: $(php -r 'echo PHP_VERSION;'))."
php -m | grep -qi '^pdo_sqlite$' || erro "O PHP não tem a extensão pdo_sqlite."
php -m | grep -qi '^posix$' || erro "O PHP não tem a extensão posix (necessária ao agente SSL)."
php -m | grep -qi '^openssl$' || erro "O PHP não tem a extensão openssl (necessária ao agente SSL)."
ok "nginx, PHP $(php -r 'echo PHP_VERSION;') (utilizador ${PHP_USER})"

passo "A instalar o rbldnsd"
RBLDNSD="$(command -v rbldnsd 2>/dev/null || true)"
if [ -z "$RBLDNSD" ]; then
    instalar_pacotes rbldnsd && RBLDNSD="$(command -v rbldnsd 2>/dev/null || true)"
fi
if [ -z "$RBLDNSD" ]; then
    aviso "Sem pacote disponível — a compilar a partir do código-fonte"
    if [ "$FAMILIA" = "rhel" ]; then instalar_pacotes gcc make zlib-devel; else instalar_pacotes gcc make zlib1g-dev; fi
    TMPB="$(mktemp -d)"
    for ramo in master main; do
        curl -fsSL "https://github.com/spamhaus/rbldnsd/archive/refs/heads/${ramo}.tar.gz" -o "$TMPB/src.tar.gz" && break
    done
    [ -s "$TMPB/src.tar.gz" ] || erro "Não foi possível descarregar o código-fonte do rbldnsd."
    tar -xzf "$TMPB/src.tar.gz" -C "$TMPB" || erro "Código-fonte inválido."
    SRC="$(find "$TMPB" -maxdepth 1 -type d -name 'rbldnsd-*' | head -n 1)"
    ( cd "$SRC" && ./configure >/dev/null 2>&1 && make >/dev/null 2>&1 ) || erro "A compilação do rbldnsd falhou."
    install -m 755 "$SRC/rbldnsd" /usr/local/sbin/rbldnsd
    rm -rf "$TMPB"
    RBLDNSD="/usr/local/sbin/rbldnsd"
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^rbldnsd\.service'; then
    systemctl disable --now rbldnsd >/dev/null 2>&1
fi
id rbldnsd >/dev/null 2>&1 || useradd -r -M -s /sbin/nologin rbldnsd 2>/dev/null || useradd -r -M -s /usr/sbin/nologin rbldnsd
ok "rbldnsd em $RBLDNSD"

# ---------- plataforma ----------
passo "A instalar a plataforma DNSBL"
mkdir -p "$DIR_SITE"
TMPZ="$(mktemp)"; TMPD="$(mktemp -d)"
sed -n '/^__PACOTE_DNSBL__$/,$p' "$0" | tail -n +2 | base64 -d > "$TMPZ" 2>/dev/null
unzip -q -o "$TMPZ" -d "$TMPD" || erro "O pacote incluído no script está danificado."
versao_de() { grep -o "define('APP_VERSION', '[^']*')" "$1/app/bootstrap.php" 2>/dev/null | sed "s/.*, '\(.*\)')/\1/"; }
V_NOVA="$(versao_de "$TMPD")"
if [ ! -f "$DIR_SITE/index.php" ]; then
    cp -a "$TMPD"/. "$DIR_SITE"/
    ok "Plataforma v${V_NOVA} instalada em $DIR_SITE"
else
    V_ATUAL="$(versao_de "$DIR_SITE")"
    if php -r 'exit(version_compare($argv[1], $argv[2], ">") ? 0 : 1);' "$V_NOVA" "${V_ATUAL:-0}"; then
        # Cópia da versão atual (aparece em Atualizações → Cópias de segurança)
        COPIA="$(runuser -u "$PHP_USER" -- php -r 'require $argv[1] . "/app/bootstrap.php"; echo basename(upd_backup_code());' "$DIR_SITE" 2>/dev/null)"
        # Nunca substituir a configuração nem os dados
        rm -f "$TMPD/config/config.php"
        find "$TMPD/data" -mindepth 1 ! -name '.htaccess' ! -name 'acesso-teste.txt' -exec rm -rf {} + 2>/dev/null
        cp -a "$TMPD"/. "$DIR_SITE"/
        ok "Plataforma atualizada de v${V_ATUAL} para v${V_NOVA} (cópia: ${COPIA:-não criada}); dados e configuração mantidos"
    else
        ok "Plataforma v${V_ATUAL} já instalada — código e dados mantidos"
    fi
fi
rm -rf "$TMPZ" "$TMPD"
if [ ! -f "$DIR_SITE/config/config.php" ]; then
    cp "$DIR_SITE/config/config.exemplo.php" "$DIR_SITE/config/config.php"
    # O HTTPS é gerido pelo nginx (agente SSL), não pela aplicação
    sed -i "s/'force_https'  => true,/'force_https'  => false,/" "$DIR_SITE/config/config.php"
fi
mkdir -p "$DIR_SITE/data" "$DIR_DNS"
chown -R "$PHP_USER":"$PHP_USER" "$DIR_SITE"
chown "$PHP_USER":"$PHP_USER" "$DIR_DNS"
chmod 755 "$DIR_DNS"

# Estado da instalação (lido pelo agente SSL e pelas reinstalações)
cat > "$ESTADO" << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh
DOMINIO="${DOMINIO}"
NS_NOME="${NS_NOME}"
IP_ESCUTA="${IP_ESCUTA}"
IP_PUBLICO="${IP_PUBLICO}"
ADMIN="${ADMIN}"
DIR_SITE="${DIR_SITE}"
PHP_USER="${PHP_USER}"
NGINX_CONF="${NGINX_CONF}"
PHP_SOCK="${PHP_SOCK}"
EOF
chmod 600 "$ESTADO"

# Registo do endereço do site, servido pelo rbldnsd na mesma zona
cat > "$DIR_DNS/geral.zone" << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh — endereço do site de gestão
@ 300 A ${IP_PUBLICO}
EOF
chmod 644 "$DIR_DNS/geral.zone"

# ---------- configuração inicial da plataforma ----------
passo "A configurar a plataforma"
SAIDA="$(printf '%s' "$SENHA" | runuser -u "$PHP_USER" -- env \
    DNSBL_DOMINIO="$DOMINIO" DNSBL_NS="$NS_NOME" DNSBL_SOA="hostmaster.${PAI}" \
    DNSBL_FICHEIRO="${DIR_DNS}/dnsbl.zone" DNSBL_ADMIN="$ADMIN" DNSBL_PROTEGER="$IP_PUBLICO" \
    php -r '
require "/var/www/dnsbl/app/bootstrap.php";
$db = db();
$set = ["zone" => getenv("DNSBL_DOMINIO"), "ns_hosts" => getenv("DNSBL_NS"),
        "soa_email" => getenv("DNSBL_SOA"), "zone_file" => getenv("DNSBL_FICHEIRO")];
foreach ($set as $k => $v) { if (setting($k) !== $v) { setting_set($k, $v); } }
$pass = stream_get_contents(STDIN);
$user = getenv("DNSBL_ADMIN");
if ($pass !== "-" && $pass !== "") {
    $st = $db->prepare("SELECT id FROM users WHERE username = ?");
    $st->execute([$user]);
    $hash = password_hash($pass, PASSWORD_DEFAULT);
    if ($id = $st->fetchColumn()) {
        $db->prepare("UPDATE users SET password_hash = ? WHERE id = ?")->execute([$hash, $id]);
        log_history("palavra_passe_alterada", $user, "Instalador do servidor", "sistema");
    } else {
        $db->prepare("INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?)")->execute([$user, $hash, now()]);
        log_history("utilizador_criado", $user, "Instalador do servidor", "sistema");
    }
}
@unlink(APP_ROOT . "/data/codigo-instalacao.txt");
// O próprio servidor nunca pode ser bloqueado
$r = ip_parse(getenv("DNSBL_PROTEGER"));
$st = $db->prepare("SELECT COUNT(*) FROM protected WHERE cidr = ?");
$st->execute([$r["cidr"]]);
if (!$st->fetchColumn()) {
    $db->prepare("INSERT INTO protected (cidr, ip_start, ip_end, description, created_at, created_by) VALUES (?, ?, ?, ?, ?, ?)")
       ->execute([$r["cidr"], $r["start"], $r["end"], "Servidor da DNSBL", now(), "sistema"]);
}
zone_mark_dirty();
$z = zone_write();
echo $z["ok"] ? "OK" : "ERRO: " . $z["error"];
' 2>&1)"
[ "${SAIDA##*$'\n'}" = "OK" ] || { echo "$SAIDA" | sed 's/^/      /'; erro "A configuração da plataforma falhou."; }
ok "Zona $DOMINIO, servidor de nomes $NS_NOME, administrador $ADMIN"
ok "O IP $IP_PUBLICO ficou em Protegidos (nunca é bloqueado)"

# ---------- agente SSL ----------
passo "A instalar o agente SSL"
mkdir -p "$(dirname "$AGENTE")" "$DIR_ACME/.well-known/acme-challenge"
chmod 755 "$DIR_ACME"
cat > "$AGENTE" << 'AGENTE_EOF'
#!/usr/bin/env php
<?php
/*
 * DNSBL — agente SSL v1.0
 * Instalado em /usr/local/lib/dnsbl/ssl-agente.php (root, 0700) pelo instalador do servidor.
 *
 * Executa, como root, as operações pedidas pelo backoffice:
 *   emitir (Let's Encrypt), renovar, carregar (certificado próprio), https, remover, estado
 * e gera a configuração do nginx do site.
 *
 * SEGURANÇA: este ficheiro nunca inclui código da pasta do site (que é gravável pelo
 * utilizador do PHP). Tudo o que vem de data/ssl/ é tratado como dados não confiáveis.
 *
 * Uso:
 *   ssl-agente.php            processa data/ssl/pedido.json (acionado pelo systemd)
 *   ssl-agente.php --estado   só atualiza data/ssl/estado.json
 *   ssl-agente.php --nginx    gera e aplica a configuração do nginx
 *   ssl-agente.php --renovado chamado pelo certbot depois de renovar
 */
declare(strict_types=1);

const VERSAO_AGENTE = '1.0';
const INSTALACAO    = '/etc/dnsbl-instalacao.conf';
const CONF_SSL      = '/etc/dnsbl/ssl.json';
const DIR_PROPRIO   = '/etc/dnsbl/ssl';
const DIR_ACME      = '/var/lib/dnsbl-acme';
const REG           = '/var/log/dnsbl-ssl.log';
const AGENTE        = '/usr/local/lib/dnsbl/ssl-agente.php';

if (PHP_SAPI !== 'cli') {
    exit(1);
}
$uid = function_exists('posix_geteuid') ? posix_geteuid() : (int)trim((string)shell_exec('id -u'));
if ($uid !== 0) {
    fwrite(STDERR, "O agente SSL tem de correr como root.\n");
    exit(1);
}
umask(022);

// ---------------------------------------------------------------- utilitários

function registo(string $msg): void
{
    @file_put_contents(REG, date('Y-m-d H:i:s') . ' ' . $msg . "\n", FILE_APPEND);
}

function ler_instalacao(): array
{
    $v = [];
    foreach (@file(INSTALACAO, FILE_IGNORE_NEW_LINES) ?: [] as $l) {
        if (preg_match('/^([A-Z_]+)="(.*)"$/', trim($l), $m)) {
            $v[$m[1]] = $m[2];
        }
    }
    $v += ['DIR_SITE' => '/var/www/dnsbl', 'PHP_USER' => 'www-data', 'NGINX_CONF' => '', 'PHP_SOCK' => ''];
    foreach (['DOMINIO', 'IP_PUBLICO', 'NGINX_CONF', 'PHP_SOCK'] as $k) {
        if (empty($v[$k])) {
            throw new RuntimeException("Configuração da instalação incompleta ({$k} em " . INSTALACAO . ').');
        }
    }
    if (!preg_match('/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/', $v['DOMINIO'])) {
        throw new RuntimeException('Domínio inválido em ' . INSTALACAO . '.');
    }
    return $v;
}

function correr(string $cmd, ?string &$saida = null): int
{
    $out = [];
    exec($cmd . ' 2>&1', $out, $rc);
    $saida = implode("\n", $out);
    return $rc;
}

function conf_ssl(): array
{
    $c = is_file(CONF_SSL) ? json_decode((string)file_get_contents(CONF_SSL), true) : null;
    return is_array($c) ? $c + ['modo' => 'nenhum', 'forcar_https' => false, 'email' => ''] : ['modo' => 'nenhum', 'forcar_https' => false, 'email' => ''];
}

function guardar_conf_ssl(array $c): void
{
    @mkdir(dirname(CONF_SSL), 0700, true);
    $tmp = CONF_SSL . '.tmp';
    file_put_contents($tmp, json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    chmod($tmp, 0600);
    rename($tmp, CONF_SSL);
}

/** Pasta de troca com o backoffice: tem de existir, não ser ligação simbólica e pertencer ao utilizador do PHP. */
function dir_troca(array $I): string
{
    $dir = rtrim($I['DIR_SITE'], '/') . '/data/ssl';
    $pw  = posix_getpwnam($I['PHP_USER']);
    if (!$pw) {
        throw new RuntimeException("Utilizador {$I['PHP_USER']} não existe.");
    }
    if (!is_dir($dir)) {
        if (is_link($dir) || file_exists($dir)) {
            throw new RuntimeException("{$dir} existe mas não é uma pasta.");
        }
        mkdir($dir, 0750, true);
        chown($dir, $pw['uid']);
        chgrp($dir, $pw['gid']);
    }
    if (is_link($dir) || realpath($dir) !== $dir || fileowner($dir) !== $pw['uid']) {
        throw new RuntimeException("{$dir} não é de confiança (ligação simbólica ou dono errado).");
    }
    return $dir;
}

/** Escreve um ficheiro na pasta de troca de forma segura (sem seguir ligações simbólicas). */
function escrever_troca(array $I, string $nome, string $conteudo): void
{
    $dir = dir_troca($I);
    $pw  = posix_getpwnam($I['PHP_USER']);
    $tmp = $dir . '/.agente-' . bin2hex(random_bytes(6)) . '.tmp';
    $f = @fopen($tmp, 'x');
    if (!$f) {
        throw new RuntimeException('Não foi possível escrever em ' . $dir);
    }
    fwrite($f, $conteudo);
    fclose($f);
    chown($tmp, $pw['uid']);
    chgrp($tmp, $pw['gid']);
    chmod($tmp, 0640);
    rename($tmp, $dir . '/' . $nome);
}

/** Lê um ficheiro da pasta de troca (recusa ligações simbólicas e ficheiros grandes). */
function ler_troca(array $I, string $rel, int $max = 102400): ?string
{
    $f = dir_troca($I) . '/' . $rel;
    if (!file_exists($f) && !is_link($f)) {
        return null;
    }
    if (is_link($f) || !is_file($f)) {
        throw new RuntimeException("{$rel}: ficheiro inválido.");
    }
    if (filesize($f) > $max) {
        throw new RuntimeException("{$rel}: ficheiro demasiado grande.");
    }
    return (string)file_get_contents($f);
}

function apagar_troca(array $I, string $rel): void
{
    $f = dir_troca($I) . '/' . $rel;
    if (is_link($f) || is_file($f)) {
        @unlink($f);
    }
}

// ---------------------------------------------------------------- certificados

function caminhos_cert(array $I, array $c): ?array
{
    if ($c['modo'] === 'letsencrypt') {
        $b = '/etc/letsencrypt/live/' . $I['DOMINIO'];
        return ['cert' => $b . '/fullchain.pem', 'chave' => $b . '/privkey.pem'];
    }
    if ($c['modo'] === 'proprio') {
        return ['cert' => DIR_PROPRIO . '/fullchain.pem', 'chave' => DIR_PROPRIO . '/privkey.pem'];
    }
    return null;
}

/** Nomes cobertos por um certificado (CN e SAN). */
function nomes_cert(array $x): array
{
    $n = [];
    if (!empty($x['subject']['CN'])) {
        $n[] = strtolower((string)$x['subject']['CN']);
    }
    foreach (explode(',', (string)($x['extensions']['subjectAltName'] ?? '')) as $s) {
        $s = trim($s);
        if (stripos($s, 'DNS:') === 0) {
            $n[] = strtolower(substr($s, 4));
        }
    }
    return array_values(array_unique($n));
}

function cobre(array $nomes, string $dominio): bool
{
    foreach ($nomes as $n) {
        if ($n === $dominio) {
            return true;
        }
        if (strpos($n, '*.') === 0 && substr_count($dominio, '.') >= 2 && substr($dominio, strpos($dominio, '.')) === substr($n, 1)) {
            return true;
        }
    }
    return false;
}

function info_cert(?array $p): ?array
{
    if (!$p || !is_file($p['cert'])) {
        return null;
    }
    $x = @openssl_x509_parse((string)file_get_contents($p['cert']));
    if (!$x) {
        return null;
    }
    $ate = (int)$x['validTo_time_t'];
    $emissor = (string)($x['issuer']['O'] ?? $x['issuer']['CN'] ?? 'desconhecido');
    if (!empty($x['issuer']['CN']) && !empty($x['issuer']['O']) && $x['issuer']['CN'] !== $x['issuer']['O']) {
        $emissor .= ' (' . $x['issuer']['CN'] . ')';
    }
    return [
        'emissor'    => $emissor,
        'dominios'   => nomes_cert($x),
        'valido_ate' => date('Y-m-d H:i:s', $ate),
        'dias'       => (int)floor(($ate - time()) / 86400),
    ];
}

// ---------------------------------------------------------------- nginx

function nginx_config(array $I, array $c): string
{
    $d    = $I['DOMINIO'];
    $root = rtrim($I['DIR_SITE'], '/');
    $p    = caminhos_cert($I, $c);
    $temCert = $p && is_file($p['cert']) && is_file($p['chave']);

    $acme = "    # Validação do Let's Encrypt\n"
          . "    location ^~ /.well-known/acme-challenge/ {\n"
          . "        root " . DIR_ACME . ";\n"
          . "        default_type text/plain;\n"
          . "    }\n";

    $app = "    root {$root};\n"
         . "    index index.php;\n"
         . "    client_max_body_size 25m;\n\n"
         . "    # Pastas internas e ficheiros de dados: nunca servir\n"
         . "    location ~ ^/(app|bin|config|data|rbldnsd)(/|\$) { return 404; }\n"
         . "    location ~ \\.(md|sqlite|sqlite-wal|sqlite-shm|zone|lock|sh|service|conf|tmp)\$ { return 404; }\n"
         . "    location ~ /\\.(?!well-known/) { return 404; }\n\n"
         . "    location / {\n"
         . "        try_files \$uri \$uri/ /index.php?\$query_string;\n"
         . "    }\n\n"
         . "    location ~ \\.php\$ {\n"
         . "        try_files \$uri =404;\n"
         . "        include fastcgi_params;\n"
         . "        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;\n"
         . "        fastcgi_param PHP_VALUE \"upload_max_filesize=20M\npost_max_size=21M\";\n"
         . "        fastcgi_pass unix:{$I['PHP_SOCK']};\n"
         . "    }\n";

    $cfg = "# Gerado pelo agente SSL da DNSBL v" . VERSAO_AGENTE . " — não editar à mão (é reescrito)\n";
    $cfg .= "server {\n    listen 80;\n    server_name {$d};\n\n{$acme}\n";
    if ($temCert && $c['forcar_https']) {
        $cfg .= "    location / {\n        return 301 https://\$host\$request_uri;\n    }\n}\n";
    } else {
        $cfg .= $app . "}\n";
    }
    if ($temCert) {
        $cfg .= "\nserver {\n    listen 443 ssl http2;\n    server_name {$d};\n\n"
              . "    ssl_certificate {$p['cert']};\n"
              . "    ssl_certificate_key {$p['chave']};\n"
              . "    ssl_protocols TLSv1.2 TLSv1.3;\n"
              . "    ssl_prefer_server_ciphers off;\n"
              . "    ssl_session_cache shared:DNSBL:10m;\n"
              . "    ssl_session_timeout 1d;\n\n"
              . $acme . "\n" . $app . "}\n";
    }
    return $cfg;
}

function recarregar_nginx(): void
{
    if (is_dir('/run/systemd/system')) {
        correr('systemctl reload nginx');
    } else {
        correr('nginx -s reload');
    }
}

/** Grava a configuração, valida com «nginx -t» e só então recarrega; se falhar, repõe a anterior. */
function aplicar_nginx(array $I, array $c): void
{
    @mkdir(DIR_ACME . '/.well-known/acme-challenge', 0755, true);
    $f = $I['NGINX_CONF'];
    $anterior = is_file($f) ? (string)file_get_contents($f) : null;
    file_put_contents($f, nginx_config($I, $c));
    if (is_dir('/etc/nginx/sites-enabled') && strpos($f, '/etc/nginx/sites-available/') === 0) {
        $l = '/etc/nginx/sites-enabled/' . basename($f);
        if (!file_exists($l)) {
            @symlink($f, $l);
        }
    }
    if (correr('nginx -t', $out) !== 0) {
        if ($anterior !== null) {
            file_put_contents($f, $anterior);
        }
        throw new RuntimeException("A nova configuração do nginx é inválida; foi reposta a anterior.\n" . $out);
    }
    recarregar_nginx();
}

// ---------------------------------------------------------------- estado

function publicar_estado(array $I, ?array $ultimo = null): void
{
    $c = conf_ssl();
    $anterior = null;
    try {
        $txt = ler_troca($I, 'estado.json', 1024 * 1024);
        $anterior = $txt !== null ? json_decode($txt, true) : null;
    } catch (Throwable $e) {
    }
    $renov = false;
    foreach (['certbot.timer', 'certbot-renew.timer', 'snap.certbot.renew.timer'] as $t) {
        if (correr('systemctl is-active ' . escapeshellarg($t)) === 0) {
            $renov = true;
        }
    }
    if (!$renov && (is_file('/etc/cron.d/certbot'))) {
        $renov = true;
    }
    $e = [
        'agente'         => VERSAO_AGENTE,
        'quando'         => date('Y-m-d H:i:s'),
        'dominio'        => $I['DOMINIO'],
        'ip_publico'     => $I['IP_PUBLICO'],
        'modo'           => $c['modo'],
        'forcar_https'   => (bool)$c['forcar_https'],
        'email'          => (string)$c['email'],
        'certificado'    => info_cert(caminhos_cert($I, $c)),
        'renovacao_auto' => $renov,
        'ultimo'         => $ultimo ?? ($anterior['ultimo'] ?? null),
    ];
    escrever_troca($I, 'estado.json', json_encode($e, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
}

// ---------------------------------------------------------------- operações

function op_emitir(array $I, array $pedido, string &$log): string
{
    $email = (string)($pedido['email'] ?? '');
    if (!filter_var($email, FILTER_VALIDATE_EMAIL) || preg_match('/[\s\'"`$\\\\]/', $email)) {
        throw new RuntimeException('Email inválido.');
    }
    if (!is_executable('/usr/bin/certbot') && trim((string)shell_exec('command -v certbot')) === '') {
        throw new RuntimeException('O certbot não está instalado. Volte a correr o instalador do servidor (v2.2 ou superior).');
    }

    // O domínio tem de apontar para este servidor na internet
    correr('dig +short +time=3 +tries=2 @1.1.1.1 ' . escapeshellarg($I['DOMINIO']) . ' A', $r);
    $ips = array_values(array_filter(array_map('trim', explode("\n", $r)), fn ($x) => filter_var($x, FILTER_VALIDATE_IP)));
    if (!in_array($I['IP_PUBLICO'], $ips, true)) {
        throw new RuntimeException("{$I['DOMINIO']} ainda não aponta para {$I['IP_PUBLICO']} na internet (resposta: "
            . ($ips ? implode(', ', $ips) : 'nenhuma') . '). Crie a delegação na zona DNS e tente de novo daqui a alguns minutos.');
    }

    // O nginx tem de servir a pasta de validação antes de pedir o certificado
    aplicar_nginx($I, conf_ssl());

    $cmd = 'certbot certonly --webroot -w ' . escapeshellarg(DIR_ACME)
         . ' -d ' . escapeshellarg($I['DOMINIO'])
         . ' --cert-name ' . escapeshellarg($I['DOMINIO'])
         . ' -m ' . escapeshellarg($email)
         . ' --agree-tos --non-interactive --keep-until-expiring'
         . ' --deploy-hook ' . escapeshellarg(AGENTE . ' --renovado');
    $rc = correr($cmd, $log);
    if ($rc !== 0) {
        throw new RuntimeException("O Let's Encrypt não emitiu o certificado. Veja o registo abaixo (causas habituais: porta 80 fechada na firewall/NAT, ou limite de pedidos atingido).");
    }
    $c = conf_ssl();
    $c['modo'] = 'letsencrypt';
    $c['email'] = $email;
    guardar_conf_ssl($c);
    aplicar_nginx($I, $c);
    return "Certificado Let's Encrypt emitido e instalado. Pode agora ativar o HTTPS obrigatório.";
}

function op_renovar(array $I, array $pedido, string &$log): string
{
    $c = conf_ssl();
    if ($c['modo'] !== 'letsencrypt') {
        throw new RuntimeException("Só os certificados Let's Encrypt são renovados aqui. Um certificado próprio substitui-se instalando o novo.");
    }
    $forcar = !empty($pedido['forcar']);
    $cmd = 'certbot renew --cert-name ' . escapeshellarg($I['DOMINIO']) . ' --non-interactive'
         . ($forcar ? ' --force-renewal' : '')
         . ' --deploy-hook ' . escapeshellarg(AGENTE . ' --renovado');
    $rc = correr($cmd, $log);
    if ($rc !== 0) {
        throw new RuntimeException('A renovação falhou. Veja o registo abaixo.');
    }
    if (stripos($log, 'not due for renewal') !== false || stripos($log, 'No renewals were attempted') !== false) {
        return 'O certificado ainda não precisa de renovação: renova sozinho quando faltarem menos de 30 dias.';
    }
    aplicar_nginx($I, $c);
    return 'Certificado renovado.';
}

function op_carregar(array $I, string &$log): string
{
    try {
        $cert   = ler_troca($I, 'upload/certificado.pem');
        $chave  = ler_troca($I, 'upload/chave.pem');
        $cadeia = ler_troca($I, 'upload/cadeia.pem');
    } finally {
        foreach (['certificado', 'chave', 'cadeia'] as $n) {
            apagar_troca($I, "upload/{$n}.pem");
        }
    }
    if ($cert === null || $chave === null) {
        throw new RuntimeException('Faltam o certificado ou a chave privada.');
    }
    $x509 = @openssl_x509_read($cert);
    if (!$x509) {
        throw new RuntimeException('O ficheiro do certificado não é um certificado X.509 válido.');
    }
    $pk = @openssl_pkey_get_private($chave);
    if (!$pk) {
        throw new RuntimeException('A chave privada não é válida ou está protegida por palavra-passe.');
    }
    if (!openssl_x509_check_private_key($x509, $pk)) {
        throw new RuntimeException('A chave privada não corresponde ao certificado.');
    }
    $x = openssl_x509_parse($x509);
    if ((int)$x['validTo_time_t'] < time()) {
        throw new RuntimeException('O certificado já expirou em ' . date('d/m/Y', (int)$x['validTo_time_t']) . '.');
    }
    $nomes = nomes_cert($x);
    if (!cobre($nomes, $I['DOMINIO'])) {
        throw new RuntimeException("O certificado não cobre {$I['DOMINIO']} (cobre: " . implode(', ', $nomes) . ').');
    }
    $fullchain = trim($cert) . "\n";
    if ($cadeia !== null && trim($cadeia) !== '') {
        if (!preg_match_all('/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/s', $cadeia, $mm)) {
            throw new RuntimeException('O ficheiro da cadeia não contém certificados.');
        }
        foreach ($mm[0] as $pem) {
            if (!@openssl_x509_read($pem)) {
                throw new RuntimeException('A cadeia contém um certificado inválido.');
            }
            $fullchain .= $pem . "\n";
        }
    }
    openssl_pkey_export($pk, $chaveLimpa);

    @mkdir(DIR_PROPRIO, 0700, true);
    chmod(DIR_PROPRIO, 0700);
    foreach (['fullchain.pem' => [$fullchain, 0644], 'privkey.pem' => [$chaveLimpa, 0600]] as $nome => [$conteudo, $modo]) {
        $tmp = DIR_PROPRIO . '/.' . $nome . '.tmp';
        file_put_contents($tmp, $conteudo);
        chmod($tmp, $modo);
        rename($tmp, DIR_PROPRIO . '/' . $nome);
    }
    $c = conf_ssl();
    $c['modo'] = 'proprio';
    guardar_conf_ssl($c);
    aplicar_nginx($I, $c);
    $log = 'Certificado de ' . ($x['issuer']['O'] ?? $x['issuer']['CN'] ?? '?') . ' para ' . implode(', ', $nomes)
         . ', válido até ' . date('d/m/Y', (int)$x['validTo_time_t']) . '.';
    return 'Certificado próprio instalado.';
}

function op_https(array $I, array $pedido): string
{
    $c = conf_ssl();
    $on = !empty($pedido['forcar_https']);
    if ($on && !caminhos_cert($I, $c)) {
        throw new RuntimeException('Instale primeiro um certificado.');
    }
    $c['forcar_https'] = $on;
    guardar_conf_ssl($c);
    aplicar_nginx($I, $c);
    return $on ? 'HTTPS obrigatório ativo: os acessos por HTTP são redirecionados para HTTPS.' : 'HTTPS obrigatório desativado.';
}

function op_remover(array $I): string
{
    $c = conf_ssl();
    $c['modo'] = 'nenhum';
    $c['forcar_https'] = false;
    guardar_conf_ssl($c);
    aplicar_nginx($I, $c);
    return "Certificado removido do site; o site funciona só por HTTP. (Os ficheiros do Let's Encrypt são mantidos e podem voltar a ser usados.)";
}

// ---------------------------------------------------------------- principal

$lock = fopen('/run/dnsbl-ssl.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX)) {
    exit(1);
}

try {
    $I = ler_instalacao();
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}

// Primeira utilização: aproveitar um certificado Let's Encrypt já existente
if (!is_file(CONF_SSL)) {
    $le = '/etc/letsencrypt/live/' . $I['DOMINIO'] . '/fullchain.pem';
    guardar_conf_ssl(is_file($le)
        ? ['modo' => 'letsencrypt', 'forcar_https' => true, 'email' => '']
        : ['modo' => 'nenhum', 'forcar_https' => false, 'email' => '']);
}

$arg = $argv[1] ?? '';
try {
    if ($arg === '--nginx') {
        aplicar_nginx($I, conf_ssl());
        publicar_estado($I);
        exit(0);
    }
    if ($arg === '--estado') {
        publicar_estado($I);
        exit(0);
    }
    if ($arg === '--renovado') {
        recarregar_nginx();
        registo('certificado renovado pelo certbot');
        publicar_estado($I);
        exit(0);
    }
} catch (Throwable $e) {
    registo('erro: ' . $e->getMessage());
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}

// Processar o pedido do backoffice
try {
    $txt = ler_troca($I, 'pedido.json', 65536);
} catch (Throwable $e) {
    apagar_troca($I, 'pedido.json');
    registo('pedido rejeitado: ' . $e->getMessage());
    exit(1);
}
if ($txt === null) {
    exit(0);
}
apagar_troca($I, 'pedido.json');

$pedido = json_decode($txt, true);
$id   = is_array($pedido) && preg_match('/^[a-f0-9]{16}$/', (string)($pedido['id'] ?? '')) ? (string)$pedido['id'] : '';
$acao = is_array($pedido) ? (string)($pedido['acao'] ?? '') : '';
$log  = '';
registo("pedido {$id}: {$acao}");

try {
    if ($id === '') {
        throw new RuntimeException('Pedido inválido.');
    }
    switch ($acao) {
        case 'emitir':   $msg = op_emitir($I, $pedido, $log); break;
        case 'renovar':  $msg = op_renovar($I, $pedido, $log); break;
        case 'carregar': $msg = op_carregar($I, $log); break;
        case 'https':    $msg = op_https($I, $pedido); break;
        case 'remover':  $msg = op_remover($I); break;
        case 'estado':   $msg = 'Estado atualizado.'; break;
        default: throw new RuntimeException('Ação desconhecida.');
    }
    $res = 'ok';
} catch (Throwable $e) {
    $msg = $e->getMessage();
    $res = 'erro';
    // A mensagem do nginx -t vai para o registo, não para o texto principal
    if (strpos($msg, "\n") !== false) {
        [$msg, $extra] = explode("\n", $msg, 2);
        $log = trim($log . "\n" . $extra);
    }
}
registo("pedido {$id}: {$res} — {$msg}");

$ultimo = [
    'id'        => $id !== '' ? $id : bin2hex(random_bytes(8)),
    'acao'      => $acao,
    'resultado' => $res,
    'mensagem'  => $msg,
    'log'       => implode("\n", array_slice(explode("\n", trim($log)), -25)),
    'quando'    => date('Y-m-d H:i:s'),
];
try {
    publicar_estado($I, $ultimo);
} catch (Throwable $e) {
    registo('erro ao publicar o estado: ' . $e->getMessage());
}
exit($res === 'ok' ? 0 : 1);
AGENTE_EOF
chown root:root "$AGENTE"
chmod 700 "$AGENTE"
PHP_BIN="$(command -v php)"
cat > /etc/systemd/system/dnsbl-ssl.path << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh — aciona o agente quando o backoffice faz um pedido
[Unit]
Description=DNSBL - pedidos SSL do backoffice

[Path]
PathExists=${DIR_SITE}/data/ssl/pedido.json
Unit=dnsbl-ssl.service

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/dnsbl-ssl.service << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh
[Unit]
Description=DNSBL - agente SSL (processa um pedido do backoffice)

[Service]
Type=oneshot
ExecStart=${PHP_BIN} ${AGENTE}
EOF
cat > /etc/systemd/system/dnsbl-ssl-estado.service << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh
[Unit]
Description=DNSBL - atualiza o estado do certificado SSL

[Service]
Type=oneshot
ExecStart=${PHP_BIN} ${AGENTE} --estado
EOF
cat > /etc/systemd/system/dnsbl-ssl-estado.timer << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh
[Unit]
Description=DNSBL - estado do certificado SSL (periódico)

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
EOF
mkdir -p "$DIR_SITE/data/ssl"
chown "$PHP_USER":"$PHP_USER" "$DIR_SITE/data/ssl"
chmod 750 "$DIR_SITE/data/ssl"
systemctl daemon-reload
systemctl enable --now dnsbl-ssl.path dnsbl-ssl-estado.timer >/dev/null 2>&1 || erro "Não foi possível ativar o agente SSL."
ok "Agente em $AGENTE, acionado pelos pedidos do backoffice"

# ---------- nginx ----------
passo "A configurar o nginx"
if [ "$FAMILIA" = "debian" ]; then
    # Servidor dedicado: o site de exemplo do nginx não é necessário
    # (a ligação em sites-enabled para o site da DNSBL é criada pelo agente)
    rm -f /etc/nginx/sites-enabled/default
fi
# Sem IPv6 no servidor/container, as linhas «listen [::]» impedem o nginx de arrancar
if ! nginx -t >/dev/null 2>&1 && nginx -t 2>&1 | grep -q 'Address family not supported'; then
    sed -i -E 's/^([[:space:]]*listen[[:space:]]+\[::\].*)$/# \1  # desativado: sem IPv6/' /etc/nginx/nginx.conf
    aviso "Sem IPv6: desativadas as linhas «listen [::]» do nginx.conf"
fi
systemctl enable --now "$PHP_FPM" >/dev/null 2>&1 || erro "O PHP-FPM não arrancou."
systemctl enable --now nginx >/dev/null 2>&1
# A configuração do site é gerada pelo agente (mantém o certificado, se já existir)
"$PHP_BIN" "$AGENTE" --nginx >/tmp/dnsbl-nginx.log 2>&1 || { sed 's/^/      /' /tmp/dnsbl-nginx.log; erro "Não foi possível configurar o nginx (ver acima)."; }
systemctl restart nginx || erro "O nginx não arrancou."
ok "Site em http://${DOMINIO} (raiz ${DIR_SITE})"

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    instalar_pacotes policycoreutils-python-utils
    semanage fcontext -a -t httpd_sys_rw_content_t "${DIR_SITE}(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "${DIR_SITE}(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "${DIR_DNS}(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_rw_content_t "${DIR_DNS}(/.*)?"
    semanage fcontext -a -t httpd_sys_content_t "${DIR_ACME}(/.*)?" 2>/dev/null || true
    restorecon -R "$DIR_SITE" "$DIR_DNS" "$DIR_ACME"
    setsebool -P httpd_can_network_connect 1
    ok "SELinux: permissões de escrita e de rede para o PHP"
fi

# ---------- DNS ----------
passo "A configurar o servidor DNS"
cat > "$UNIT_DNS" << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh
[Unit]
Description=rbldnsd - DNSBL ${DOMINIO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RBLDNSD} -n -r ${DIR_DNS} -u rbldnsd -b ${IP_ESCUTA}/53 -c 60 -t 300 ${DOMINIO}:ip4set:dnsbl.zone ${DOMINIO}:generic:geral.zone
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl stop "$SERVICO_DNS" >/dev/null 2>&1
sleep 1
if porta53_ocupada; then
    mostrar_porta53
    erro "A porta 53 em $IP_ESCUTA foi ocupada por outro serviço (ver acima). Desative-o (systemctl disable --now NOME) e volte a correr o script."
fi
systemctl enable "$SERVICO_DNS" >/dev/null 2>&1
systemctl restart "$SERVICO_DNS"
sleep 2
systemctl is-active --quiet "$SERVICO_DNS" || { journalctl -u "$SERVICO_DNS" -n 15 --no-pager | sed 's/^/      /'; erro "O rbldnsd não arrancou."; }
ok "rbldnsd ativo em ${IP_ESCUTA}:53"

# ---------- cron ----------
cat > "$CRON" << EOF
# Gerado por instalar-dnsbl-v${VERSAO}.sh — tarefas automáticas da DNSBL
* * * * * ${PHP_USER} php ${DIR_SITE}/bin/dnsbl-cron.php >/dev/null 2>&1
EOF
chmod 644 "$CRON"
ok "Tarefas automáticas de minuto a minuto"

# ---------- firewall ----------
passo "Firewall local"
if systemctl is-active --quiet firewalld; then
    firewall-cmd -q --permanent --add-service=dns --add-service=http --add-service=https && firewall-cmd -q --reload
    ok "firewalld: portas 53, 80 e 443 abertas"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 53 >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
    ok "ufw: portas 53, 80 e 443 abertas"
else
    ok "Sem firewall local ativa"
fi
aviso "Na firewall do Proxmox/datacenter (ou no NAT), abra 53 (UDP e TCP), 80 e 443 para este servidor."

# ---------- testes ----------
passo "Testes"
FALHOU=0
R="$(dig +short +time=2 +tries=1 @"$IP_ESCUTA" "2.0.0.127.${DOMINIO}" A 2>/dev/null)"
if [ "$R" = "127.0.0.2" ]; then ok "Lista: entrada de teste 2.0.0.127 → 127.0.0.2"; else aviso "Lista: resposta inesperada '${R}'"; FALHOU=1; fi
R="$(dig +short +time=2 +tries=1 @"$IP_ESCUTA" "1.0.0.127.${DOMINIO}" A 2>/dev/null)"
if [ -z "$R" ]; then ok "Lista: 1.0.0.127 não listado (correto)"; else aviso "Lista: 1.0.0.127 devia não estar listado"; FALHOU=1; fi
R="$(dig +short +time=2 +tries=1 @"$IP_ESCUTA" "${DOMINIO}" A 2>/dev/null)"
if [ "$R" = "$IP_PUBLICO" ]; then ok "Site: ${DOMINIO} → ${IP_PUBLICO}"; else aviso "Site: ${DOMINIO} responde '${R}'"; FALHOU=1; fi
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMINIO}" "http://127.0.0.1/index.php?p=login")"
if [ "$CODE" = "200" ]; then ok "Site: página de entrada responde (HTTP 200)"; else aviso "Site: HTTP ${CODE}"; FALHOU=1; fi
if [ -f "$DIR_SITE/data/ssl/estado.json" ]; then ok "Agente SSL: estado publicado para o backoffice"; else aviso "Agente SSL: estado não publicado"; FALHOU=1; fi
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMINIO}" "http://127.0.0.1/data/acesso-teste.txt")"
if [ "$CODE" = "404" ] || [ "$CODE" = "403" ]; then ok "Site: pasta data/ protegida"; else aviso "Site: pasta data/ acessível (HTTP ${CODE})!"; FALHOU=1; fi

# ---------- resumo ----------
echo
echo "${C_T}Instalação concluída.${C_0}"
[ "$FALHOU" -eq 1 ] && echo "${C_AV}Alguns testes falharam — veja os avisos acima.${C_0}"
cat << EOF

Próximos passos:

 1. Na zona DNS de ${PAI} (ISPmanager), criar a delegação:

      ${DOMINIO%%.*}    IN NS  ${NS_NOME}.
      ${NS_NOME%%.*}   IN A   ${IP_PUBLICO}

    e APAGAR qualquer registo A ou CNAME que exista para ${DOMINIO}
    (a partir de agora é este servidor que responde por esse nome).

 2. Quando a delegação estiver ativa (pode demorar alguns minutos), no site:
    Sistema → Certificado SSL → Emitir certificado (ou instalar um certificado próprio).

 3. Abrir o site, entrar com o utilizador ${ADMIN}, e em Definições:
    preencher o contacto para pedidos de remoção e «Verificar agora» nos servidores DNS.
    Em Protegidos, acrescentar os IPs dos nós ISPmanager.

 4. Só no fim, em cada nó ISPmanager: Proteção anti-spam → DNSBL → ${DOMINIO}

Comandos úteis:
  systemctl status ${SERVICO_DNS} nginx ${PHP_FPM} dnsbl-ssl.path
  tail /var/log/dnsbl-ssl.log            registo do agente SSL
  bash $(basename "$0") --remover
EOF
exit 0

__PACOTE_DNSBL__
UEsDBAoAAAAAABJ4Ql0AAAAAAAAAAAAAAAAHABwAY29uZmlnL1VUCQADFMe/alDHv2p1eAsAAQQA
AAAABAAAAABQSwMEFAAAAAgAmHhCXU/1udLtAgAAAwUAABkAHABjb25maWcvY29uZmlnLmV4ZW1w
bG8ucGhwVVQJAAMPyL9qD8i/anV4CwABBAAAAAAEAAAAAGVU227TQBB9z1fMmxsU7AYkQOWmVOVS
KQqlCahSVVkT7yRZYe+a3XWp+sRH8AFIPCCeEV+QP+FLOGsnbSoSKbG8x3NmzjnjZy/rVd3L7vXo
Hh1Npodjuhymj+jv129UWLPQy8bx+uf6h6U5e6E9uZKqLm0/4idMtdOVaMfUBF3q6w1UfBBa6GKF
I0vrXyhVa1aWaga0q5t1fyno01jsNZ5lYk++wQ+XQVriP+JJqv+fOYhQDg1vWCPONKZgsqgw90GH
Rqq28siTQ0dsAjBKFtrozQN719bwgGaz8YC8uEutLJBRhwEFuQrW98nHgZbitGIfq5moRPHJLjCf
DGJvRzslI2HWcxIaZ+i8R/hkGU1sJVRZH1wU4U6FFpLMHRuV0Obz/AUlD90K+GSwc55jrmR7PtaY
iIwsISj6BXBL9q4uNMYqD6jgSpuVzT6cjjE3NRWVdrn+HXRtae9k8iabfnxDRcnODjpnFo1R0b2i
cbafbgtOWy/Z0SVfa0DhZ+NZwSyq2EFxaNCq1T2RgMTmjSuTm2F2ujuMKUIzCkp4mr4f6yApjcAf
51EcOEOxKkKiZw4Js0GWUD9mAAISF+K9pS8yp71LcXQ8mc5G49FpWql+14Ca5zWHVXKjZp4fHZ/m
OaWUZGmatSzK+HmZ+s8lGtj2lwSkGZmQ29ZfQYpaMsg9t2Zrh0cH0Dg3XAEaYW21PN5nuzPtTBws
iErFo5gkthCzHe+McNQgYzirEGWN+LGSuwxalZK3OPEt0/DB/m35U1HaSWt3LFI76Xx8O5udTOOu
FhIsTC+4jGnqp8iqj0yCWP/usCEuq99Yt7CukHwVQg22SBdcI7d8xyeebINtUnGT0DnMudLtVnUb
yiYuMYjTAzJLba5o/Z0WTrB6wNOoZrwTdpKFJlTLH0MFY+EFnd1/bd0XdkpUvKLszp0TxMHeFHjV
vY0O6DwZPnic7uM7TAaUDPfb6/3sSXKxcdY14FH5puNWy/OLQe/iae8fUEsDBBQAAAAIABJ4Ql0s
SIovigAAAMAAAAAQABwAY29uZmlnLy5odGFjY2Vzc1VUCQADFMe/ahTHv2p1eAsAAQQAAAAABAAA
AABTVnDxC3byUXjUMEWhILG4JFEhM68ktSgv0UohrzQvOVGhOLWoLLNIoSA1J1GhPDWJy8YzzTc/
pTQnVSE3PyU+sbQkoyo+Ob8oVS/ZjksBCIJSC0szi1IVEnNyFFJS8zJTU7hs9GF67JC0K2LX71+U
kloE0p1frgPUXwkWdAEyFNKK8nNBEijmAQBQSwMEFAAAAAgAmHhCXTgXnm4mBAAAtgcAAAwAHABl
eHBvcnRhci5waHBVVAkAAw/Iv2oPyL9qdXgLAAEEAAAAAAQAAAAAfVVtbhs3EP2vU4wNIbsKLMtp
0v6woxitrSRCbcuwhcKFExDU7kgivLvckJS/mgA9RC9Q9EfQA/QEuklP0sflriUbaPTDkIbkmzdv
Zp5f75fzstV73qLndHhy/tMRXb/Y/oH+/f0P4ttSGyeXX5d/aUol3etCUimNJG3JsrlWqTZsyUyy
tLApxblOOdO0WS6ybLOz7SFH5PQVFxQf8lQVClj/sO3Q8m/i4lrJVFOhKZETXn6V2VzTRbci0R37
VxXCqTaU6LyUTk1UplKZsv9N0hPdIakKUAOeTFg5Js5pv0rZ36JcWpqqRCIHWPJMWYcvyNmQpxue
+CS9VspJJg3H1hmVOOHuSrb9F529Fk5AnOOo4iVORuJ8cH4+HJ1EW+TMgnHF8KeFMkxCHA7PhKBt
inqyLHsTrR3wZLkNiSNAzRnkTRwdyGTO3QNdOKOzXbDrgpjhCFjNlYvqmAvXHYNKd1Q6pQvr79pC
Taf+aquNBnHiOKU+KnJOFbM4Ck0TlQT+Vjvoj0+fquqKWSduo4izXwZnl9H78fhUXIhQ3Hj08+Ak
+kj7+9QW7wbjyyjAVJHIo6kpxWtp+32E6fNn2phLOxfQQWZ2dWGLQvZOh35reQpz50qBkSlRC4sE
4xK/2nkJXH/It8rFmz8mbC2mgmcYju0PxSZOv6BWmWX6pipVGiPvxFRlDkKFH7ks4wi15WhKiUYL
W2YAi3ofznoIPRWnxhKqtFEHn7quOtyQbavSi6bK7zKNx0mm0A68iTs14ba+8hemqJlDZIouorcr
LMIEtmWDWD0yFabAHlnGvRrLfyoShp49q1Jv9GvoJvCmj8eXkXXSOLSkjr4OUS7S6ON6noZgv5rS
vUfxCVherUJfWqu/nsMG3q1DfbNrq84NTyE09nKBWVb3wTbqBgZ8tLHXozHWbApZ/L18+afDfmKu
HzsKxpGSucxlTmz9UhdYClgEbIgpVwWeYv/Dly0PiraS8nMDYDRZGRmchtj7BBvlbaA2ssepEm0M
WHvmidGwHGfu6trNohAl3upUJcJJe2VjP4ywK+d7PJ4bfSMnGVObG7nYGG1Epme1X5AL1e5SBFto
c/fNjN0xJlzOuJojP9oYZV5fYfgs+/nmh40LN1bbpmx1Hg6+tV3fP92uYOLBNAsvx1QrmrGRqVwt
W5IxptOhTG9UsR8grHKVC4aSO5V7vrEqXMcHq0DcnDcOdiSt6x5Du6niNNQ/y1PpvJVuUUrH9Cu9
31W7FgsaMDveOend8Ti4m1VF4vM8MavhW3E8Ohy+HQ4Oxfnw5GDQ2FOtVXi2EcTCksRt58V1xunA
s7oA0R4vmKv2q+bxv3q+3Hm1pmcl1oOpr/n1Ljm+db0yg9B7fpKx666/sF1pE6XWfb55dcTFzM2D
TF5Iq+4f2uv/w8h0reF7rf8AUEsDBBQAAAAIADJ4Ql3WYs+lSgMAAEkIAAAJABwAaW5kZXgucGhw
VVQJAANQx79qUce/anV4CwABBAAAAAAEAAAAAI1V227bRhB911dMAQJLIkrUAnmqoxiuzToGHEsR
2b4IwmJNjqRFKO52d+nEKfwxecoHBPkC/ViHN5mU5MZ8IvfMzpkzN7451Ws9SDHJhEHfOiMTx929
Rjv+LTgZDAz+U0iDwPnF1YxzeAVsJLQe3SrlyFroV3SfkaFnVOHQwhjmA6CHaSFzzFj5DuO3MGdL
mSErX1toWGHMSdcC0y6we9iKfOva4hKNyNhiWHNgTiGkwrJDjh003OMIu8BRjmtpnYAcV0bsM7Ej
alpouK8mTKUTBnr400xDYLm42wu+pddGOVzJVFl2kMxHaNhPZhd4tlCqIQV9tGwNdFi2uALgatrL
aZfpTzRGbEhWR9Oa2BX1m2IHTI/QsM/0joDt9xZ5NlWKS5nTJTxMXwfqp++iArbftj/wyQRGFA5u
HpOXKKKtc7fPU0NtD3R4zjJHPW1Ai0zcGfFSC2uxjKXDc95cfuyQHaVwhcjkF3FUXA/syztroL7A
/xNnbTPNx+SVYDdJHaZzNE4uZSJSBVF0XQ/kcZ5FuUg07ZBqE+WrwPf4ZRjPmWYLOD3dbY5yM8kl
+KXteAwsUyuZswD+rSJtd9bZdMpnk0m8W1parNCOKuNmbZXm+Fm6k8FD36PMqaVpJz7XaWv/M79E
Tnty5zWxZsmTNSYf/aC+5fEojKKryU25SRf1mUVrpcq5wRXm1CwOuUx9ZwoM+gYpDaJR960vgymF
nDi/MJnfJimoYmrk8OrQ3+WTyGd/h7M5m4Uf/gqjmL8P43eTC8p+Ff10EsVPxP4AmFlsoNEIYvqf
LIUFUTi12X51VH8Lfq6APj7LjYJiI+AOv4BWBjYyJ7PgBPIiTwTIjcYUNyBAb79SfAJSBHFrpKm8
O3Pf8FQii5xrNFKlMuE09B9tK/8BEuGSNfjx2qhP4jZD8DDoXKVNoUyZAp9d3ER/XIOrg/4dGJXX
w5dvV+jeU26pxH7Qem1L+oukQXV+8+Obe3oRtM7XzmmqltUqt8gTlaL/+tfXbYXLBm87uSqGNz27
DOmw4wpe0Hi10+5pmt0Kaz7LOVG3vNy6rlT7k+as1JQczcQuSrzpVO98chOHNzHRk0fSy5MMRd0S
T7q9k/iJBkncU0yNn/8AUEsDBAoAAAAAABJ4Ql0AAAAAAAAAAAAAAAAHABwAYXNzZXRzL1VUCQAD
FMe/alDHv2p1eAsAAQQAAAAABAAAAABQSwMEFAAAAAgAmHhCXekMyfJ/FAAAtFIAAA4AHABhc3Nl
dHMvYXBwLmNzc1VUCQADD8i/ag/Iv2p1eAsAAQQAAAAABAAAAAC1PNtu40h27/4Kpo2GrV5RTVIX
Sza6kZ2ZnUWAmQ0wnQABFvNQEosSY4pkSMqXGRjIR+QHFvuwT/uYL+g/yZfknLqxbpQlT+KenpbJ
qlNV534rffwQfPenL9/8EDzEk0XwP//5XwFtu7yo2iCtgjXZ3FdZlm9o8OHjxcVtU1Vd8OtFAD9h
WJKH59tA/FzG02Q1Te+0d2FyK9+R6XweGe+KvKT4utmuyXUyn4+D/n+TaD4fydHr4kD7VZJ4ni03
+rtwVz3Q5hZXWc/jm5Xxrq2yDidf0ilNs7nxbn/oGODLJSWrTazebdVqOG9FaZbIdxvSpP1eMvYj
3+XlfT/xMr5JZtOp9k4hI7icTmc387V8h9tQQC8Xi5vlksh3EkliLzNKqFovy2nRz8um2SJTZ09J
uWU4Ye/Ws+lNsjbfCcxcZmu6oepdda+fPc5uyCzt3yls4l4W2YwqOjySpuz3uSRzEkX6u54OWZpN
UzWvIWl+aMOCoTxJ6ifzhQAZz+wXYbvHd3HUv8iqsgt3lDCUvPvnQ5fl3btx8O4L3VY0+Nd/gs/t
c9vRfXjI4SMpAQht8syYv65SxtHvvs+3XUPp2QD2VVkhgEPOPrY12VCE8f2P8Fv4E90eCtIApB9p
WVTj4NuqbKuCtONAjb67eLm4+DAOPtzermlWNZR9JFlHm+DXYF09hW3+S14CxtZVkwIh4dFd8HKx
6/YFDAgf6fo+78KOPnU4koYk/fdDC8iPo+g9DsQzChHek2abA+EErdgJMrLPC0DCA2muNayMtCEI
FuDNJfKRSwH1+XaHy0yElG2qomokHBAAAQE1yrapDmUq3623Izw0gd0bc1BIR3cBO0lKN1VDuryC
3ZZVSfEg5JZJPkxzhgB02uC2GGbicbBL4O8Uhg6dETkHFusx4tl/UNCuQ9EBOjEKhJMopntcY1Ol
9Ah0pC7M17A3WS5xposNJtYwtiZpyhaZwBLBZDpnwznJpXQsakb6P+/yNKXlz7CBNG/rgjxzJAX/
kO/rqulI2eGw26zagOg85G2+LnC31aHjCmZaPwXAh3nKtfF0Og5WoIbjWTTGlWE3YmgItqClQOWE
r3wxyTdVyYT01+AxT7sdvEKhDCQ78N+ygj71hGOTQIS1SfFCnxSLg00QbwL6GahdJZwoE6Za+XSD
muz5iA1p96QotBUEb0/FBsrqsSE1P94u7yijPcWj4HM2pME9cwiMD0mRb4GD2GN+2hJRxwYo8vBn
DIUfP4DykD/BDxXwn/4AzS4K4KRgb7jgKjjbJhcKGj+B1O/hOWwTjnvYl8AicdbgXz5mn5e9nEbR
w84VyUtm0WDXbDlAB/I1G1VXbc6lq6GwRv5A78y9IJGFloBPYZo3dMMn8N3wd4qv58BDwRwoHcyU
fhdUulRmtd9aaFAQXQhHoYT5nmzp7YU0RIhi0oRbFBdadtf9VGZYR0FcP42DrgFVXpMGRuCD0Xhw
/ipK6XYcnAbG2RznrBk7MPJ3j+Q1TE2DCfsnBA103/Mrw0SgRtZ5t9nBW6mmyKGrUFftyVMoJGm+
iATv6lN2saCig2GN6zcF2dfX0xkeZzqZPTyOg3mkjmJp+WipzX8Uj2/Q7LtLA15KnfvXRbW5v3O1
PRPMkbP5WjsxOglBZJ15NmNnFvC8HuXN0lQSSsXwhTLm1x6FMLcATKUK5BD2xJXOXiKYUghBgexB
JjfAI1SIJNrmPHsG7oZnZWe+VLKC5wuSmcE14BvsNQXKrLuGk+kysk4Iw3eJqecShgWHhNasz4HQ
pD0ZZowKiY1EGDxhBkwNBeeh6yrw1uKlZywpaNOdOHbdlf3IrqqV+bM06I+k2RBbg5rCZanhkNHJ
S6NgS2ChONHYS4mkBrJ92PakmC51W8Z/swwgn4rmQt8N38aA8nTkb25DarumKrev+zg6/RM//Ycd
HX1Bulfc1D0XAC7vAIcbU0ySVyVTuV2cqtL08oWAAypGdsXYScQYG59IbMwZJ9jqxeGMPwCGDt2h
IUFKAlLDVsnXv339a+U1t6SuXdq4BpRpALSSa9I4hhJEe3P/zGWZnS1WIY7GEOx3ebjZUo6Q62xI
sblmiwUh0wFCH0tRjLlGZP/08JXqQBnlLxMVLaHbnBXVY/jMTciQZ65bWdPz5O9V+DbymO+XHi+c
lh4LoHYp9p8Iv9KaOezoK4mCrZ4uSkyo5VIwM8Rj15J8ck+ohVjsyRSNE/4kk7nxWArQQoa+rxiT
C33t2yxv2i7c7HKmO8UeuEDMtI2CErh/g5XptZh1xEgc0UvkfsKxoyyXo2NYcCJG7SSKrjrr+RNC
i+FI0NbLEvokb0OyQUfVWsEIL4dmM6dFkKXKwu65ZgEeE9tYjdwARJkQ60VaD7xcvjnONT1tgDTL
AcqsViv15jXUxaMTaDgy6KJhTj/l62slLkIhCmOeUY86VKJC3UV3p4osAgJp6LXs+ey/8OvGhIk5
/m+aCP6sIYxg1jLn9tS/cxi4aQ77tS909IabBsHnws8y1kI3/RT/zPIFEoUfRraqbF1deMS7USF6
iEHtbcBDW8czZSNomfJt5xA2W5TQvakTCOJYuj4O1O3C0sfpHLGYjjXsk0plHTFXpjjY6SnENZNG
UIuo4AfyYJtD0+L0usr7U/kyBBcCV6+ZMDMGv8lW2brHM8+y9L6+4WAqZxmHhrBIm7PBygFl9sOy
tE4qiWsUDyOLg6Y0I4eicxbyqnCdOjgBGTMlHR3Kw+ir2rud6adrO9Id2mCSsmhNoGOlY2PlOdsc
QyN9f3AojNO/xb3YwFH3VfdITmuz1f3IN5Y2TdXYY3mO3Tse0+EObHw44kJ8aGHne1oe0A1wUy4I
kQ3h4ZBOVh6TSW4gD6RzlaUQ0T5tBI831CeiMpiJbCntn3jQPJTiZbb21QQEY7nhrELaVHVaPZaO
n03WLZiJTrjSDZ8VaX639KHfB79DBImt/AJyn6JqT6I+PyYd8f6YCseLMzTRMdXDkvg7AkdRji+a
Hm5S49U4mMXjYBGj7V6MrCQbjxheND5hDFvTMtDw44mF+rfkzRbURQl3IJMBjjCihHb/uuY1rKNB
cnJE0ciU+XB0oMCcoEkHMsUia83E7rfK1MKRKdc3MQzZKXatR7COIS0t6cd+mBwzaYByiGFJIbPa
+zxNC86AEh0nEMZTShmmlYQri5jD4LVKpr2IroAV3U4zoyhTQruaUjds4lQaUgc4m8kEofCgTHWd
SI+Tu53nha7SKGYFaXe09UCO3gA2FokVby7OyqX8ESzSjrQBBd3adF//GzZhp9xQIHQkMgGxDsCq
FiJAGKhggFLek6frCGKMSZw1I+0B/mp5tm3X0G6z40mEDgh2blagpxrQVoj6W/V9nxkxIgeUHgTA
3P4TlTHbNByo6QbyxsztDNe0e6S0fCXsmcmwJ7FtuaK6qgjy87BCh7VxO5kc9x6kHtUGxiQ9lz+T
qXzD/2NpFTWJV6u9e1/qlGLQQeEUoLpQHrzhjhPjvPgmT3oovsgvUQUWz1QZKTseLRegb1FW/lqB
Nw3/ATX/48D6ajikjIKP2LxWbpO5u9uAV33f4nKdUbJDJcP35ZJCUgFJ6HNVlX8V9+iSh2TMY6QK
nOKMl5PkZkoIvKl0b48nvP1lLiw/joM5FrkWvUvo+p341Ay3rfTrTKVfxWA3d4716AsbA7okRMdT
5MvFUPYATfu9x98zqkJq54mu4JljzLK/ClAIfgK2YWQYsA5kk5KRNp4VtuV4biSxCnFPh9KeWETj
I5Q43YGTsemqJqRZBh8YnLAFnwMToHysFJ8/Nl//koER5zKzA2Fi0mwnTJUpZ0NOxQ5HBWlr2ETI
vBI2Igo+QsgD2O4FT3RQ9EuEwtTJs+s60zpufOJxBeDngqxpoVDshs2MFTgTOpkK0Y9QbnbIWTJz
wwE/nQjYmwIxAQufsIftcpHZURLdjLTRR3jISNRabDOZn4dJnjLQTyvgctb6hjQNuDPIWGvCdH+R
t6qwxbelSavmpp/nYknHhy1S5B7/6DUvKPZ5QaIEdiTJt+wXDiXtHVvCCds/pkWR123e3vm7X3yx
hFwDAg/mfEnxumGJGa+Zkh68PyXlblKskLEUpCPcWn3u/dCKg4sJ0A8EBvkbenzFcmSgH4BdCBp2
tOvd179j7U8wFD5odW0v05qnJ78FjM8w42HYYzzFKTRYZE1ayhqRjvqLccxs/Hl+orbhW4hS+tqW
BSHSjpdqPRgOU4khqWk2XXJ4aKbqndz3I+Xz4442vvarf0HJIG4s0xFQ+NLYKHBPmgFlI+x+DHFW
OFJB6pYyirJPQz4vh9LtBI31sxQ06zxOirfQpvJovmSGRVw0HT3RT6MvS2YMZLvFEVLdVcQNCa/u
pAWG8g46ivSSKRgVuexAJRWxd6tihh5Iz5o6DINhJQiRV7RhMLe4a/Q53SCfW3N8uY3LbJkRkf2X
2+RNhtoORdfhUMvhBhS35FY9dOlbJ2S3GHcJBwVkQBgvJmCguuehfL4mny9i6KQmBkeo0hsHh1Ww
5sSi1ZHClNat0/OeKvIleuGDe4p+7hNluQZOnFUnFy0cZfIdmIS8hFiochXKmqRb+vYCmjodE6yh
jLxWJj6rc2FItNmmw0L1GHlLNgvZUhCoGTwbF/yWJB4HxAszfkDifoINRJZtOABeffEDUBcVbBCq
OiOAlPQA3k1xVspTCo7JId9Xzf5QfP1Lk3tYRDbSneNfMi/LKVNzSJ9lH6YbWHuMkSdnqyDxpukT
5EL2crFpYVM9usfRvNOhhJc3b9OD/Nz3HIp8Df5RWRp3ILbcPKrRUxitcjoXeVkfuj9jt8end6hb
3/08DvRnNWnbR5Ay+3lLSbPZ2U95lgKeGnCxFIojwfcCIo6ZDucxk14lYB6EVpPOS1DJ+UAWf/By
heBHo5bQa73LdEUTSs6oLZhOYd86pHfGyfbm/lxBQzlHSLvutDCwbkaOEMze1TXgEwJMFXtZRph3
VTqt38GhKa4Rv+SWPfjYPmx/97Qvxu+n32KPJnws209Xu66rbz9+fHx8nDxOJ1Wz/QiWMcLBVxDc
08dvqqdPV+ilJzP474pFjZ+ucCNXIgz9dPU+mfK7WldGZPrpKlEP8IgbUn+6Ylu8ej/9A2yjJuDd
pZ+u9otgFSzwT7i4+sjf4Q7g07uRcbSGAjJYeCs+Gm+1xBtzCVg5UZpKp/1ctj0zduQXQiQfyt8k
1fjv+jURUQVRPq1zVce5SGCVOvHPVBY6zZxAPNf7vlnHL9uj7RxRksXZyt7FZTqjEd2IdPCO+tL+
rzbAOPk1uyLGkwkIXG7tSCWJbHANL5pwk3jC8C0FChXIcwh8jGWQ5/70qZkkc3KBsxO9IwOM6thk
2xnsPjrWaKTQQdJzzZ2JDJgfDhSdXk2qWCmVScJKS1pJaLDKZC6t6TyjWfjGuBUl7+JZkzVLNjyS
X8l5A5peyQ64i4iWe35yUBKZaZUZ3VSpxEvwZDAp5TfpHJgyA0K8eIytxzGxNO7c7A60ypyiALwV
nmQgTOoXlKVkTw9KwENN7gKf22cgVE1IH2B/rVYVF+tKxWOGtbPE2B330LXtSygsoBwi1syfoHPu
I+pqwugUFgGrHuXdqFjAjkx8LibzkV9xTvt1zumo8xYjFiMJarBTmBsxjytstfBgcOlt4ImWQt93
tO3klZ1hUXGkwsuzLzq4XgR653cq2RV7D+rncCCSOFL0l3jWpkvW892BMqOabyp/Q8Bw78xvvShl
9pO6vqjZWeOUvc9rr9FaRP8vGkRVns9hYRZyaw02wz0zp3e3YGNN3YBz3Dyf0xWvTTvSkNN/HcNI
zcKAeniwL9xWXpKa78+TpQs6z2I1cLurWnslvfvJr27cmMjOBCnYJzQ6yT3vLfPP+rvsZk2PZrPV
aqRRjSt1Deg8sWEsjqlmhMFKJHaS+oWlozb34nLJ2bfj+qMYattMAsoeqM9Bfbsj7XW/4khL6Ie8
dSn09xz9/iFvPXkSeYnQSmkvPcgwmzEHcvAc3qHQ9rWQnSpWOjkypqjIQ/eqFf7ZmLA9QFzQtqdl
sC7j2XwzXWnTebfxGZm0y+UmIUmkgTgzBXa5WM9k8wU/pvZFDTIncfQbGHx9HHiznvWD90RLhnwF
Rwu7cmNU1tTFLliBZwzPRjabyhB1PpaQaX/fHUBefsHrhWgIsQh4qIsKO4WOuAADSTCW2fb5yzpI
TwpMeQF67gl8bPru56FM0yuWc2U0+3rSUv+/+Sd2ZEye4XeeBFZZ1fFdkA4/0W3edqzfqqppI+lx
/eXLDyNGlaLa+r8LRb9eyrODVvdVf29ysJR27D6lSlwsAAH0bO+D5/A/xpO5+10YrqtRN7x2KV5V
2FcHMer9bcD+CfEJ+94ZQNkX2jzkadUAmr770xdev4ZH9LWeCGXU3tAa8dKvwVoiTKUQnVo0NMAc
u1EZ2WNPKFCzwaJj0z7Xa5H1azfLLQ4eMKiOPfyJtnVVtvmDc4P5H/c0zUlwrcWAcYxfCDAS3H5e
4y3vs33hM81eRUNlqDQ6G6jd+rEaqV+Q1zx7XEXaFvUvPTny7SZqOf0LS7T6WKLqjPpOI2ua/cUa
M72H2hgpvinCOREfY94EZ9pBZQiy/ImKGwL4k5fsm3Qi8SUeUvHgj2qcnGkPLQWFP57vcvHokcjp
SXYfaECZz4w2RbjPiPF/uw7jaP5+ZI0SB1MzgknSBpS0Qp+99HQUeBEXVRSW9MUkInU8hqhD8fKG
kWrhiFQI1BpNp5En7jcC8tnozqXd8W3qm3Dv1bDt+u4M6NdCFH/IK6yuPbeunetVVCVNfXrVcOD9
BXGVpWPT9Tt7YxPaZ/72Fpyea/222og/kbfNRj6u5xqBrwtgnfsIwlGO9fhH1nBkLaLXKqhdx4Gv
8dtwuO2GDEPp/JbuEC+gN3SI6HDszPQJmky2rXp7UWdJZA4UrZzjwGkZ7b3kaWSjekCBG1vvexRP
y5+jgRHXXjTjZih78EQyYMKwoelhQ8ECVTJpi78r62QpiNxMd7xc/C9QSwMEFAAAAAgAmHhCXUgh
FhcqBgAA9xIAAA0AHABhc3NldHMvYXBwLmpzVVQJAAMPyL9qtce/anV4CwABBAAAAAAEAAAAAMVX
zW7bRhC+5ynWl1BKRSpu0R7quIHiGGgAJylqI5cihxU5khamdtndpWS3CdCH6AM0yKFogR77BHqT
Pkm/WVIyKVGx26ItYVgkd3d+vpn5Zjh8IJ6+OH9yJhaHyWfijx9+FKmZF8Z6OSftjciMGMv00kwm
KiXxYHivNyl16pXRotcX398TuKLSkXDeqtRHR/fCq+FQPCdd8vHSq1x9JzNjw8pCWjHnpWMspiVr
Sb4tyV6fU06pN7YXJZBnY94U9Y/CITURPX5ea1wLGnsNObyyLeObTHoZbwS9XkviC6cSmWWnC+g+
U86TJpxIc5VeRgNx4x811fFFifOm+MqaQk4l7+k1pK5tMgVtjEpz6RyrSLyZTnPqRcrFvCHaOsgm
OfIjDxTHpcdGaZWM6aqQOqMMZgWxj0XkbUmR+FxEE5k7asp527jfQPu3/GS4DyoHjPZSadejxEs7
Jd/f3svXlq+W5max39e7+bvrX/Dxr3p7SdeZWerb/aUEW8Xx8bGITl0qC6j+Xz1t+TU22XWHWqcy
GkvbqXsXqbft0sylJytzQXNBqV29d6IgFJE27l5Ld6uwRnm+rq0qo+PaBhRYMjH2VKazBkNQ3gSR
8julI47s9XxdRlue3/hY/95qfZob918bvydsLePXIXpFVoFy5UBIUUjrlQ1UbM0SlDYQIFx+77wU
7M5QkPOrd0Km5NzqtwXlCGYuxZLGG9LlUoZRH+LdekuTdden7t8XS6VRSsmEfDprIhNe9KJgRzDA
xB7mgDGu/ONIfCSeItMSbZa9/gDopECZwF/axGBTS4AvtZRBiUIdYMHMlY8ARiudEz8j3QiOZaAt
+dJqYRNzCWq0iacrjwhARnR0mwDfVd7ssU/gJ129nPSi0Bnji9Pzi9N4dHJ6fv4SpMAUER/eqD9q
lNr6YrxlE2l4CBBOc+InYKUWXfUuq2R5gd6Lw5HMyXoR/sdkrbFR15E2uViTM6LV2W4dSiN3v7x4
fsY6HqFvGz39YnS3bEoeDesDYoTBAGmY4Q/N3Q14cBASLCJzubDSxRCI9VRNrMzwnoQR3lyii+EI
6I9njNXPq/dmIAqDV8hrrIB6raUpTuCtFd+WMucshQHIK5mIJ7nBs2JhVa6J1U+ust0JWRTDgRgr
PWRr9ERNcVN7JOw4z7TLhqK3gLxnL84vRmejr5N5NuDjEHSYfNxPOiCuSwC4wUT/hMAU1JODzfuJ
ss6fzFSebVPwVgam0rcIBjm0y80jD5cxLwVohCy9ma/eeTCBIA00eCabITblXPJIYOt9IPG0tM5s
qp0PfqDUKxLkTbGliSU3e92sel5o1gdy7ELNyZS+bf6aE3KThnkIFJcbmfWY1AaiB+Jy9AwJz/KS
aStRdwyIwA6HD/vizRvxSV88wP3DhzvonHBU7bz2mvHgCRPOSwytMFPX+br6BXXD/S0zd+wHleBY
TeJ0JvWUsu6moHRRtqgjzErhLe+ed/PCzXpHE3HlmBnv1gmlErKQeQlqtWqOAByAi6rXGU1kmftX
zVVw9kEdoNq9WkZHJHb9j/qdsx4lhSV24GmlcXsE7pg7Gm2tHT9kMzmmA37+HbfKsmwbgqhunUMY
z1b0ukNWh+WmX/2zMGxDGsTtR/TfgTGke6BecLaWzKeq5oLbUHPhocItHLvuhs215x8mlaWVBUgF
KyGXOcHW990EU8mPcU+tL7AKR0jrLhfW5a51Cl27X5utTTOzrA0KdVHN76x6i8dZVzJTWRa+zQ74
3O6XWygOLIfNW/6Ete1+uqlKdqMqLYsZWmGcYatYSTOQRw0+7ZwmQ+EhA9n3hip+7HUWU6FgNlhW
YtpYvcOMwTnhrdRuQnb1q06VvCv9FXvSYNzEfXzXGXgH2+rrcX9HGneXUHGN+tkF/aD+GN07hAWV
mAahsNpa5weaS/3MqydVB9/NhMxo+mDyrTeanCM9vpmpOj4Am6p45Aphy0zHpLG3zY5bQxuUhv56
+OmmQ3bk2BorLRdqKoExhktVjI20WWOaV+6cMDlQsO+qcyjuEJAsrfJ0weN2OFUN14zatj34bsIQ
uCu0jkJFRtvkx9cmT+iK0hMzn6PVI9lCRnTt1nQ3Cn3b531/AlBLAwQKAAAAAAASeEJdAAAAAAAA
AAAAAAAABAAcAGFwcC9VVAkAAxTHv2pQx79qdXgLAAEEAAAAAAQAAAAAUEsDBAoAAAAAABJ4Ql0A
AAAAAAAAAAAAAAAKABwAYXBwL3ZpZXdzL1VUCQADFMe/alDHv2p1eAsAAQQAAAAABAAAAABQSwME
FAAAAAgAMnhCXcTaEHhfBwAA1BMAABQAHABhcHAvdmlld3MvbGF5b3V0LnBocFVUCQADUMe/alHH
v2p1eAsAAQQAAAAABAAAAACdWO9u47gR/56n4AlBJS2iOFvctUVi2ZfNefcWSJNgk7Zog8CgpbHF
iySqJOVsrndP0w99gKLo9+6LdYaULNlxvNk1YFskh/OPM78ZajiusmovhbkoIQ3806ur6YfLyxs/
ZL/8wuCjMCd7g1ev2PdLrhhXij+y/avTdxP2atDNa6NEuWD7Z5cXN5OLG1rbrzUohp+YJbVSUJop
zQThyd5+yZfMLVlWtz5O+HdsPGa+j8s/yxImSuGyBmOQceDnXJvpAkpQ3EA6BaWk8sOG9tSwHbTc
WMK01G94SoT4NM2A5yabVkrOcig0aWXVOhflPZLM6zIxQpYsaC1TsjZwsDI05zPIu6FIZNmN4KNR
HLn46EO0mQXEOTxu1/+xR7bvc5SwBPIBuSOO40YIQy8woSO37rNj6xS3RQnu3LZlCy1Gjatjr+IL
8PqbFZhalcwfcpagh3TsIY8oR3t9drjS5pD5HssUzGOPprOgVnnghIShXXXUpAiORr7lTZ9DRk4I
rCss5VBXvBw5Ls5fbnqwmm8cZSf5CPX8lU7BaXIm69KgpUF3FOhBgXON+zStprMgjEaVgoorCPzr
yfnk7IadXf7p4iZ4FbK3Hy7/yNAdSoBmf/lx8mHCSK7+ez51UoIwPGnZRSP4CAkaGtz6x6V88Fk8
YvgfhHfhmgsD1CK0G+ZgkuxM5nVRUgT9GtLveDT8JpWJeayAZabIR3tD+mM5Lxd4Lia6uvFoDniK
fwUYPJCMKwzf2KvNPPqD106XvIDYWwp4qKQyHkPPGnu4DyI1WZzCUiQQ2cEBukYYwfNIJzyH+DUx
McLkMBqOYzoBl2h2yr8L2XjE/vdf1qy9O798c3p+fetj/r59/86/u/Vnipdpk5M/XFy/OfftHvs4
HDjOe0MKH3RLjnYpQPVKSEwbP5kxlT4eDOaotT5cSLnIgVdCHyay8L5srzbciMRuZImSWkslFqJc
Y6LNYw46A3iRAoNE69+O57wQ+WP8ViyMAjh+WGTm+2+Pjk6+w+/v8Pv7o6PfNDSXeDTCOJL+cip0
lfPHWD/wyvuMQph1YPSAV9Uhih8vY+d+Qtw/Tz5cv7+8IB8Tl0ETHTOZPrbpittoiWuRQjtHzzOu
PCbSbjCywdrluT3KVgcnkrLarzgifu6HTigtWMppwdV9QJOUlY4XwU2HGp7DGpvTsXfBl7Dgn/71
6Z+SVQhwiah43ihhN6eivzlaIJqgJe8QnvPhABd7pGMHbYTCK/0OmH+1espkATYS9z7H/1xoSiFY
KL5TCsEDT7km7pPe84yX9GdRrM8+IWDyGlybF2Za1kXQB61wDeasrs/Yp6SBhUillXe1NtKZgDx9
maVvsRoiUpSG652WGkCPKOJ+Y5/Y+ysrCrhKsl2KZuhKzLhEEvmPOPj073bklh5fpug1EkOx+zhs
H4LMwbrhBzvC2PqPGzc1Xu/SVmsbKWegjJiLhKeSXV+f01Quk/tdO7mpeS5+5q3002bcyU/lQ5lL
nnZchgPcThlr8xIfeqY3CRnNeHKfKll5LOUGa3QuNUTN4qjxxtrGAuO9TWNCAmykmhUjqy7F7fqs
NkauIpSqbzQzJcN4qOnBY1SIEAQsWaOBkQvEwlaFtWw+nSmh7G4HCbao+zT2HSQ4RtvTm5qOiBTG
M+rpuEmWqLqYeeuFyYaIK0wb8eG88PrZOoZg+bqnzkZw9cSi72xTJUu9qRy1wEzMsVNre89vYtu/
HfejZUW+gtZK5Dmjn4hKVK2pb7O96Ra47UW2g1xmjWhpWskNGvdhJ5UIOA2gIIXExoAhNV/h87od
kGuwtriW92tseOCq/HITRFHlMsU+7IRhsti7wjRx3VGji0VwjQ15+Bkzsc/AdqdgTYNOyLbb1uYe
EH/1sb3U5Od1/hseCcNOjS2wtKkdCn+FdvL+S46DamvKGRRNg0dlKjWtk15kR4uF6bNRVqZifrJp
yRrTzpAlKI15542WW1ueRvDznCh1EbmgBQ16RvsHxeCvzvStHNY8+rKzXSHeWqVxV5l+MWrkPfVN
D2/ouhs5JH162uuwbT1l6Z+D7BUzh9YZ15Ws6gpdo2poGjL4iDqlgK3gnGOYbRH7xLF8icxV69Zi
NsU7qkEkrvCmTqN6hhOBvcvf+vRLdxL/7oAdHbDX4bOuX5PVIvcmk97mzu9JBkslbetFE3Y20sV6
2V6xf1KNtp0DlV4q3B5TkrLjmSNpQqajEdisbIkauoXxpwFzD64LOs0NpT/DJpgvFY8q6vqfxMmX
CMzlAu/f6BEse/ZSmmg1nxp5DyXdTTcVachp+gZUIUp6PwNaY3++VY1t5XajiHZDdzMB1TR7Dgr2
5zm9M0FvZ0CvUlwlnecdDPePo6Hr9zCWy1wq4ElmdzKu2e0+pcEB2y/04u4povdZ4o1XGWZ/oybY
aK/DROdfB6WrpgN5bmk1VsjW6HLSdXmdBzbQz01Sx7Zqb9w1fc3AuHs3tmJJe6hztKyHOlGiMkyr
ZO2i+NOOeyImj91ETOimaC+O9o3D/wFQSwMEFAAAAAgAMnhCXdoY5RAsBwAAtg8AABEAHABhcHAv
Ym9vdHN0cmFwLnBocFVUCQADUMe/alHHv2p1eAsAAQQAAAAABAAAAACNV99TG8kRfuevaBPqdpWg
X2D7UgLhkDPEVHHAITmVFFFtjXZH0pR3d9Yzs1gixx9zdQ+pVCpPV6k85M38Y/l6pEUSYB+4bEsz
3dPdX/fX3ey/KSbFRiLjVBgZWmdU7CI3K6Tttmt7G7gZqVyGweHFRXR5ft4PtilRJheZDKPo7cll
FNUgtir156PL3sn5GQSDduN1wI80mxTrfKTGzfl/Ddiku39SbJRINAkqhHHKED7LqcyKVFOOQ6My
qYyg0qlU3Yi7f9z9DAHKyzwWUOdnbTm0Trny7t/QLbQh4UqxEP6PtBRqi8dj7fDZ3v1CzogbmS28
aSyMsTu1xsZWPBofq1RSl6poqUFB85Hrwd6GGlH4QtloBPmwUqzV6O8bhJ8/xLqYhV95ZMUwcLrX
39u43dj67vzs+ORPcMLIj6UyksJHdujNvQ51vubsqh1Ok3AyQq5EmSLJQPdG5zKy0oULq1dBdRoM
6M0bCo5KowvZPFV2qHN+IhtGKncSFZBGMo91ovJxGLzvH9d/71NdOb3mlCiKZqqGzWS4gO+rUhOZ
FtLY54iq4jlSHM9z5OIJyvBZZgHvs/xLchtPZPzhObJO2A/PerQsOI/mOaLWpgsxJsuRMaDDSDih
bIeKu5/GCjSzCiUCesQ6AxNjUVqmnr6+++laptsEtlzLG0oklRl9/te7fv+CXrVan/9HFldyWqQq
nlOz4Vlx8e4i6h1enNCLbpeCOFVBxQrUWSSnsSyc0nk0EXmSShOOwGY+oLA/MfqTGKKmt2StQ9da
JQtN/pFw3kSpRrW9Pev98bRDAUId4020LmtD6HDo8+MtWT/A1ffSWjGWob/hSFbumDzzi87K6Sm3
Me5oldmtzI4JZHz44orEBISARHAea2NkyTixs4SnLAoZHa5Bh5TJnDW59zDeTtAIZVRSrkH0sbJO
M8bSpwi9zConG8HSCkPL3bnQCBU+obtCO02g7/BSnlBi1LU0QJuBH4nUytoKfOueErIEc9ZJb4hy
7qxOcgHIqYOn/L1IdGQ/pnwvnLoWDTrTdNK7yESOQMy2P8WdrXS44a4o4W3/YZebOVzzjyJGb/tx
hLck4fMTcZa5LwoAhFaUE4pfDIWVq5HSjz/SAy0jAXyezp6U/xVkPBzMcTkuEYeNjYT/fiYJi8zx
k80GfcdN1mSSczgGmBg/CA9pnWBsIY0fobymQigHIBXjWFdTLdGmQgOIcQ4glClbocXWlRNrSK1V
xYsJIgW66OO5C2sPQ5s4V0QGlcjhRGjYMgR9V+rXC/knwgARwT9X72MB6MCZqWtOXJbuEbdG8Ldb
utG80T/2RcYTTcH+i0THvD8QKx7s87+Uinzc3Sxc/aK/iSMYO9jPmALVs5v+XdxhlqfygBsVff4v
eaLvN+eH+02vGKw5DvruD3UyQ/ZnqexujhBAfSQylc46dob6zuql2rYit3UrjRrtZWJa/6QSN+m8
ftkqpvhu0AU77db1hETp9F4hEp5pnRbtvMR9rFNtOr9pf7vzcnd38wnrk/aabatuZGdnp5huHhzO
/V+rJlWSMEZggTGIp32wXxxw92GU0CtiJVIPSegLcpuOzvrRD+/P+0c9VPRiyHqrzQJ4cOAMCwO9
KI9bv0P8SiPGKOA23iM9NGos3N0vRmkKuTeDZKjAVMcinWgLD7CZCRQCkLS1jTlVcA6qgG4O2HxC
2XjC5uNagUaGUitSEWMXbHb+lvxuq8l7IP5WMuFW1Du6xI54FbAP0bvzXn+xawS1qvH6ssbm4mbL
xWSkTSwjrmYbDGr0zTfE+5f/Hi6+5hFjC52561fBfRx+Gd35ttHCnzZ/uep02oNgsI2FsJRrnKmo
cApdnksdzyDbaTY5UV91f/3+8uiH90e9fvT+8mQh0Qxqc4PbtNtqr5BITpVb5O8+/mVwT3nX84t6
vY9SArONq/dkXKJPzDrEFY7+3N1tv9p93Wq1KrbefrkwPHzzHT5ZjNfo7ByR9PwmX1tOcGt5dvv1
/z4zq6eLSLH3DNOIL4Su7FdivAbEWn9QMuLiymx4dR9ekKqR5BU0oO4BtbaXF4Vwk8B/xAWQXLmy
HLoM5ldL2FYk+IRngX/VJ2BFG15z8/V3wamYLp4ePHTbYTnkuV9R6Fhl3J/53k9L9HGsUxiJKkGO
HtVxheZVUKoEFbya1S2V+F87kLrwFbgC7tce48tCUabyElyc49zeaeGd39Lr1vqigOnBO/3SJDYk
F4mYnXOzBX0YZjCnPjf3ZWE6mPv3aGZWGnD8arA+TyqX0RBkjhUIv3aoJPRc23v6ERAcdifB4GrA
7wWfhMmZqIf3ADseizk2pgdIN+gkV7FaZiLX18hpztvF4OF68aUYHkfdXQD0cNTdzgugIuJf6seo
YVk/91st1uq3R2d/rUp+KbQ6WJeyuba5Go0eil/KEfZAaeoXGss1KM01Wtfo1cr/Dna78X9QSwME
FAAAAAgAEnhCXSxIii+KAAAAwAAAAA0AHABhcHAvLmh0YWNjZXNzVVQJAAMUx79qtce/anV4CwAB
BAAAAAAEAAAAAFNWcPELdvJReNQwRaEgsbgkUSEzryS1KC/RSiGvNC85UaE4tagss0ihIDUnUaE8
NYnLxjPNNz+lNCdVITc/JT6xtCSjKj45vyhVL9mOSwEIglILSzOLUhUSc3IUUlLzMlNTuGz0YXrs
kLQrYtfvX5SSWgTSnV+uA9RfCRZ0ATIU0oryc0ESKOYBAFBLAwQKAAAAAAAteEJdAAAAAAAAAAAA
AAAACAAcAGFwcC9saWIvVVQJAANFx79qUMe/anV4CwABBAAAAAAEAAAAAFBLAwQUAAAACAASeEJd
4LQYE5ULAADSHQAAEAAcAGFwcC9saWIvem9uZS5waHBVVAkAAxTHv2pRx79qdXgLAAEEAAAAAAQA
AAAAnVltc9vGEf6uX3GWOQEYUxKl+CUjRbYVmXI0tSUPRadpJJU9AkfyRngzDpTl2P4xaT9k2pl+
yvRLv+qP9dm9AwiCdOK0mcoCbm93b+/Z3Wehb55k02wtVEEkc+WbItdBMSzeZcrsb7f3sDDWiQp9
7+DVq2H/9HTgtcWHD0Ld6GJvbW3ryy/FQN0UqTBqMstTkclcisEPAxGmIh9FYWLCXXFwdnh83BGz
WIpIJ1PZgXQsAogGhcqVEcpkKtBSm03x5dbaeJYEhU4T8VOaqGFxU7BXyUS0TEeM0jQSrSulsmdp
BJfFvhjLyKj2rrBSa+/XBP7XkibQGqtPdZAm1773enC08bXXER57s7U16B+cnL04HmxtHT8/Oe33
sNQyODBt1mPhlwr2SwPCKl5QnuVqMsxVFslA+d7W+V8vbna6Gxc3j3qXW2SrrvSj9StXcXqtsPfc
u0sie/RjnX5cXNDPv3mXcyfu1E664IDVcn4JPV7LWzBQ+oZwVK45eecRSzivPnmUi5sunWT7CKc5
urzHxxGf3I3Qx35DxYVZ2uW25aqY5YkwsxGcdJHuiG5H7HS7EPnIwFoTJbaAQBmJUAFB2DrRBu+A
sV2RioIFfL7TtlCELMGQ1WHawTruvgDKUlLG2MxUiCVD2igmt7/c/iPdFC9lUtz+MyaFaQFbciT1
TSpIcOfBgzpUrRew3iGVrD4JyU4sJLIik4mBRhILZChFy1rFluNXwpcwIrbr+tqba8uQh7IsNYvQ
p4Muo38J9e68uJF58qiigITv4WHo1r3yJlpmNh7rG4EN1d47gLzniSe4uY0qgLt42pzL4NGhjj2j
XxYR572HA/KjRzfi7JNHXrtjd5T2R2n4zu6uHHZnrR/TCcfyRljhnQddOAeDkUp8d4g23mzfx61Y
XOGsswTayEKHsmTZZM6wLWFoBYFCmPF38C/Zazcwa3dvloErwSp6SZHTheukUDqXscK/QAHeMhhk
NAEGaDG/lhHqZJ4WQHKYPlm+fp0YHaohiwAloS/zXL4TLVIGB91TtQwMECwcAsZprmQwRf2qBIQ0
EK+XDyotPpxpt7JzT2dDU8i88C7FN/vCvmZTC0tffCHqO1QS4uXjZXleqNuqxa7IZ2qvWvhYK1pO
gAttFdLDNMG93P6qXR6r2/+GlJOoB8EUQebAhpKSVGf3AbNa01nRSEYzHYX+q2enohWOOnQXonWt
ckMC+6KLMHJky0wyDtMWvWYoo8gvEVQUEa0RTh4CJzYG5tzDexx+ryz0JqO0wnv6FYfB1WZldW8l
hvWzzSEwMVPGXvRwrCPAxD3EMkPmAqbIJK6vJot0QdW1v8Xd5dxLzHCamsLANKPV+U9FACfdeIxt
GfV276z3onc4EIEO8w5CLk2aIA7ujvk33J446p++FHShGuXuz9/1+j1OffMmGiLz9bXy23j0xGn/
Wa8vvv3LkoYq0Uyx8VjdqGBWKP/c203St57Yfyzwr9+uwoS4cvUh4bEqgulBLdCE4fIYb2Yqf9c4
xGrn58hf8tFrL1phM1tbZfoaW/+b2bs6dUVClZ7LfTYbRZoKvtksNR4Yo6knsDi3GSsfqgyOEnCp
l6E34HfcUKDC238lIEGCvFA3QTQzt/+hhjPHtI1JeTVgECWWzJXO0NgIxnuNKkDhpfxXzfxfXWpa
aKEc9XYzh0sj9+7tLbynzNTJcmLXfWWe0lIlTbFOp7OCM6A6BV5YQnNX/IjeYRsO8M1945Ix59tE
b4uJ4mqbqUiKZydn374Q1yROJPX7Xv/s+PSE5UEz6TUjbtnKUVlHWFsq5KxIY1ngIi0ANkQiUwHC
AOTgJmOZejV+mJgFRlbpbZ2dHljfqUyQF/yQmPPu5fwR5zKpHKpY6sgdrisedrviK/z/64f38bPU
sbfKyMnZsg0dZ1EaItGZcSUN4jnfOxi8aCifL+7yAteuTfe0xEnIeZAsOYsKevYuO1zaV0S47IrA
eKEMQto/OhQPHn29syt2Nrv4b3vnEWYCpCbRte3qFcXdvfaaWrHOcjtit/p195OGlrbfFd+j6EM/
pImiYC4xDkqpGMngKkVfD5TlbegPGk+4fjQZgwKAtCcWCMh90q+v5n59tXttbXFQy2ZTXpdDpat0
VEHMFIo4vO5xaKs0APIEdKyL2YvmEW/ba6Z5WRSWUr2FC2KlpQE0cmY9LUV9yWpvO87XBulbvu2a
YKecheb8byEIbK3ij7ST6rTD9wposfxuTbCOWM4yrkUr8+yuOC5rspkXZVMr27kKEZJRlKJ1cHH3
EzACWVXr1LRrh1hkTsukadH6HXY/W/R77nsz5+6CtMSWQzta6m7M9lLl2k+nLmGPzsvcDlLl1qt6
T2tprAtNh8vS3HU+rlN1XnVeeecxkUoKj0rv46pirF8k6x12lwzy03yL89Rtabhfk6u6iFeT40PU
hJzrTll5EitwWR/9+jzoSYG7o+SzPC+ehUjLWIBQc/Ii2WO6aaSmawk0T4nDqYyRswcng96ZZd8A
Cl7Mw1zDSzpzEyOaNBruLo2QqZsTSRkQP7X1X2k7U+ZI4lAVCt6h4ugxBrnk9heMf+yDc23VYAen
roahzot3PujmdarDkm2GI6AkHFVdiggPUSd//fjkrNcfgMkI+51CHJ8MTitaKvwrhZmA+WNbfH/w
4jVObEetYTCVyUQNjXpDUziKx/qy9tevnh0MenN1Z72BVQZ3Dg/OBr59ODgjs73nvX5b3BPbjhbC
NGG7aaw0s0CdXYNw1J5KMJOhlNIOPXeB1+8JlEy+6k55z5ibXcvHdSbp9VKzZsIf0MQgfjw96Q2P
TvsvDwbkHrUANvrd7c8OCfamGVpSJ1DKzAzGJ4wuWR8xrAMrxrREqdC4qWJxBlt18Fo28riwMBUv
X5V4vEqMjBU1qSqtPnxYHLOHNqqeLey1gNQz7DmBFZjN5XUJWooubxWyuP01RnCFX4UCuYYac/tz
rlOAAJhH5Pn7hXgduyqLFVurNG4IxQUFmKMczlCgJvPII2vBjsEfbv+eKM4yv9Z6FadY29ZpbI/5
0+G1w4wE35ysTK+3ucak0RzkGqmFQbXeTqI0uKKvhOMUtNwvP3JSZd0KZSG3NjmXSYpiHpSzTdmf
7rCCZpsopnn6ViTqreijCOpY9W4ClZGjvndCZxinGvXamNt/X6sIp9XEMGoxRFFbNL5ZNzwn2GNa
89mHjnhxevinYe+HmuDiWX8LmlU8AC4i5Z+D0cbOn+jnfn3W5jmbNDZFMeGq+WxdQhYvm0qZAlhp
R1AWj/N7wT4VKA86mTY+Gziwc9aDLaIulN8MN5sefFz0HMWb0KRzAr91bYXLd7ShMu+TeJsY152n
8VX5oiO6jx48cJT5Dx5o/ZPoAauR1C7fk4mPm+u/fYwi5k8TdBpC+iaxipE0qnYqWuD3E1XE7zId
2rF/E1u95RM/pT3DbGa/MKIgG5+M4Pp/Oq84x+Uco6u/q39OBM6QHJnKY23KD63KIAQ4OhY+6/RP
g2mchs6/7sP791fd4NPcBcOegkOyytWnsyTSyRXLNfT8H3fJnyJ1McO9vGebv3cWl0LIymJFj3Bf
j9srcnB5o2sZnXq7+K1NEfA2nKgEVR2cb8hbeaT5A5uYJNYdBVpKunn5B/SoPE9z/oNLvUzaPxxE
zRq4XDRfnzRsjQMMFcrKrCy8JbH20itmu5TMnRpVJm5bP0unSY9pdf6G1itm7FbL58tyKEItK2g+
GRCm5AhFsTHqxWbC31k2HiNnXypj5ET5jYZV1dyVEbR8gRQ1sR6lk+GU/vJC3+CoevKOlZ/3afeq
mH3OBTY2N8PMFYPizOIcKWyopkbHLp/PWThNCgFGzgA3IZlGgC1SXGLAQGIc5j9EGltHoHTFd2Nm
FUOWbrL2vOx3jnnU/3CXs9MLn8KtDq8C64FZ5KPIQLDPyUzmoZ1SYrCmeq+iYmFpsPtzDIxYbWWy
UAz+B1BLAwQUAAAACAASeEJdJg91miMIAACvFwAADgAcAGFwcC9saWIvaXAucGhwVVQJAAMUx79q
Uce/anV4CwABBAAAAAAEAAAAAM1Y3W7bOBa+z1OwgVHJXceJ3TTTSdJk08bpGkgaIwk6OxsEBi3R
NhuZ1JCS67aTfZfBXiyKud6bnbvmxfYcUrJFWW4zix1gkyCWeD4e8nw8f/T+YTyO10IWRFQxXyeK
B0k/+RAz/aJV3wPBkAsW+t5Rr9e/OD+/8urk558Jm/Fkb21t88mTNfKEdEXCVKxYQkk6Id3edJvI
FB4pUSxk5FX3+KKJuGM2ldGUkWsv4KHyGsTTCVUJPjAR4gcoGfIZPtHwXaoTFno3qEukUUQCOSE1
ppRUBHBMBGMeSlS8uTZMRZBwKQiP+zFV2loiRqTGRZwmDXKYvT/OFLwwKuu75JAqRT+sfVoj8FPT
IADgxLfzgAAc5kPio+jFC+KB/RZr8Lky7y2N4GFKP3LZ9PbmAOAkVcKsZQfv7DrWTpj4tG3HazyG
t5peLAgbjqWGdYGMTVj1Eaw+pJFmxQ1cw7wGqLuByWwWRzJkPqBhCKa164uNGBPizAQ8wUcBHnI/
5COegMScqs9FUgfUAWyruIpj6nrP7F0SLqb3v0RwBIRNyJdfP9X03Zffmut7zrQlAhYkuERkaxdZ
wj0PeQS+1Z9S5RtTT7qnV52L/tuj0+7x0VWn3+3Nx05Oj17D+9vtujFziau5Bf+Fzp0C/459h2Q9
N53cf0bf32mQn1JGKBchJeL+HxLHdRpLlVBw13Vn+m5heo41IUQEkDqPIEs0LZK7yrMiCV4ORvK4
jY9oYeYGtQnVtyiakw4WbYEFW7AN39+anWQ/ZH+f+E/bZCNH1uvkMVnIc30meFGfWfOxXSCTQTwT
s5YFgW/93a5fpQizQXljsP4hQcVtHvtWSx32WR5pYnDA/2yqVZhxcz0ny+Yb8/jiwK7XWAhtEsqF
5q0gxcxE5lPhrSDL0lUms28F8TyHLRQbNzKEWdzN3trdmpO+ApmKxDdZidQUZCgIjCw9ZXbZUFHX
Zms3cEzzAWvJDfkTaS3pVWzKIDGGi8wYg3L74urnkyyRNCGRmI3kk/15jkERaqjXzUJQCGwVmEIe
1CYABKxNIWI+giNrJhJMFAI9+vjN5ctTEt//exDxgDbL6VsxDWpY2FdUjJj2YZPFFL18tltN87v5
PDsmJNszYfPl12TMNYRS8l6q2y+/eYWzaZWnzWfFik9pSF3wVnNn28BbW14R/Or1m6MrB9r+zlWM
0EjKeECDWwe4832z/SxTuuNlQC5uNyIZ0MiBftdutnYssu19a6/ft7MNtLdzp/YsqZB/SLdzdbIM
b7vwUAbpBM6M3v8TklIZ3tp57u569VaeN1sZ9lm+74RBSGgCM0LY1CRmYizLk561mki53dPXN9Te
egoLtFpPcwu+AW9vZ+xsL45nkkYJuKJOHOT21jJyzqO3Knzn7juhSTAuxvGhE2tDqRgNxhC7FS5P
qM6yIiaOiA5Y5FSymUnwWadjgOVSPyOPISEXUsI+pJ1ZnjJQNnNleTop1/0s3tY/2W3cNcgns+Dd
erme3xXj09alLDO8kRNGbAqRxO9dXdTx+E2da+Td3VIeiBPlpiqXv9pYaiw+fx6xBB8HH2gYqkK5
y5OlBaLF5sHkXwBBdQF9iYzke6Z8ZZs+REC71fTqWGscG06kEixgIRybcV4mplwSOIGER2NwCOi3
eIhpbgieBK8kZpEkYKtrGFjVj5WcAlb5eVNag9ElA/EYHxlJ4URW95NWJfavhdQ4knIUsSY0znlu
nHvyayNyAo9hzEGydLArwDJNIKndllUj+IwHSmo5dKJpLJMJ5dGD8ZN80J2xEk8n9KMUmull/JER
kcvOZXEClKRwpHhYMhgnXILoNYic/QR6usyN3Q/YBVeRSeziw6hiwkq80qOqBVbrpyJUPIpoHBct
dvDEP8tQdXcqj0apKC+WTwVRFVqq0QPQGgLiFq4tpcM2rKKoJ90ki6fAxSBKXSdF/EtIGE7qHuDA
ki9XYz/QsVyB/RFFy9hK6pewQHdFPFk3QxHhryKZOp7DAxypjMFVUz7KccXmzZS/SbdaGihLS8hK
6Ggyq/BgG99nfy0i37NBM2RloEH+YEUlB2mqyh2cZSKHbBGy5X1YslFUBENWS6SwrjR2g7pnRE5G
mo5XmIfZskE2N8mIifvPigcSEzg0qu8oNgly1169qNZc0IiqvLLjx7xMF1IsFmedDs1NBcqzAC3F
HG3qLw6ae4z5mqFUUwMJdUKkrOpGbC/qiTKT82Xgbq7TAZQHI2qQDXiMmPAzeR3uAC1764Xahbeh
fLyylpvNPbx696A0Mq7wwp81+AQPho2wo8dOX8OfhOiM7/8FtEIr4Za8IdyE+2ZGAHchv3d8Tmrh
ILtZZK2R+yWMuVSGg40DuFHF+LWUd9k57by6IlCGL87PyFwZ+eEvnYsOdgv2cgWNzC4jR2+OcQiv
oAcwoMn5xXHngrz8cQE87Z51r0jLW1xlNw7YjAVpwvxrb1fbG9uifYKmYJfNB02jdOP2GUbFkGHP
B71FqXnormAOHeH+8wSUklgqQzAS7Q8iCWKqUGB8E6ZzStiQ8UTWv0ZvH1VSLqCP+MOZ1mWm2f8R
03pBNfZrIlEm6oFQHzu0Cb5AcFMCR2Hp5t9glgsN8V/J6v+I1IMyqfvVpP4hZB5Fkb+4zHeAMLjN
EZrArc746rv7X8BfIcxJIhMaYeZk1bEeSOj0wQH7FAanFYw10NNJjc0CFifdEOja+v2uiUfKoRe3
HGLW0z9F+ZLmi6Gcya96rBkApg/ILnz8bv8V8r3hFz79OtL9kDPAIZ59K5ST8EAn/w9QSwMEFAAA
AAgAMnhCXd7q94YtBQAA7Q0AABEAHABhcHAvbGliL2ljb25zLnBocFVUCQADUMe/alHHv2p1eAsA
AQQAAAAABAAAAACVVulu20YQ/q+nmBIBKAXhmsvLZGM5aFK0KmAnQVvoTxAYa3ItsqZIgaJkK8fT
9EcfoI+QF+vMkjq4ZNpU1PKY3Zmd+ebYuXixSlejRMa5qOR4XVdZXN/Uu5VcT/nkOU7cZYVMxuYP
b9/e/Prmze/mBD59AvmY1c9Ho7tNEddZWUAWl4ViLhbwpBBL+Qz2Xyh4vYYpmLTGnHzfTow+jgB/
T1aiTmn6nfqkn5mWS2mq1+klmBe0ApKpce0Ct5kP3AE3j+Cc+cbZ5XHWh4j5c4en3JtH2hy3weFb
K0i9bYAT5rPjZreiaPZqNouzKs4lxI9TgzsGxLvmWU2N6FTi0mfnQIM7LFA3Tew6zWSemD0bSHnw
0Ipg6zM/tvE9AJc5EDKPTCIjkOZanHH6tjymTLXIuOBDR4eIoHCYGlfcJ2hsXQ0pqjg1h6zjrXVc
WXfekewgXrblsoCGJjLN1nVZ7cyed5RrRIgPGjZwHAiMFTB+5TbUjlOIhmPrp5qzHDJ4zp3cBadn
T11j8KzN//KW2xUZIbrcF5w8hsNWF8OAYmHOEGqBICqVueWwENUOc4tx/HdZ0Cuhpdg6RHynyDsR
4oG9HeLmOHydnYXMpe10NWjkA1qACo+wJ8a3+Mw9ikCal/Z41TLGNeZG4t7mo4ijFgOCUO1ZpFNJ
j/mpFgRFnxl6OECDbT6gwt4fPUAbD857SpDs2alD8O6lQw7BhR+0GMvLRbmp+6kbYQ2Z+a1MstSx
nPnJN+B36nXyiGNtwDphqasTkQ4q5cwibet7uftKMaJq18S3T28Y4V43nZZYG1U5crGEuFguXE0T
qjmUceBqm8ap3FZloSf0MoAIArosvQQsZbEZKtAeBCkP8MGd9hniU2Ou5F0l12mvfjh2v4BQGvhW
kOMdY0BD0D7UD4Xt6R4yyeohBale2mnUrQ1BI0c4jIKNt85EnK4QzyjHXFYZrYdJXQllRf+UQhDC
zhYhBHMvDbdO1yUIL9UObxZcoW808at8s/6KCf6We9e+AtnTuDZFUg5x4VHhYSZGuR6HSEvpVBV0
fPgK9qZycz7Do0GLlHK1O5FeybiGRzoZYafuD1lSp00JTmW2SOu2HOMaRzurud9Lnd7htcjLW3lE
+BuPZmoTHN0DdOwKhAD/BwND6BAsxdJtDeL7ATCXHNUPLUyLgdTIyw7PHiJPQURAH1EKTlBSE32c
QtXxzM8FOa/RM8Ry6jI94JPyochLkZgD7caWd+MOo9oGny5L76BU93QU/f5526Nhf9Y0au9Uc/ce
XrwA02xmK1lvqgI3XW8XoJq9qWECg3TctH4TfDcN2Gby4WWJFpIZjod/A+6yPJ8aRVlIg7rC8l5O
jXhTVbKoX5V5We2p1h4yFh5IObalsVhNjarEoO+Q/yiz4kAXVSasNEsSibS62kjjkrRDm1CtizNU
+hIN+TwanT19CtfYLQlIBIhVnsXiy19f/ixhjAfCl7/rbFUCdrB32WJTiaSEcgNLtVwuoZaPdTlh
8PTs2BLfVqJIbnDJ/VhveimwRQ5PXr15/dMvPzcwZncw/k4uV/Vu3NLfqZPoZlPl5vvJBD4evH1A
PFseEFe7WcSAUFTxwQUDohp/iLzuLVJCzNa7zbrL1sufNV+vRNHdmgzF1QclWRsRHb979B/0yWl2
O3aT3fSs9ife/40V7Xi8jtre2rXb27eL+UrIofQmfLo295Ch4EADSUixuPwXyH98/dvLqwZ3lNws
v5DLQZab9ea246mLM1yJbLi9plFLoyD/B1BLAwQUAAAACACYeEJddnEwArEEAAAkCgAAEQAcAGFw
cC9saWIvdGFza3MucGhwVVQJAAMPyL9qEMi/anV4CwABBAAAAAAEAAAAAH1WXW7bRhB+1ykmhhFS
gSzVD+mDE9t1EvUHdewgdtqiAkGsuENpYZLL7C4dO7aBHqIXCPpQ5AA9gW7Sk3Rml4poySkfJO7O
/3zzw+eH9bzuScwKYTC2zqjMpe66Rru/239GhFxVKOPo6M2b9O3p6XnUh9tbwCvlnvV6oyc9eAKv
Ts5eHMPl7vBb+PePP8GRolxYEI3T5eKTU5mwzPZSG4MlWP1RVXNhB1BpIPqVKjU0pYBL/Ai1NlCq
iiQH8L4RldR7LAo7oC1YNJdKaoOWTYJEmwlSORMlCPioKwExXpEGcmBIQQ2Io1VG9PBCEQV1opg1
i88lNFaAhqnILnSeqwyX9FjXmSKVRd/7FmKCzOgKsrmgm6mqRrKy02KHL9nekEVPFn9pWHyG2mCm
rA4SFYUtMrR0Nlo7Zhz1enlTZY5sgGmqtEajtFRZ6oS9sPFU6wK2c20yhH3IRWGxvwcUrbju3fSA
nm3dOCJNIiOqCPYPAtMAopLsiBlafzlJEoKJ+VUO8aOgsQ9BhVdTCMt6LDqnqlkcscMpX6bkVsT5
ah9WELgf7e9DFMHjx0Dl4rRTJQZKHw7An/qUwadPu3b4MegaU3nPV2rveuE3BFXo7IK8+S7XNVbx
suZgCNFICidGw7a4hswYUbTZ0sUQH193zW6YvFsx58wce5EBHJ++/Dkd/wa34e3kRb+rJs8KbTHw
dlLygHb/58x1N8VyChSTnMYd0e1Kf6BL+u3etiik9L+OxMCL9Fs0+RmNYFw5IyT12vsGqSdrZYQR
5cqIh5bs7xxQPdbc4NHZ+Hj88hyUHECmpBlQEMLqahDE0abCwfdvT18Dkm5Frfbrj+O3Y+Iq9SVK
pv50Bifvjo/h6ORVV4ivCaqHSM/34bBzJ9NCz2YoybdvuhVG7u4c4BVmjcN4wuEmXWorzBExY44u
mx8VRbxeoy3fevXRgMC0FOYilcq4667Y3cpIU8uNlL178+rofPwlIWfj881Adts8KT4cdqOilkOR
zVeOAeG1jevukaZ0rqzT5jqOMOCaBkilYPRxEjFgURLeA2xRwr3h554yugEaNBHd5KVLpYuZbwVD
lPSZuc9tY8kSlqLr5zL8LgQkr2SUJPdy1S3AH9CIxd8882QYwQOqYZp3POwWn4wSq8zmqsDuoPF4
8OXGkFnmifaMZ6oQpU2njSpk7LdPqyuMITo/UtZrij3Bs3wx4xtohhU56ggwNEYb2mFhhq2DsG3I
Q2/zg1GUgfX0UKNPVgM2mSRcK2YS6YsoucfJzyFs/c5LaYYM4R7cMGdbRFFyBy3ItAg9pTbaYUY+
etpVVjR28Q8uqfZC1XWg6VI5xU3Py9JLeQSGWxse7EE0pnhBaO+Eadfknq8R743PRvI1dH+hpURL
cYnwxgr+wnt/4PlUzXnkVTadoyjcnEfYejZXjTGn+EgxGsqL7w5rLteh+Wr+t/hb4IZFJtFcW8cp
ituzqunU31uSrROu8bnn75T2UqITqqDLrfvurYbCHWTCsaPnc6M/iCnV3mb/PuhbSH/F3zb/n8kW
Etw5mKF7HZTED3ddMMRbny0402C7e4C+1ERRdJHYXHHvTrqjaXOthajvLba73n9QSwMEFAAAAAgA
EnhCXa6yG53+BwAAMhkAAA4AHABhcHAvbGliL2RiLnBocFVUCQADFMe/alHHv2p1eAsAAQQAAAAA
BAAAAAClWd1y27gVvvdTnPVohmQq/27TnZHruKpMJ5rakivR3WRcDQciIQkxSTAEpNjZ9Uyv+gCd
vkEv+gC9623eZJ+kB/wFKVmxt3JGDoEPB+cP+M6hf38WL+Idn3oBSagpZMI86cqHmIrTI+sEJ2Ys
or5pdK+v3dFw6BgW/Pwz0HsmT3Z2ZsvIk4xH4E9NqwPX58Odn3YAP0ISyTxoxT6HU4iWQXCSjrMZ
mOkgixASeZTP1CoLsmXqk1C5TKJ0abbmMf2eB3xKAmj1hoOL/ttsphUTuUD5+eCt4U9dNWRM8nmf
JYDz+CsiITVTvFVp8h0TLs6ZCmfpOvwhvCvG23D4w+vDNshkSS1docI2+llZYBriU8Ak7Riwn+nV
Ts0uvm9L2QjudLqOM3Lt0ehqeG6D9jl9k83nU679vmdfO/3hoL1h/bl90b25dNwL2+m9c1NRxfps
qDseD3vZyol1Umq994beU880rkfdt1ddmC7FgytZSPlSokGvDw8PjafRHzlGhwRuyH2K6B+7l1vA
M55QNo/cO/ogEDwcFFgMVMjmCZE0TYd8tBb6x1p6lXA0LwVguq048/N80/beLT3VG9ldxwan+8dL
G/oXMBg6YL/vj50xCColi+YCzBKtPqgnfjv2eweuR/2r7ugD/Mn+0K5hViRY0gyjBA5uLi8hjwQY
RgnNTfqGHktBk6YSzNef+gPHfmuPdH2ge+MM+wMUe2UPnLp2SqDK9eypruXNoP/nG7uOj4kQn3ni
uwsiFnV8HeglFN3vu0SuCa4DAyKkG/A5ixRWAV/oExrhJUS3e+WlbvGYn2iPW9RnsYs3UyIb+zwJ
plGl2HYwOlBgLm/UQcugbW5/ToCmDyWykRqx3xRVB9D7mCVUfAvgq+jOqb9mbmnEYdPwkK+2bVwA
NNW35Ex/cG6/b+QM8+/dPG/chERzlf/DQZVKRVTbecheLjV3b01qFZznZXaccEk9JeXp3P4/Evvb
p11P7udn9nakT4WXsDi9p1+e089M6F9xjSyYkDx5eNrVL/V0pfUWpbX7dz3PScZma7GqozBAc7rh
uD/pT59KwgKxbcGvOE65//TEL1360sQv6EDSMJZbbvYXhoTF5X+fx1w1VNMnu/g7LxvpjCwDqUqW
qm4zvvCIGtD8YMVl+JGYBvvfJwsu5H4stfAYeJ/GPBLUZbFRX3R0/MP+If4c63Apg/UtUvj3WJVp
wEi4ajdhrAEjsTcNjjZrIzhxaYjJYjRXKXCIzE2TzStzl7jyXjbsGNGPlEni8w5w6F9DCyjeMRBg
ruAg0BB+Qs+RR11avJzi/MLNKNHQpNWMDDFp4gQ7kHtd39R5v9NxKjLujAW0aVbRtGBNbhwg+5ED
pcpBFq80npoUZDeeoIX8jkaGLmXKouMFvTeRWHwe4n0kqTCPf2tZ64tJEPDPmGssTiOjVNW3SGuj
OY1okmekAd9GeXwZIXDNOw0YTRKeGGvCUt94C8WJrqCfjCdcncKmS4YhrlDrMC/hkZtunCwrJzX3
xCRBrSOJ910jWWoppXKYkgD7NdiIKro4odqSrMLHbIhVn2r0B2N75MBwBP23g+FIXWPOUCvrsZJv
Z6W6BX/pXt7YYzDP2nBmFR2Iak2It8B2tDztREDrTinQWunNIO6ftRZLbD9uW3dtnJ+UrWCjnXGP
3NdFS4OTB69e7cArWB3tv4Zf/vZPIKASMK26CT4gWUDj8gCTg8BGEvDsTIl3x2cz5lHAL6LOkg61
9pXsHk8SCsuQwNf/Rgq1ol/2Yfz1P4CuxdxQXkBbBXzCtoWwyCfqgNKPJASPh3hm03nA9AUeMiG+
/osDiSSbcyX+YFMTlhr5RCPmYyKV4cItkwdzd2xf2j0n75wuRsOrKlA/vrMxeKrvOlXnHcV7hCv5
xq6192ZGpbfo8WAZRqbWt2ebfHd6CjMSCLr+9qDWpysyRWRhRvqOI5pjqC3F1tn7CDTiLB+vBX49
8Z5py5mhMWMzgyb63ErtoQAbjK0sSnGFwXCWvlWATmGM1VrlJhdHhm5Q/eb6XBF0qe/YLuxAfTdr
38puDl8x4SSnxzQC6FQzY0Qr1cuoEWD9+FDd+nWyzJm15pR829uJSov0yNTOyC9//0fz3Bh6zCsV
S57M1NxtsuNfo3TkuBrZ3ab8OrlqVPy0BXjOV8xPT6FPIeIhFR0QeETX5G22Qmff3N/fpt1nR+T5
DF6vA562V9J7yZWpiRL99d/qTlGXTS6ndnemVuardS0PDqCb3ZZYNSpZ6rKc44WGF1jqxBWvdtde
/2zL8l537JjZQ3dcVJsW/AaO6hdRkzR3dUs3ElFKPxvq43bZEbTz8r+dF/jtom6vE1T5D5mqVsZq
EVN9vGl82Av3fHjXYR3MbgyNwN2xuMujxJALuGrmUxLwiVDjRC5JwL6QLCKKlXCUhXHAfRR4AvhU
hmKy9razsnq3ot+RfX3Z7T2Lf+v3uzJR3fHbrJpY9feAhXxVZ5lTzgNoJTTgRN1PGRV0gCQJeWi8
hvaQ6en6i+h8+DSbUO+1c3G101Isvp1USVBWD+rFd8FzBTdUttcJAg+hKjES/lmXX+1xq6ZuDVxu
TNQxyh5TQYa296MWloIc0vUbfVXRndKqeMiPscp1A32WDRcUjs7FiZqv6y9oUxerl7ouvcekE2Ym
XC20kElKUsLnWzU1QaYqttyoJB4yuVnRLIVqJUbm8g2V4AtSMT9gNVZOTUhxRerXXJD/AeBx539Q
SwMEFAAAAAgAmHhCXY7OzUttDwAAxC4AABMAHABhcHAvbGliL3VwZGF0ZXIucGhwVVQJAAMPyL9q
EMi/anV4CwABBAAAAAAEAAAAALVaW3PbxhV+169YO5wCkHiTYzspFV1oWU5U25JGsjNJKIazBJbi
VgAWAUBaUqyZ/oj+gUweMplOnjJ9ad+if9Jf0nP2AuJGSU5Tj0ckgd2zZ8/lO5fdz7ajabTiMden
MbOTNOZuOkovI5Zsrjsb8GLCQ+bZVv/oaHR8ePjGcsj794Rd8HRjZaWzukJWyfODk2evyHy9/ZT8
529/JzSdUZ9f0Zufbv7JEhIxX5Axdc/FZMJdBhNwztuARNQVKSM3PxNBvtk/Ih4js4CSOYuTmx8F
8agmbLsiIGJGEoZzkpTiyFREwmkjpYNZ6FIipySzcZLydHbziyeSHnFFOOFnHfXRhm0SBkvBz5Td
/MsTSMajKe0gFXtME6aewNwmuRIhbRL35teI08RpwoZdlgo1vj1NqeuyJCGaAMUfopWyJGXt9CKV
fPVhmQQp8hB4BuniTt2YU9gY7lPRJsAHfPP4mVCCkzRJgRtJ7oQRakiBZGG3E+pPgSolAeOiSXJ0
YOWYC7lgzCKRAON0loqAptylAYPXSLKzsgKySFLy9uj56HX/q9GL/Vd7JwT/bZKPu93uRun9s6/f
ZO+fdoGn9e6jx/pjg5BOh6Q0oOEUJZuA0qKYB9wTJSpvj14d9p8rKo/KVHJjX+7tHY2e9Xdfvj06
wbHrwM/KBJSdchGSWeSNPB5Lgw3PSANU7/SI+rXy/QqSb3gwy5gtaROrI5VlwVccviEH8QmxH/BE
0mp4jkPUXPy3E5yrp03S/eRJt0nSeMYcNe1a/o1ZOotDWGhj5brEW8RCD1gZRTSd2mXO9DyzB8t4
jCtYAv6FrOJ8qagrHllV8jH7bsZjhrpMkDyNY3pp9h0Lkea2vpFfc5Btz0LK6uvmFgH3T5IRuHUC
BK1veNSP3SmfM8tpLmYk3/k8ZZaawS5SFibA0MgX1EOIiDwx0kPys97FPKVjH+bBLBC1+W1LRh3y
pz9Vn0oZ0CiybnmN2jQLDaWIOqur5AV3p4zHIkHP0hDz3YyRcAET2ovQs9ALCoJNznmUGVXMfJDt
WAhfixatBZ+Szc1NYlXwxcqbjxY4Gk3eZpAE0AevlJSaxFJW6Uia3RoKD3g4kvrVEwZWEYUsQ6MM
Q9Zwuc0CeCQsE9ouDTj6LdAHjJgDkrKzWSyAU8Dc3/7Rbv/27yah40T4ACOAjrOQAzIBvAEsuzSm
LgAO/ApnvkicGqHSCQOT9TPBhoBCINntor+GYLTwBEZGPuzFtk5PcW8d+KNmLFwWx6IKLAxGjXDQ
HarfHfnAyDdskoen3YcOeQDv5I5Lb62elXuZCR4GRTE7GwFgulPb+sj+9n3HOW2ftu3O+4bzkeTH
qdEU7N+vw4cwE3Q/BEdPMAAY28TIh1LOokQIAaIqQngdMTfNJAjOewTQUnF90MJm3snFuXQ7uT/Y
L4tjEcsnFooWYy2ssHgw4T5AEP4cgPFY6A0R8+SDbh4I+FXmzjjFzvgh28TmYepIQjAq96ZXJDGl
j548XUpkSpOpempGNkmeFHBrHD+D8eUYltcVymigBQFWQ6xDcvQFZh/gNSQB8CIhgkQKOqEa5PA3
rE3QN0A3ffhgLUpCQfZPjiDi0TMWN0Fxi9yFKZpCEmxbG2VLQSbyltK4Ak5C9o4suLbz5n7V2hIQ
EnIiQquVzn371iYaDtWmICEAy0OTm9/84ENsvoM17Zfge9KstLAbqQBThQdd9XsCqYbd4PIBgc/P
CPIbzoIXaAT4aG2twGaC4QnHgMmn+xDoLmC6s+BErghDtLU7MGFg4TNruBikYEAOzJBAJoCxetwk
rXXHoEJ+efyHSSAPDTIv9KCliJsrAFcef7LFTSBAty8vgLtzAQ0zNd6iI40EyNPNzwFqyNV4zEOt
JzB4TFuQiyK5itJKe5G6GyCruFiD54SstLi2qRxWylj69bAcrlwxC1MlgsQhW6V8EQFYkdoqZooF
ldeJY7kowE49FtAEkmVBzmIKJgKvYojfLK4tEu5jx5CfHhlJ1xcUxGYX7R7xwmTst6CeedxxlMFD
NJjwC2TRKqSNCTNyGVgc7VhmAcMC3oB3MOpOtbEmhCbawrZAHWWzQbqF0POtPfi2M1xzOpL8KdJv
yAAkU4FGoPOjHCONYLA+NPlTB5KXFFyCRjWcZXrItreYa21Uho1hH+fFx9clk7teIhyzAlDOialJ
qq/v4vm+hoQYl4M8bVeLmhICIhQrJOMG7aGytnMf5B6rbDvDKmDwjKUvYhFoZLvXHnNmldP/w46q
v09PVQH+5d7xyf7hgdU8PU1WLXvQbf15iH/6rW9o66p9etoarjqQNjmdh03FmbSRDxfggSwwBSeQ
KSU3v8zBXjnWIxziiaw5Mwc0SfZ9RCVXMTnH0NjbxoqJIvfzE4m9WpoPFPSDDxRyav1aRcnuh4E/
JqE6jEha8M3HyKtJVoJALvxkBUQjrjia2rxJqIZraxsfwBNOVanZELA8j+QmfSgpVU2B5A/HLkqQ
gmJ0SnogIIT6fB5riM31Jmw2h6oLeIOcVfZyIOMB1QSqPgg9UZPrQ2kA5VaWp2Ijo0nML0inKlU6
7gs3JFsebTkmn1ZgUfBog+Aok9rJKQ7kFWEpryiRsloqaBaoFjNznLGogpZ0ZOx0Bs/yHSDY93M2
F/5cNpR0sPZkG6sqEex9zaKRKzxW6QQYlnOSy7oCrsDek+4HwGxgqDXHHeWQINslsAWp8teB1/qC
wxzI3WXnwJjDfdNLZKeZG9Xr7R7v9d/skfeFh3tf7b6qT0HTaSzeyaWOIWngAdsDsUUoC7sOVLAf
hnBimmFMVZ40vPkpr4i25RQxFxW8SWIQZWAvKRlN+8NpqgQwF9UaPNXyOGbuDOBozvahgqWpiM2n
XXj7nMdQfIn4MnttqDeJTHIvoXgIzMte7+Tl/tHo+eGbEwMXC3CDpRHZJmVEe9CYtLZ4gtTsCnjc
ig7YYrqlcp7IeIRFA+Kq7RRh3yc5vENKC8BDIZfh7p6dizt5BoOjnic3W2FQJTcFhSsBLUDuf7A4
yCbnv8PkbgWMcr92GQR44woAnPliDBDT2D08eLH/+caHgYJKVJe4v+nEKZq4dGuLXTDXto6O+5+/
7pN31B9BceieRwIKAPvN8duDXXB1x8onIzuw4KWt2RtY3lh2NGXuJlH4/+b7ZZkW1bHjTgPhGbzq
Pn3cdTaW6+lLFsvEBRaAPB+oEfg/yRqFESBzIEsLlgBTssNFTfc+AJnBi4B8B6EAVIH1R1XBmBz4
/Gya2rIdo9ZPyt2ZKBZjnwX5WjoDBjlwdM4udXyDSktnQIUQl9IYnKXc2JZxDoYWnbUQM9XECrKY
/veiv7pkYGEDA5mCFBYsOvidAADGDCTgr/R5s+hi6Lsp+kCuNc9jWerIiRh4sqn4ppJslcjjmDo2
qruvpXbLtq9rMMIMN/aHxzf7qr1XNDx54mVqk7/e/ABWJ9uDnpBHPrtQpjYUdOgsTvqMtk19NpVP
V6pHR4Q1kRI8of6ZOTJq4qkQ5HPlQ6GaIyR1TlQwdahe/MtyH7JJtN3zcCKasmVeYr3sC2KGVjy4
o0EpWw+6/Yi/PKaxdDEEIKnwyDSpXHCslHnK17D4X8g9FHP4a8v6UPoHh1JQShW5jOiZFF2y5MRN
d8V84Z4D8Z2JzJyq50zt7FSHijYOlvspgKuiAYXDgwl+s+XvJnl1uPtytPcV5Fzy28GzYgEHkivU
an8Bw2FJiuYDendFHANIwSDI5XNHsT/W9vpgWKFHksaX+aVygFVEOannrCYp10RmWsWRyqyfYAeG
xQFPTNtUITAFwFUtLx5EPibOKDxtZKPE55DjZKs00TaeOE4FrtpZ62rB0BZ5QraBMgA75Ylcojqo
BeRkj1mG2TY5wDNbDF7UxxSv2DatFWdOpJlUlJXWyyRv2UMt7ULdsFEzaWH5Q0KKkzDc13JySyWQ
MXq/ZrM0lw+L+HQcAy4vOga1mFw0QfyXS57zVlfsEGCvpTZmoTPqdnOxL6OmVPtcUgZqljkZqiN8
x/4f1uzfB8f8Hlm+zvVNHtawcF3dxn0D/2Lfd0TY/HYrYfZBdvjNY3n8/UQfJf5BkjC5X9Z+VWK5
rzB4cgArbQJu1qQ4NbJIAwxDRobo03lwhrc17U6Uy46kH83Skbw1EspVgqiprMr5ww0E0Y/NMyu5
pzhMMiw5g1z48TIt78RMG4Pcwy2ZniQ7C30ensvRNRR/x/bM/Rz+gRuUHil1voxXE+1VhqY2di9L
0uiLWUalJ5frbkPyAKmZX0am2mZqCfdN8pQdTIrIBTTDc6WEpVZF/DuF93YtRqpgPAuLTVy5l0rP
75q42Esm9htUFma5pMFuSygaTCLla5Yk9KywAiRRxywQ2PXKp7F4vaIuU4KgSUEviQuOI2bEZojY
0uPVHNlLhgxgTq/wklW2TKkmkh4BIjY6dqoNFCk3Y66TcrD08jhYfqsLDRiEQS4D11xH2WuWMFc3
PHDMThzU3ByqX9lzlppXMf7WZASqz11TmLC5DvzmgkDN7NK6pn8+V8ZSx3g1HX17UIer8VivroqC
mrVVL37e1DBZQ6NgfW2sr8aKsVpHx9ytn50+ZDfdEGfUVTdauepm1RLC9LIPkC7tFbJ+NZ0r85Uk
bn5AGninbYzHsmjSaMUq5I5zPBPLaYNjRCKc0kU/Awy7X7gJWU4aK4dnNSCzc4cmdiYKfuSA2oaV
TEkL/apkac+rifWjzItj5sqKUJ4I6GcgbH5WczVFqbp6DQ0q2bSu04Etrzu63KuqeU22ezC96u75
E9Jsjt1e23Za9qn3/afX6vPptWNv91qn3pqzfYoUG9gQxfrYQIE8HcshKLIsQ8igoCmZccq7cpBq
FuYXh+Wv06ij1G2w122rNAybdYaaPiYNBo+GeO3lObx6A3G011Ngh+nqCxHDXmV3j2B3D5mG4Sgw
dSsgGHw8dFpbEzOuFbRgZI/3UKyLqzLZ+ur2jlq/dFknv6XCPYBZImLgEwUEvhwCglA8YXSQBgCl
G0RQ4AzU1tDpqfnulBpzSCEzyNdUXXlIbn5FLZuWRt4Ea7qpOvL1yFxwT1tbZl0Sf3JGhB0C2SZd
NR1RZVARTQE7wsr5Eda6t1ioFHg2V9rnwn60kCSZipTwaYA5ko0PPis+oflGeyn+6XJXUy1fjVXR
UPje0niI76oNq/yN0kmQjsaXIGu0BuS31KRW5SvZwku4jz998snT2rtvwZjFI22EMLpjBjfJOhbv
qAmipEheP7NqsKpIIqAX9jpKT1J69NiRdX6Rzstn8m7sfwFQSwMEFAAAAAgAMnhCXQGHyg8mDgAA
MScAABMAHABhcHAvbGliL2hlbHBlcnMucGhwVVQJAANQx79qUce/anV4CwABBAAAAAAEAAAAAL0a
227bRvY9XzERhA6VSL4kTbNxfIEby40B11IlpZdVBWIsjqRBKA7Dixy3DdCP2B/ILrBFH/pU7Bfo
T/ole87M8DIk7XZfNg1SkjPnfp0zOjwJV+EDj899FnEnTiIxT9zkNuTx0X7nJSwsRMA9h54Oh+5o
MJjQDvnpJ8Lfi+TlgweLNJgnQgZk5bTjzgFB8GD54McHBP5EPEkjWErWfhzyuWD+fMWi2HH0rk47
7pL+1cT96s1g0h+Tn9TL+M3n48nF5M2k3yX0zeS89zcKXHwokQrkjXMHKY8l3KHf9dY9j7w+EAdx
FTaNfEOdtEO25F3Coojdkva7lEe35IhMZ3egpiLw+Psd0NUJJTsgVBK616nwPVeBOlMaUnJ0rNHO
yGODskI/4p6I+DzJmUgk0NtI4RlqK848Hjn0Us4ZQhwQpIbbXqp1rfcyyoXP4lWBDwzXJdnbmscx
sGOTaLvj/nh8MbiaUgVLZ9MZSm5gM6BZAxkeo+aVyjJkCwCtYyQnJ6BKzXIaxDxx6nuMREa/7YVN
bx5HCzeRb3lQM7ZYEIevw+S2jBT3A84O0XsqgupVYPVaBE9W/L0TscCTa/f6NgGZnj7pGGY+WCxV
4Rs4XAjue3e5Iz0UQZgmBBV71FoJz+NBiwRsDW8I3SIb5qfwojzKKYvcgS+0dUwbSM5XfP7Wqdg0
5kEC4mWhBZoZDsaTXHAwR9v9og8fEv1GqZH4PmVioD9cgbFc/i5lflzf0tWULbWr0Ih4HEowvDuX
Hnc+3dsz5DIfdugQQsGTRASb7UcfnsCvSAyut/2XhB2hiGRK8C9ZyGid+tuPkZBk+ythQSKWcod8
Lf2EE5ZE248x4aDyOfglX6bwjYTbj0sRsB2amxW0uPvoERmQiyEJeZTwYI4bmb9M18STMXyPkRwE
KI8hjxBfxAk7AYVuf4e1zacd8mi3MIQIXRG4uCePPBHmyQS/g32upfQz+/gS9hwB3BN8cmB3Sf9m
9eiILEDLvKxM40nqe9lFQSmczVcIC8QIi0l7LrzIcv9IEXRDyLm8SLpqW2EMRT8in3xieDyGcI6m
FISP0FXy74f6Ow88dIyCSonJJEp5gfhDPaCMFLktQu0C4NBLUD2Ykm22v4L2OQGjhJF8f4vPcxks
BAu2vzDiqOclZuHOiWWQCDyUx4m7iCCqgZE44Z6rUDi2JZa+vGY+ab8aXJ1ffKHZbeNGAXaHAFIm
hPjR6xAvJVywJUttleSVIQB1lVyjFI3j/ujr/mhKR/0vodi5p2dnozwQuzl8pVqI2MVgiisioMke
FjGrEb+eTIZjNA1arPqVPATfonKxoA2+VZjNMtZ9Gs1RADGQMZG+vIGq1SAvMuB+654PRt+cjs76
Z+5wNJgMctE7yuupkpLmngExCt7tE/QNX0B+4TtkDHGoPYHwNfm2dy6jGxZ53MMnsoHqLO92nB3L
VzROV4S1vN3oHBFfS8g0VnK925x7O+q/cnp9eJ8qGwxiKJZt0obOSQTAg3JPd81CBzxTrGkXc6WP
OZZ24eWvWACeCv0bNiGdQBoQQGAu0wCqtaLXIT2y/xJSG2aFPXzo9awMI0Ks/mrvtC1mdlZZCEjQ
kbthkaOS4/nF5aQ/cr8+vbw4OwWlXQw7zTkP/4DtEhHU80mu01KYKewmcO+O284dWQug701auTWM
c/YhNaKvMQIpki8YlhOx/d0Tc3aAbMcCGjjWizmBxMs8LGokwKI2l1CfIrLafiRrJlSae0bWIGQi
44qDRjJwgUyS1vst6J2w0ENLBfpZOlTtxY9ulAaZ17XlW/j3yOxWwU/zWE3EmjtqpYN2Va9o6ad7
e1ZSm1L5Vre08i304gigX/FplunjAXlErrBcBiumg26NrRW09lg5QTdrkfBMdliEgu7JQOkvBDwM
e3a2u4No+hsB7xAqsGf81SXCYY3+QQaMLAR8X5cRcNAK2MGBpvyARFImHURih7mLkQcNt4tEXHkT
QJKqNE7Qj4OissMNdl27uJmWwhfSMOxycGtDuFphqkgAPvB9rskpKGOVNSfKLBmLLnRCcRI7NJSx
eO8uecJT4UGOPiHWFzDPAXEE9FkY83mahX7c9wEHnztUeKSX0k65qdC8PMwiTBUG4AA/6DUrlLEr
vZe18CbjzbG/GUqdKUUcOrXk3YYhdFD5UkTc4iYCQzvjyVl/NOqSFoRX7kQkAZN7Fe9JE+GLH8D0
kXEkTn5EJX8gzo9Kig+dne+DlhXqO4D3PVRMH7rMOAXEvZSYzQR6CdKCHWJt8iiBPNr+4nLw+enl
eEpZtNzkRR8RAe5qL7tfbjML/0uBa6gzaay97qQcx41tNyp41lQRgtT3y36GuUHMSRtRg9GKZWV4
/fVIf7eMrFKHd+10esdhxEM88NNx/7L/akKE1yUIiErpEpVQfAlNtMsScj4afKkWY/LN6/6oD5sB
zwkt6QFQ947RFVMw5lT5alWwWXm74VyBLXgyX4GPnxyUJPlzafBP7WypVXh/QkeMlbGAEbzWELRT
LImWIe3GL4V4aKdA12AAV4Ejewyxw9eMVg//OhkpvVbykEo0NiHbD8zcAAcYVCGgnUavgzV3BeRl
dJsfTZhaKsYCULggeAlWheKjxxMm/Nh8Pck+l1zM5rjiRhdX0HBMyMXVZEAMfWjXoY3DIsySsnNl
7Gg2usRQ7hBoDd70x8Q5Afr53w4t2s2Si6kpUNfwhxln+Hrojk+HF7qjhORPwTS5JcAqhZERLmOi
nXGRKWBWacKNMFBjr7lfq8dZrcxZhBNSgmXfZdARADw8UrUAlZP29RoprXXrkGDrJAerQGZrDWDY
p2xEAVcGy9ca4SCZbAqCNly21sQnntJZM8F8rQQHrVjCl3DiK3QjqYEbZmuktNYIa0SRhVYL2Hyt
BIntA9SqMqM55N+xtTBrVRDoL6QFYASEzyTQXUkZRs1JxVzy2GXY9wLKOBPuTK1tf9n+B46IxWoJ
Wk19QLRAbphXIovQE1wj+VoJCsclTLpIV1QdZmxGKfliHQ7agpWlFYS7CLa/gf6xrGbTGL3PNgfz
2SZiLrRwMc8Fptoceq2n1nJxy9BFCXfnkSgERug3RXk3a2UlBzE29Ne+CmnbMGMeoekjcnY1Vq1C
vrGCAPJoGiJPFT1bCEqbSuDQkTPkbs5kzZdOzRqYWakdarRfkbsEbim/Dp6tlo0W+64emNheqVSu
Bynj8WUVAg4kcz+1gRBigMJpWgBF9Lbtb3WSyIlM6yQrCGyGZ/ek0EpVuuvSoJJ1p2a7HmXq52Yi
iQz4n9DAYoudDeZxJ68E06bU3W3Kk7OuGppAhc4GvR4LII2UDg33oS+ScUMu7d6RJ7s1561zAee1
+zkoElu3lgW6lfDqNvtr13KLOg83LAqo1SPRgKcgpF/phhbrxPUSJ280PKjBOOQi7RuRrCZCHUcU
8gbrPYTtDX0y/ePnf1DrQKbOysWpF6Ds/i2BJkHdGhVUoWvwdte73+ENEvYN+g0PBQkeZAyNqihB
unbad3kzLF7zyMVJNkscZ+FLBv0xmGQP1IlzGzh0dPIJwysZeMKE1leXmIl51jegAxInjRkchKDv
2v5zzROoRwfQDXXsGUL8znfR8JtSMPiC6f6u1uYy7MX1upkWnGTvcCLeUWqwrdqC0xb7oFxZNXjk
Ykyu3lxektOrM6LWlEtjOSzWBiNSWTnWvHdatkZR4NtsBGKm6s2OYA5RfEoLXpoPUTSPu7KHVJAU
rGWz1MpHHISr3rOJQh7FDfNUqoxX8RwtoXvNvGVhJ/2xZqM1w2nb1OBRSdiknW6JsvqeRVy3JLS1
YEZ1bZVeq1g/9+W7lGfZz0LcL6UpG/Moe5vZwX8YhwxnMdAMHLWUnET928M7LweFmhqB9Uwy4zC7
AFM3Y5pPa2OmJdx2uItEjmk5gjZ4yUMgTkIdSRhFinnzat8rQYDqSVRXnXTU6I60AjATa+G1kJ6g
8DVOnaQdaOp6Refv4sQlQ/vEhSmmOFR90kY0+bEqH0Wx21jZYt9TOt0HJT/Xj8/h8emefn6KSeOF
eXmBL08/e2aWPns2K0+AFBf6QKRkoXijZ31uuhCoThtUNYnVQRtZnBoEjUFWv4HvlvIvfaxusy0s
aECCX6h9CVuTQI3lrHEGTiHOgCCm7YMDfdg8j+T6XOdZzQYmbuSqcucFFUQpw+sdL6ztHT0hUyCV
aUNuNuiSPRxIksxtqu6l7zTZDn1pIajf5hXyKgLqPpgY8kozT54ePHsBf6nNvtnZlIxsTk8b+TOD
NTw7BxAJKbAl/1dmsxKqOLGKbk580Bx82Z1vrp/a/WBRCFRcudoP/sLp27g5ZqSr/CbZamoxuIju
YfeJJ6y158Xac1yzzmgq/vTi073a6oti9UV9VUeoIcoC+1CDfp0dAra/5j71x8//bm6nrxkkHBwE
1UqEHmZHakoMK9Athj6bQ9x9/z1m7F34B7aoIUhxQTR+NboYTtyr0y/75l5ol+KIBP9nmccp7iOx
SdKXdtgZ4JNO2Ae7uzqv29dPrwfjicHtyzm2jnGiAJBjW7iQ4c09PuIQEX/5AueoLlHP+hc7+pFH
Q/WWZdhIpknl5zw19SC8uuTF8eSavXcgw8658B1NhezmeK1BugaDUNtvqvl2v4k/dkLPPwzYJqt6
CB+1gDXBeqqQHbWGSkoVDepHHhYtaIosShrpDmJleSVNwA+SoLdEVaqneN0iq4gvsl+ToINkWjE/
b3oMtSVcFj9Twuu9WfZTk9MADupCRoe77LhBJkW+XMuVVD0RLECCof69hf6tksKskjovPsR2nbbl
PTR7/j9CPy4JPebLFJyB14TOkpvmAlkHg+oO479QSwMEFAAAAAgAmHhCXdeiXVYwDAAAwyIAABQA
HABhcHAvbGliL2Ruc2NoZWNrLnBocFVUCQADD8i/ahDIv2p1eAsAAQQAAAAABAAAAAClWltvG8cV
ftevGAmEd9eiScq3tpIpR7GVIEVrCZZStGAIYsQdkhvv7qz3IslODPRH9KlvRR+CPOetr/on/SX9
zpnZK0lHbZkg2p3Luc25fGc2L14mq2THV/NQpsrN8jSY57P8Q6Ky8YF3hIlFECvfdU7Oz2dvz84u
HU/8+KNQt0F+tLMzfLgjHorXby6+/IO4Phg8F//+69/EtUqDRTCXdz/d/VMLX2ciU+l14OtUZbRW
+FJ81LEc0N5XOs6KMJdiLjFcLhS+ErGOsN4PUpXLSMW5Eu63r8/FsydeH+sikcgsk6lIdEp0QFuH
4Jz1hRJzHSUylUKSLBlJkRRXYcAsMIfxu3+FeRBJsVQpBkmS4c7OHLLkJOHs8i/np7MTIcRYHBx1
xy//fEnjz1n/h+JSRYkWbqaWRQxlPeEXqSRxtXhfyFAUUS0GxoMluP8siGbgM3exJ0WS6kQuZbo3
IElqhudvz85Pvj65/ObszezrtyevTsH5yWgE1osinueBjoUfZ7OrIgj92ftCpR/4COOl6MWwWl8E
cS56dJz2MfC9Q2GW7PywAw1F7z1oOs4RvyxwSHK+Eq66TULtK9cZOH2RYn3kWooY8TwhM9EL5ZUK
PWHIWFKDsZivUhIiVLFrl3hiYFcbLp/4v8OhuMA5pmpesHUOBSmgIjiMpPNMdAa/8HF46d0vSRro
2j1kkes0yGUeXGumBScp0hg+MX/nOjH/IDe07YvR7Qi/vjjAo/mXxYGoYu+70R7+lLtohzEVef6n
jo1hGH9GJqgsHGVLY9UHPb1YZCpfMy3rnMG+k6nRvAelBPuV3WKHvy+iRPkYXsgwU3ZwWcjUp7Uj
M3CzCkJEQZ4Wqmn1YCFcpns8FqXdIRrH6f6+pXIsDh7/trmLfvkq1TciVjfibQHPjNTp7VwlpLHr
VAdAERvJEJ4RwVkd76gi8ak+eDCFnDr1mfWExJk2VrKIvGY8Jvu3xaDV+/tHrbErmPvdJlZEytB6
gKN9BWJMk5/aZGnlrrVsd47ZmhOgsyDr7YvHbRE+tYWsjojsf7SmACYacj35yhMvXghY/Me2VcDm
YCpevmTf89pkEPZ5EDeJNy3MrjSZgk9WXOGcXeN/JdE+H0KDopkYm7PZpzxWU9xmmrZJmjtsgAVR
Iy1YmUysIBVSHv5KfuSMNy/zOrkPcrSg3C0xVQcxlsxBVnMdeK2uKX+LiaPfOWJ8LK60DpFsVJrq
lAdMZGEonUMCHkLs4V3K5gbzMpniMb/N7cvUZPhWPLezJUml0r7Ymj0XoZb0gijRBVno8WBkF0A9
GkBlOhQyTeWHMvzNwkolju2WTo7T0ufRQa1OuXizPjZDBJweUG58Hc0giwsCz589e/IMZ2JWZHr+
Dku+gF5KRjN6VflsHgaoqK5T+MnhcOhQPjQGwJNzyO+kFI4Yssba/AWJfmUA62jGkYhq242KfGLV
JId1qF6HqHwGErjMwFAkhp5Te631M6LQdL9SfMhuBXCZa1+4UNsrpbKvCMTynB7Rwem0GkAteigO
RvzzrBJfLG5QTFRJsVtQrS9YP6AKavf1KEeScRdUG8rtT0e/e14uiIBdxLiUfgnpaWTmy1ya5Xbh
Yh7qTFVDlWkth7GtC5TR6yHH+ZzNdwFLcghPDCcOae/PsMSZeuKlOZAqw7ulbRxx2J76/MHwnzz9
0KlFZQ0iIsiCKDz/c93xVSSzQAIDACPk24rPCuoWsa3igT+MF6FcZsP4PR5lPIxjPMsUoVYmTuLB
UACidavUauIEPiy4CwvTWf+vohPOBMDDGsLClO9wNvi7RQc+PZMJ6PRIDNYCb1RPRl8dddYiTUzp
DWWHMp/nrm15Cg+3vlTmdsKtjSqHmg6NA0YYUBZnRUTeQ3163d/vKt+GQdaMRLdTyJgVSs/TTapu
Zirj/5cpnx4zRnyLY9Fyw031/95HiYIfzzvYp60TK52mTT+kbDGM0VVl2fBNnofDGNKs+SAJDDcc
eVsseDDqjKd+AwA0aYD9xCEW0y2k6gUb7EZzJDE5Hxy/0QM9eFBb0jdg6+lmNMVe6UwZoqBnzGdx
rhPe1TGbAGhQn2WLFmsjD1TARrPSmkpqnNz8WcyM6RdNPTZRZzJhCWNTH3ita8uWIIPGQfgExEoY
tm1TYuBYDcZaVtliUSr6xqbEdJsDdjMJEMe0BVU/ocHOqbG7JK+XVzBKT32ufvTUo2MUrD8qdNlL
5XobwKCpBQb7iT/Zrl/kmlr+dtdft/N0nRDQAoVnA/k0lRvCir4erKG0lZJhvprNVwpR1cFXQAPA
y8tsJsPQdEW27H7UsaKHcbnEdWiojN8eVfec5xkutBZx6c+BNN4TNhu195zkTZqI7RxFPUYXn6O6
ytypgcEcmZ/bvHLfLldsG065pnzjlpMetW484gGwbOz7LeEVklLGkrMhZtcyLFTmmpcFiKnUvkQy
cR3q26FGkqrlLEvCAJBv+N3bIaWhUgmyMRFFU+95NWxkNNjsXKubASsDXQDQU8uHgoS2fAG/oamr
D5SyQ9eue3lYETM80mtGxzTLuJbXwehBYl5BbTLiZolxMtJxXmQGN5Of0hgJCVfhwbgIqQHwAXiC
0MLraaMAGqwKomv9JySZlPsYr56xu4qY0Kq9WRJ8oxSreIUe5pvzQSMHmYTWJUrAr+4zDA9oRkAe
rQP+OXj8mwEjYXK7fiPnbihsuz1pgnpjWlyT/40VPNGxr4DpiIuso3tAlzhbk7KsgQg57YhQ524Q
z9ivXIfEJvEfUwcoOeX3OdFsTKprsu29tWL1BbCdMTF7mzC3guIHtscn4UqBGOILMqSPXGW5EhVv
s0/dBhj1BnubdNlYP7afyZPPngkVpA1Fx7ofqJLzrS+og6bM5Bw3eNpWgOgEOFwjStcIV2Ih0TN9
5+97Q76huqW+LNpawjqCmf4omhxMN1el9bqzoRKxocpY4+pgX9ZpsgtV7MfGMlvLLRO2gV12ijOj
8oYiX29pOvtFw3uMU5kWZgnn0OQ75e2ry/5lrnzpKpbqkaR768dCFyIL4nmq4+Cj7VIp3n3pdQOF
LVQHS6npcZnq768qwvm+Kp7khQwhGSrk58Uxhef+MpT3zveXJIirS/TSrhwwpSGQW44wJ63ExpYL
HZR2X939Q0Qq1gwKnokoiItcZ9vVurcqvspkZaZ76/PK3Ln9mkrIRkTbplKDH+jmYmBxDxIKdndc
aKNSvw7gbO01mA8Ct9ptC70mDiMigzq4+Okb10MaY9FM+eRHqpuGnhm0L9MKt53eqnmR228l9Xeb
vuB7Y9lEZ8BsJqqkiApfxnc/ST5FpGaajbVYYfLulzSYb0dy6KW6OK6HhHdtM7NdBQRRQk6eveCD
3ghHaHpSKclwYWLSbKvQN8hMeplFHVNj49qRWram/qotloWhXRGwrinBOu8bWd76b5ECQrcrSC/I
vpR8u0fsjXizIJshYIHdI7cpdPPSF5xo39jw3LX5l2DnFjpY1r0CMayxZdeS6+aTUC9ndNQaRdQh
upaapPpUaWWey2AjR6RqHbVvcarUtVuzvS9X+nKUKL5U+a/5Nu8WDRSmy0VD1xw2aH6f6XimYgJD
fMh98fsLAPJv35xevDo5P32Np29enb0+Lbv3si/C0iq+7v5OXxqbUWQCCw8uqg5iJy2wC+EnPwYo
N9vihiOiEzepvGn2Iw3ZGzeU5Au00DYgL41WvrJayRuL3sRhwwXL6/7Moj4iRBeHTPBwPf0wQK9z
z6iTdvjG2hrkbJMp7n4WpnShV6+qw8GoLA/ey21mWYDYyrQ8LBxMRNdh1kJWjfIulOO0ITnQdLsf
27Cg2Zk9py+v3e+C6zFVfVPgmY0SVXDaLuqLSdXTtAtZv4WJSqi9VYwr6S/VugTtz5LoDSmVVtHA
HygaPzoxGus3kQd41xsq3NDYEKsCcD3kXdUH7dautmZm141M6VrMed2aa+5qqF/xKnfRB2Rbs1t7
2JYdhVCxgEHKXXw7cfdTtc2m/kkvZ+Rvvm1xeYC1JtaSpro0NC3HW1HjvMgSGQu++xvv8YkI/u8j
Rg/EgMDD3jG9rsqP5DT0Ykg7j50qWC7qOxQCKGWezajYmv+HoZlZbAhtzSF2e7aeSLqFrlF/OTmv
RRzHWjNDl8CkKqGNwe13FZ3S2ReLGAUIqQYndo/C53Eg/AdQSwMEFAAAAAgAEnhCXdAM3aENBQAA
Vw0AABEAHABhcHAvbGliL2NoYXJ0LnBocFVUCQADFMe/alHHv2p1eAsAAQQAAAAABAAAAACtVs1u
20YQvuspBoQMkZYskbRcFJZoI86hObiIIRgoUkMQNuRKXJQiWXL118YPE/TU5/CLdWZ3KZGK4vhQ
weYOd2fn95sZjm/zOG9FPExYwe1SFiKUM7nLeRl4zggP5iLlkd159/Awm3z8+Nhx4MsX4FshR63W
4Pwc3rOlSOMMyhVbc7DfM7lcJcnFJFtCmKVrXkgRZcCXcPfy71+CF04PErEUkuGuOg1ZsuSp5H04
H7TmqzSUIkshjFkhZ+Uyy2Q8y5mMbVYUbAftXJY9mCcZk9BGzZ8OL2z7ybkGciFdtP5uAf7aKQRo
xiqVNl1Eh2hXzMGmkyAA1wHNSb+Cy1WRQqej2Z61iAhFlDkKlXO78+tZ35sDPTo9ZcuTO8W/A+1N
jZJ5VqAWgZfdEeA6JmMuwKOXbreutp27yKUEoA+22yN25HSmoxqPV/G0RWPfP+xDF7zG2eVerkht
rV4J74LfEB56W8XpoQd4iLHyibog05BwYAA/Ndh3yK5kUtB7QGabZJAQby/Eq4R4Wojj1MX4WqvR
hRcuK63eKa3+a1qNLiXEq4Sc0hpBv5ZPeL9P6KkHJRmDo567njJZPXc9Y3el2qlDxuCoHY1az7pI
filevs5FmEHEEf1pzBCUS+BimyGYUyyPUooETzPIGdZbcqoW8B6vimDNkhXHq+Y1YZ95gq8a+9CW
Qib8m1rYYPg81yU4xkheIqUPchbd48aVP1L0BGnf1fQj3flZ03dID4fVnSSTv1H6NirWJEGvkxrD
B2KIzcGjWe9G35SmdsfEkLJL91K41Sk2p3ANlcEyywkKeOj3wMZMOiEXicIFnIPX95x6pRP3Gfiq
3r1G4eFJt9so9s+s5AqUZG/XeIGdTrskSzx7mu4LnLMwBp2TmbbyYC0rqdKCG0xWQ+fWiL9XNZLC
DXjoKLKeV0EdgKlVcnm/59dBTJWgbSXIr/GYfHEqGR/qTQDLf0pmtwm6BNz1tHJZu1WuF3jeGdOK
Y6AsA0shzoK14Ju7bBtYLrjQgT5lu4+EImMiLSiyhAeWWC4sRKNgFwqLgUUssW2QqDhvOkdxe6JO
R8lB5zQ1VVFbNOLVdHXxmqvkQL24x1QyDZcuFoWILNh6gXWG645WLHPc8c2Ob3YGN6rBY55M1Cqc
T+jdeU2r5FvZ1LpTQUEtRonRcXNWjgfEvddFWR+SAgTHVQ8DOF/KWbpaouOO0+gxCtk00uqxUv4G
J2annpoK1T0dzboHOPkZRVld79ea4/2hG9bI39FankZave6BJPFoHh4rMWHqjMmgZnhIvwWRBo22
hgAzqBDzo/tk9+G+8eLo/h51qooPxZnXA3g6n6EowuQIR1GG5RFuK/iEVUqhCKwr62ascI/5vQaV
Y/U2HmhJmO2GRl2mZpjgLKG8m5ZOwx5ub/GTxGmgIX/yp059rFWQMJ2DsCqcfddzj518K3C3NeAq
93YKwUfA1aZTn/f808YfWfrcalLNsanswkQPkKAUmhn6wP9c8ZTBy1cCSM4KBhmEaOXLP2quRjhE
GbKc/I5E9j+aw/PkeBzup6PnuW+bUzSF6KvqxLjyKs7/ZXDsG/nx1NgcTYyNmhYmI8PDhEDrqG3a
OlNDpzEK3tI/hpXMyq8fNY4I7l16Usdob+g2/Zvb1dd2fe6oPL1t7uQFL3mx5u/KnIdywjDbgZVm
1AnUHIpFFPE0sGSx4jh79nHsH7UQpfL7LegE73fbTQ2x/wFQSwMEFAAAAAgALXhCXcSLj291BAAA
pAkAAA8AHABhcHAvbGliL3NzbC5waHBVVAkAA0XHv2pFx79qdXgLAAEEAAAAAAQAAAAAhVbNTiNH
EL77KYqVpZlBZryLlE0EIUAWS+wKAcLkhJDVnimbDj3ds/1jIGGlPEQeIFEOqxxyWuWSq98kT5Lq
nh/GXlbxAdzdVV/V91VVt7/dL2/KXo6ZYBpjYzXP7MQ+lGj2XiW7dDDjEvM4Ojw/n1ycnV1GCTw+
At5zu9vrDTd7sAlHp+PvT2DxKn0N//7yK2SqcJJnbPlx+YfyK1DA5igtwnh8Qg7e5wymLLtVsxnP
kGy0RjBYQKn5govln3OuTAqHBlSJ2iP9jQaMmpJZhtpycmO5MoAeS865vAfjo82QW2agRNHGHDqj
h0JlTAwFnw5zaaZiaIzYqs5Tog+xVsomAw/GpbFMEHgF0i410JZBveD+e7zYTrdBOTCOEuRKJ2lN
DCBnlvkAwxJzMk5/NErSdrXyKB3mcZsmK9mcbdFSgUCdrEEhZfEEVa0AQaNxInzPGSz/EZYXrJWM
5IjRZJpb1RVkHdqVQrF8CNWnoy4VY/mJCkKOjQxEPOSZf4Y47PVmTmaWU4KEOsm5Ds0k59A3bgp7
EEXJDlRbvZ97PlY/p+2mryCFaNgkFdEqDn4be94T9unQb4a9HY+1GyD4DOINbkK4fp4kUCH7z0Fx
W+0O4OXXX70cgNUOa7cP4a9G67SkNHZ7H3wvb8KoErZ0U1FL8MRy4MstnRDUBU8dLYk0qxrYpV6G
FRWqQsVEfJ9pzR4a4jMi3qiUBOadAker1GZcYNyfrXCrM/fZdAn1kXA9xITmWeUY1yVIPMZkjnaS
KUpaWuMBVxSpESleSDTuY0KiE+BOHaVW6Hj5O7iiaeblb9SLvt18W1eK7MMRLpRYoO+anOUINNYG
507SvLYafi5VhUj/ZO5hgmZc2i8r1pmuaJ1DoxlRKNh97IvPC8KELYgJNOhRhK0g7BrHN5qzDsmS
Eb+GXtrSo7vBZ1oPi/bMBJPLj4wuxwzD/D3PUsdBYuhX+OtT4ev+rCBhFnyi3U6wN1rdgcQ7uHDS
MxpR8NLHi6N3VKubUK+VS4HqkTltKLvDuWOaKvTeIVjUBd30abQyInWOVxHPo+smJpViyuX2Dd7H
mlFZi8n0waKJv0lq39brvfPntSclr+7idRNnueA/eQXJbA8cXbGS+VrVdqRXt/T1ri1K2g2HvhfS
Cm3LXxHPpvY6CU2Tkl9nvA7CXJSuOxdkMahmCGWYoTrTAbwbn51Ofjgdjd8cno+O6NvbN2dHI3hc
PxifHI6PR2OKuEcFmzFhsC0XPZ0bBxoDwypUy6Hbz6sXmZOCy9tgX/P/v8qfhrdQcSiVMcu/Fiho
OOac7hjq06avqQ/aR2Ct7M3N2K1+GI+VZmYZUxPBpijaq56td3ONdNWmHWHBLdeRb4jv4MUorFae
nRO0kYGRzPRDaV8MnjxJN7Vg3pU8o4tq1XWNOsYZDRnOvbU3ftu8X8+9b123G2tLE0GVXXQoaCzI
6/jy8nwM9PODz5ldflrz0VioBT7lFVZfyqu66KMmgHXMt7+u3/Ta8vqqz65hny5g5mX/D1BLAwQK
AAAAAAAteEJdAAAAAAAAAAAAAAAACgAcAGFwcC9wYWdlcy9VVAkAA0XHv2pQx79qdXgLAAEEAAAA
AAQAAAAAUEsDBBQAAAAIABJ4Ql0OePCU/QsAAJkrAAAaABwAYXBwL3BhZ2VzL2F0dWFsaXphY29l
cy5waHBVVAkAAxTHv2pRx79qdXgLAAEEAAAAAAQAAAAAzVrbbtvIGb73U8wKwlJCLam7wPbCluT1
Jgpi5GDXSoJi3VQYkSNp1iSHmRnKdrK5LdDbvkHQi0Uv9iroE+hN+iT9/xmeRUk+JECFRDbJmX/+
4/cf6P5RtIj2PDbjIfNazvHZ2eT89PSV0ya//krYNdeHe3tNyd4R/AxIHHkTuIq5ZAELtWq1D/ea
EQs9Hs6Tx8nVJKJ6gY/3+Iy0mpPx6PzN6PzCOR/9+fVo/GryYvTq6elj5y0ZDAbEOTsd45kf9vCY
JnWpAGotpSVQasNufH7h4H3YcXREHAcp42JD3W5AQixcciozUobcDGg1J09Ono/GF05EXaGZpRLG
vn+Yr2NS4qk81HDk7MKBayHtytdnz0+PH09G5+eTl6eGVDvfaFgwm4GDwsqTlyeT8cnPI1Rl3fMn
p+cvzIIit/iZ+VQtWsn5+8Q5JTPuLhiXgqz+TQLKhSSeIO9iRgQ5e3qGF4prRiImA/zZiiNfUG8S
0OvJjPtM8fes3XUKPH8kzFcs4/ybMmenz5Dnb7iaWELMM2RaqUVQOzqIJiENQJXtXfyPlCv8BQVm
fz4BZikJxZKSJZNq9S+xgS1jBjwHeQcjDIG/x5MXx3+ZWD7vpjOPBVRxCnqaSxp6oCkqKVFMkjjI
OEHOHr8c//R8A0vf/BiIJbuVSvZJGhU7lfMST54JTiKh1Or3JfPJPKbSoxL0lcnAAuBO0x7VMfX5
e3Bipnpd8oZJPuPoCFRZ6wON/zCFokRUaWp31QhU4arJw5lIIpiHKmKubmUiHJaWGlWY9ReOuATz
V0jh58c49Hl4uYlEjR4SgknMVdbXsmyIgAkmUawnrgi1AaQMjbrE6f6iRAi08ceEha7wWOvCMRYi
gyEpmi41m0O1eRaKq1YbPLvCx976b5J5gIagrlj6LadoHyfd/rEWqlwausyvgNUWxVUf5RIWFt2b
GzC6plVuUq8AIDDOnnFFjuo9hRwQ4xSowhkFm4FGrUnxjvX1xeoTCVm4iANiwZi4VEo2h+jsOm/L
sLrNz27rQHkAY5xzcAVXBBD/II7dktxG82P+gzQ1Pjl9CZz3nV3R2zhNZUCQyZHkQ5X0x33EbUVo
qPmcpuhNSaJ22NpqgEEL56N5211yhkC1FL4GPKBarj6pfRJDLCBuuavPEQdiDJBsHgOwrX6jtwj1
mRQBGLVwVtnLmzIBAhpF/k1m3ETFNWjQlA9Cgls5dvrxxXyy4EoLeVPwb6gLwBjLD0a2j+S/f/8n
Wa7boAEiAKuuiEMNKQWOyQBWHabadOD+lCqGiNCyyz02mVL3Mo6cNUQo+ISKXZcphYwcJ3yBmU2i
2eYYpPWhwNTHnCMw/hNICzYZgIMULV4kaETuNm4LmZsUOIF4XcA5d1BkPVgXVJIluWOSnrT6DbkO
06SX+f+BUfxmql8UeiWLRLVIBHwDt88sv1Z8pnbJCtACg00sdpOgAZZaYE0wE3CBPtYzgiH9CrZF
AHpQomkXNNX7G7gZn4vOsvuHv3bf86jZQ0zDXe20FksgGI7aWVQ8qkEGq3RMg6GWoPH7FgV4/t0r
gi+S7ndCl1lUhS9guB67Ms/Ygl/4eSDmOOfgbopbz/doEWisgde5KmisACuGjt4OJ5BDqtiAkCLi
HEgg/YmEiTXY2Kr+GjtCZCfiZCEtLZe7Atqc9GVCHILc5A6wu23p0KhrNUvWXiZLt5S6zYCBmtfr
nkJmggrIlJUeM2VlChemIJ2zrQVpe59oGTNTLCX1jlmUVqHYriID2TXijS0zEBmc0haKmYzkW8y1
AahD0EvT5i2ViJtcma4desPXkdnJQ44st5yarhEx4mi41/f4krhgejVozCX3CH51oKIJG0PDTV+B
GsED00VQ0nnJI/N4waBlksWnHbxVWGKWwTHDNS/pL74fniTlaTmP9HvwaH19lJ4TxJrBGY9MfWm6
5boGFCIGrDXjCJQ2SGEltlAefIdx6EKniHdVPFWa63j1Ozzo9ntRhfleiXvgzchcuFNQotHAVHg3
EDIy6IBw7mVVGTiaSbBVsncXDtr+bfuAHNWIXCBNfSY1Md8dE3qN4amdEjAFhaoZFJhg1dBUUsKu
wU+NfH3wYRHOh3BOv5f8DvrmSwoqgh+sg4ojJ+OzgIZ0zuQ+CQvNMyuOIvZt4RMJtHpqMwnXcPUu
5t2KsnJ5s2bbynwluaZTnz1I8EzatEO27DLlInUQQtlmWaXcg7yq6GnYUUO2drmi0IdD07aFfwj2
2SGyusGYFn6+/TYNYJN4DkjTDSKIxbUWxS6qb1Hah7tUAkFPNQNHu26sL7SL/XQtKECrDctSusO+
p4dPkkoIdKDhhjfsHw3IolXCMMDHITz3hjWKqiX6JnUjkXRUGfVliXymiXufkJWc1ROKmr0r8VQn
Ku/pZEU/s0BPwjhomUo/FcfgLLYV5kRYl9xXlzyKmIdYDnm0ryIalkCNqID6fmPYwiRrZ2XVjd10
iFZ9gCXwd4Yun4cCSkHhkIPCVVK3HqyjooHENoADsDM0m5y7KuoVBfBYVH0HdTO90UylerFTv/ad
7TB+etz5/oc/peQznQkArkRlJXdSCwrLb+dN8Mjf8CSPbgzjPvljPVpl67MMFeLsAL86V1RCMh0h
ROcjhXxmIPKZwbLqyJUpQWmmCZuZ5ELaqQFAnC3XVGVqsJbNyqJlw2KDUuA/9xZw9Q9gMGCqwCJK
9cvqE+Cxhu+CVFnSN5IRrFyBdUm0wMwM/7JeeSf/GSrXrikgpknH1NQyW8GwbPHhbo0gYRBcL4Q3
aGCF3CD2mEHDemRdhQsUG2aE2zGxKINBI6+EMgVuBsgjAvqeMcxy6AiqNEQwTQA2nSayTeuLXmGC
vLtFdiv/gLhKzqBQZL7XMuHDwyjWRN9EbNBYcM9jYYNgNoDMDM1SgyypH8NFCo+7TpjGWucF5VSH
BP53IskDKm8ayTlQkwVc26CGLidsOZ64CrGMxRI9Lxu3JhF70hbb9dB4u5xhu489zAe+mjHSIfT9
jDFfGBnKpniUkHyYXjfg8Na6sb5CNErP6iF0jQ7eatwvGFnoWnGD2NccajRthOhgkG6qse5vHvs6
cxNdn05ZVr4Z4sR8d+ZSXG0DL5O/z2yWaUFLlKb0zTuK/GLNknJrUxVqz2WRHjSwQd3HwQt3Keqz
B9cNkrwy9kyBk/cyWIPY0sODyhqqfA/LiU3+YKTd8PAuWHE7JjYAim0lAVAYoi+HBLTN0Tc5eKVD
TSuTM+iO2DULwEmJF6qp31l+1/0BVdolSd1EgtWnax6I5FUvx3KZ+eYt8EGaB0xnj8xCXQAaMO8P
RaGoSBn3xCE0tp/xVpp0sS+KBDfVQZJxqKxpdTcAXiE6waPsRCBphL72gGDMoXIK6C0nAmkvwKxr
Qs8n1Bdq6Nc43tlgfZUOJSMKnlEptuHOnamMsilB5ImJeufzQoeWR5R9YIOq1LRMqTdnxHx3xGVj
iPMEWmwkNq72aDhnAIGjAN8o6nzTnTk3c401ljMQ+H/hd+NUoob5fDyyU4IxD+7E/0szX9vJe7kp
qgeA5O7eFgy4Rfyvxz7G/aO6dmYdBdZngpJDgEFzFWsRQKpyKf5BE0vKZIQ/HJWXpo1dMkY3CrAf
M1uVQVz8u5Rno9HZ5KfjR89en41BWbZvk8xFkmo/++sN+1qot48j+Mr7vFL1nZ2/ZO/L6FtScBGP
ilhkXKJzJWlUVF9hnJjMgdc7llxNkIX0DTggqOqYh14y38d390kDiWPTyKYXiinENQrFiWAkV58h
R1W1V5ajvmjrG9ZLclTxVKPUw76W8H+RQma/B7/j9WOKEZdcZLOG5DofXNkb6TmSzxdQuB7bSZ99
2sMDevawCgOI8nX5EHI9o+4CWsJ06g4e0pxuGFxquX7TPshHXtO1VkV7G3flHbe1fD5Z8bQhhaPA
bKZyL0LJiGZamc/cglbNAGZqp193kCyx09fosZMTOP4lAqu23PjerabfrlrnqPDqzZyB8wla/94N
lpYj3oQXhBGkDGbezn69ns+8/W5sW57OVbItdSZ7QMtoflPBAwvzOPSEKcqNfR7abtb5n0GB+so3
Cfa1fh+2lPEBbiDza9BXKp4TWC/kzP8BUEsDBBQAAAAIABJ4Ql3chZKoRwkAADkcAAAVABwAYXBw
L3BhZ2VzL2VudHJhZGEucGhwVVQJAAMUx79qUce/anV4CwABBAAAAAAEAAAAAKVYS28jxxG+61e0
CcEzTEhR3txWJAVlxXgXsCKF4jowBIFozjTJxs5re3q00tr6Izll4YMPORpBDr6t/liqqnveQ67i
EBDF6e766v3oGZ8m2+TAF2sZCd91zq6ulvPLy4XTZz/9xMS91CcHh/6KTZi/cvvwW/rw25WR7ruH
y29nixtH+s4tOz1lx7idatgGguE0USLhSrjO9ey72asF+wP7y/zygolIKylS9vfXs/mMEdqpYyiH
U3EvvEwL9wbY3OKiQDTcWQvtbVEAuWbuV4eiz348YPBZBzzduo5QKlbOgDkzgOc+Z9HTzzHw8mLz
fIQs8LwSvlTC026mAiAzu6nTh+3HA+CHOCkwvbkF7utYhUADT04Ya3kXO2wyZYfixlGCp3Hk3AJH
cZ9IxWnHCXmkBclhVpc+13bLuSUduc4QHhk/LM2jC9qcHJBih8vr2fz72fzGmc/+9nZ2vVhezBav
L8/BwJPJhDlXl9cLh339NZ7E3zcO93hszO+Ay+jQJuPK58rJTWTUACXoCT+FNvQB6cAloeum8C/a
9AtseypH7w9KgFzpHKBFaw8YWmuWNkBpnx0A5kAugaG/NZ4ke6FqFUFJ/0JxUt549Ab2mPMm8uX7
TLCYGYojx0A9MhGkAgHDFThFBSJqQvfZlL04Pt4JfWkhWRL7goG2LAIuT5/uZRgjIfO44h6si7Tg
arxDigoMCgws+7Tk2qnqaQPnK9SPAx9OUWBlLGxN27mxK5KORuwig5BgnJmzT79geoCgWciZTQIm
I0KGFMH/T5+GAR9KzlIRMp6yO6HkWnpI+m+QFmg//2tOJ7n6/Fu3UWYgdgFvMjLVT58YUR2xKzAJ
u4sDTZKtghh8Q2xZltbhWcRZIBEN+OZJ2/bec+2BQoJ8URYEJ5XFwhFQt1KxpOeHJuigbnUboAPC
7JdoJE6BCHKsOQhZFaJpLfxd0j9WQsSWPDpaU8Pb8mgj8nJVY91IDLREtW61BLFQxm+G7CW4wGFH
rIl1xJzPvzlNUVtK5yyrEb2fbSU2XzLkXIKdsnWol74uVvoMjpiQMo7p7xTI8mjy/hhHYhly9W4J
HUE/uBUAEq3Ww95enZ8tZkXzup4tmDEltq8BK3WsPvvLIN5sBLa44wHLEggVWDNnGv2vxho+1VZY
N/+gCNQBlJgPbh8WTLOs0gPj5RYSJoYAzrvcElqfhv/OgPziSV8hnAyTAGqW65ww3Mmt1QAka31Q
UoulabmNfduH08zzRJoCUO/HkskjW8cSsj7jgfzI/fio1+mtHb15AO33fdF5c7EdKCUAZZqrjvHg
bS70I/VyZVCxe8NRpU2fwckFcWSyNKuEFfmtXVy7xabtxVmkEQcW6bd7iJl+mGhl8O0JzPJvwLNw
DLbcUliMVVNrnjEfWa/Z+AAJN8IEzOX8fDZnf/4BY+Z8dv2Kfffm4s2C/em4Y3oqWNMQhZC1Oeos
CNB/p9ODcTIdc+aB89JJb8W9d8NARu96bKvEetIbn07YtjUpsdNpb4pbEqYr10EqnHjwiZaGaejg
oe9NZX/6Z1qU7PGIT8ejZHpwMPblXc53o0Al/BqGXEa9KflwnEIkSIC0h6B/+naLtreC+9BlK7tD
XKocoWPAZtpMLiB+kROGcRQbbbY1j52CnNsXHaRJQQmm9nNSrE5RFromFMhGDHcaoYGBBiPA0y8Q
ty8rT6lDDJOG8KOW9IhpZoHlivsbkU8GyLC0zcgYp7JCI2DVVqvYf2C4OgQADzweCr2N/UkviVPd
Y5xs3xUBlI7SpAsVHhMPLSm9VK2XaykC360JR/sySjLN9EMiJr2t9H0R9aDFh/CE82yP3fEggwc7
ybbQ4cZie43piS+bDHLX5yrzQCjN6HtINOC3LJgaJLCC4N62gMNp5/CeQMeBzGPj3sQELSAV+M4S
ntAGwnX5y56V65OWFQK+EkEuIpmq16FGmvBoekHVfzyih/aZqj21uNe5NU3TAOfye5hpN3o76cEs
WtjXqtacdMGfUIvfZ9jCmhFJMu/0R36/KcfUtm+qfiGlhyr+0KX4s8xTmmhWTg+77GQOiwAqizWQ
GR56DKe4oRn4usmINE6oIlnrmcGSjNgcPCeVwRPTnhmmwqe0x2SfXtAuc4m8MSYBiSkpNPA0RqjW
5ANo/fHIyLZH+HqsG12XhiqFFMWgf0dJfdedT3ssYePoHYXOLnsAerclLPWdSbDn6VHPvm5Hjwyr
jsjqimLa6Ai5amgMcYLb6W9zl8WLKqrGTF0jDfdE7TkQ7Q3Xamoj+14tcun60Z3PtfuJSepQFiUd
oVznh2E49KGiw51XQ/qHsPTHb0DjB2jzHXV9p/F2Vz649HRX590tIM/Jeprta8VRrAXDr+EHrmCA
2HvvHMAVXTGZpjFLn34t3gWYi3sKKckD4IdT6v99QW139H3toFoXsTGbHpx2ab7KtC5Ho5WOGPwN
EyXhPvPQs1ZNs1UodW/6remiVi9zfx+PDEQHNm/CbrY0EnxxJHzFI08EXOGQty86xiNUz055Izvm
wUhIz7936qNBD+a66bnQPNiihvBgOHfMQxVbF+NQa3QsKgG2tU4/ELqvp2e+9EBqCBrgqGHJr8yF
toh7+F6F7n+OGZrY5/+wyuBpt1cP+fiJIO28KsPITEA3TnmxBEqaWnKxnv4RQFLz0vM/75GvBtOQ
YF/ctgVSIozvOgWa447cZ6UabdtK+XaHlb4oYy7EFaSJkApfD9vxOxen61IQxNHmhUzgzpdfI1vW
2c3KOOB3cKLL55f5lGav3DPqJv9rHAqY5u6EgoLnXi3m/X0y0KUWX7biWz847PwPRoYTzbZQu13a
cpLGa21+hB1FReO1XplLRkKXjC4H3LZuoangytuSuAuCwIr8EVKyuHJWxMxtWak+dvVgTwF6RvF5
DS3g6VcFIkEfSKEpSexd0MjineWoWoo0XwXQwxRPqjWPVmtHmpVKI+B0rBX8be1IAT/w4cxmvX0s
q6NdeKuleSejzNIIQUYGsMEEa2RXOyvvT/Siobw9teNVq/ai2fDLXm70r1eG+476CWL6O+GmNF6V
bzbgrszoe2iA7WuWJfRAQfCm2zrVyCpP0cjTPmYHt72CFOEigmBYVQ3RfHCHDNK8lu3VpyCC2UPh
pLSPivzYPXrsmpuBpO5hWMBgy1OF8qOSMf8FUEsDBBQAAAAIABJ4Ql0Rer/qwwMAAFQJAAATABwA
YXBwL3BhZ2VzL2NvbnRhLnBocFVUCQADFMe/alHHv2p1eAsAAQQAAAAABAAAAAClVd1u2zYUvvdT
nAgBKAN13e5ykWUYiYpetLNnO+uFEQi0SNvEKFEjqSTe2ocZdrEHyYvtkJIdyU6LohNgGeL5zvm+
86OjaFzuyh7jG1FwFpLJbJbOp9Ml6cPnz8Afhb3qXbI1uGsEbB328bkyXPvnrNKaFzZ1B97CtVba
oGV1d9XriQ2El+kimf+WzFdknvx6myyW6cdk+X56Q+5gNBoBmU0XjuyvnmO4pLaiEt1DY7Uotn10
d4AV8Qb0GY+BEGTy6ELdU3gJ7Qyn4EwVmxfBziB0TnXLo3YxFvGY/SAuNS+p5iFZJB+S6yWU1JgH
pVm6o2YH7+bTj+BqYODT+2SegGDoOD5SGzuI+SPPKsvDla/eighG7u4OAB/lWZp32HCb7a6VrPIi
PChyBb04ct9zLTb7sC7aqzpK/1BKH7duxwpLDWSCoiW913TgAnCoS108/aOAG/v0N2QKm2npa1KL
+nJkzNcpCpO8CH3F+xDB2zff4PFt6ZJZngNzfxpKLhXkvFAGo0BGNc3wmJtz3rq/FzglvnnfYDy0
8Olfl47PKVOiyARyZioH+oKmc76LJmqHqNP929nNZJk0rV4kp3OAPT8ZgFbfO9A6t1cwmywWn6bz
m/QmeTe5/bDsYxvP58NdUm3TnTBW6X1ImkRSn0hKJRaQMkqOzu5e0JyTdgTDjRGqSDXf8gIdLE8F
C62ueAu0kU4dMVWWIRwjkll3ahqu16TlpDkTmmc2rLR04nCVSNLvH+r7pTeOe5FBANJDhgxmFGDj
WRB7RLTjlOFktCwDd9SYPYSJ++en2umneOLF6G5foyFautDyEDrHTmDYWyuk+JMypSEajwC7cVY2
GMfRsGwJGB4VIIHX2zxtlM470teK7cGdDoyl2e8BDrvdKTYKSmVsANSXYRTUzL5iOL6WYsGQtJ0z
AjKjN+lGcMlCZ23ZcGvXL0kzsz+3zYeSHXRRybUFfx94fBBHlYzrKCiV02x3DAXUwOWjDxhJETcV
eqxL4g+cFy9Y43jlDS7csNOlI05srjraW8J8agOtHoIT8ZKuueygoMZuPTgyJS3i2flCi4beEomi
rCzYfcmx7s2bF4BrLlbDAbERlVW4HErJLR42n7LBM1jzPyoca+aydmp+ROEvZ2vnewS63XCqr+AP
LW25KHAfb+1uFLx905ZqciplPPvajkV2D/gfKV0fPpcv7NTvSe74uf3BDE+Vn05de7rcS1i/bwbl
rytrnxfQ2haAv0GpBYrZB41cU61zYYOv7ZY6RtxZB44GF9yw2XBx7z9QSwMEFAAAAAgAEnhCXRfQ
cWaZBAAAEAsAABcAHABhcHAvcGFnZXMvaGlzdG9yaWNvLnBocFVUCQADFMe/alHHv2p1eAsAAQQA
AAAABAAAAACNVl1u4zYQfvcpZgV3JS1iu3noS2LZSBNvG3Q3CRIvFoURGLRIW8JKokxR+eluTtOH
nqAn2It1hqQUx3GyBeJAJGe++Wb4DcnhuEzKDhfLtBA88I8uLuaX5+dTP4Rv30Dcpfqw0+ULAIiA
L4IQRzotJY6CSqu0WIVBd/7bZDrzadq/hvEYfJ/M1mCc0CgPtm3XrSFZlitjmbO7YH8PgrTQrWG5
spb71lAoMvzlZ/zO2EJkFY6StNJS3c/tBDHsdG8ToQSuza7JiymWV26ULiGwGbyJIiQAb99CWlVC
Bw5xZlavwxC+digDizW7Rn+fxTqVBX4dmGQPrYHFn/kHrgIRGIjDzgMgnmhwXNl8dHuwNNaOw65Q
gWZqJTR8OP1jAgdrOL8ELjRLMeWNqboSqmC5aObCZ5zWhpD/kw99wIB9+iQC3WqdfXZVcuXC/fj8
++RyAmSb5mUmuQh8ODo7AX/PGYVwYDJAf02efNEblUpgOBF4V5MPk+MpHJ9/OpsG70J4f3n+sdke
+NpGfPBoLyvdG4k7EddaBI6uEZfULCN1kQqM0VLoODmWWZ0XdnNfjvzuxZBYrJPJJfz6J6QcTiZX
x1ixj6dTNEFN4er791eTKXiYeBCQHnuoOISj1fAVtkrekrAeeR5lGZEcjzrDSli1xBmrqsiLmeLe
yOzOMBGMo5Q3Vno0Be1Xb5lmWqjKORinpVR549IsQy50InnkoVQ8sPKMvLTg4q6Pbb3hbiDSoqw1
6PtSRF6Sci4KD0g+kVd6cMOy2sxT8dJYbjub9mgIVIKpONkyMWbjCNC5CHxrguIe77DaZOKwHJN1
y4SgEuwSQvCgzFgsEplh4SLvQsm4VkzB6cWe6YssESBrqHWapX8xLhVWQ6WsZ0g/2m/nNDDrW5OV
yHDrHB3q2qdYU+pjLoB9/+f737gmizhhxYpssXZ92qZ+VS/yVAfhrgLJ0sjCJemNppKzCugPAf8V
1XBgLXbVFvcUMIBgcQLNgUWu3S8QjaB7Ex7sqvaOsK62X0xtaeCOJzyPEAtPArBVENw3HY9mI+dz
Qz4/IikK7ngebjMaDiz0hrQHVLSNcVWytm9ybDnsDFkX2nMUlrmeF3Ue2MMiJD5gc7CHByaxTzko
sSIxmwzcd+Ub8hTA9eLANqMb8fSmCazZIhO9W8U228hmR6f3G9P8zws+LBsAkZf6HkqGbX8miqTO
wZHAbJQSVSkLkpGsgNpZyao/HJTboegGeRJjaHg9Ibmtak0pjYZa4S8ZnTDNhgP8oMGREe3jMLt5
HJzYPqraiU9tN9mpASEOLPpWxIXk91tzW2I1RyVJVe0WKdHdrVzNm2wLabfjUQYc720182OMgjKZ
M+1fh1afmr8IN3oisAXjKwHmf88CNy8KLQth4O3B6qCb8E/eHc/NnMheJdJqXBaygSUge/cj0I8y
aa8QkWW9zdoQinsv/A+YDafmRfGalxHCjs1+tem3JIITJN1nci94umy9hwPsR/eJDEu2SgtGNXat
j6+ScrVnbuk98NubC18rTCl2P7fXZEDvTXM+rtHKPNLMqHnn0WU9cLf1qPMfUEsDBBQAAAAIABJ4
Ql2kAwjYkgkAAP4WAAAWABwAYXBwL3BhZ2VzL2luc3RhbGFyLnBocFVUCQADFMe/alHHv2p1eAsA
AQQAAAAABAAAAACtWFtT20gWfudXnKioSMr4BrlMBiwTAk7CLsEeTJKZIayrLbXtrkhqRd0yMBl+
TGoftuZhnqa2tmofhz+257QkLDsmmdQOBbZRd5/rd8752u2dZJqsBXwsYh449m6/Pzzu9U5sF375
BfiF0NtrzXv3YC8V7Ppf1/+UEEhIUhFxkUpgQSRioXTKAplCwkMJo1SeK56Co65/p/NKc+Dx+4zF
WkJMAqYym+GGTItQ/EwHuXIbcK+5trYejMCDYOS422tiDI4jYu3iw3rnfcbTS8cedA+7eyew13t1
dOLcc+HZce8lZKhO2W69M+ban+7JMItix4UOtFz4sAb4k/JApNzXTpaGjh3KiYhtF3VcoUpfBvyZ
CDkqLn2HBtjNgGnWxEUxkXURK81C5jPZ0Bfazo27I9RwjAedGxFuqW/dn7JUoUR79+nefvfZ8xd/
+/vhy6P+98eDk1ev3/zw40+b9x88fPTt4+9QVn4ARQAdKB6MMZzOusAnrW3A9zY8pvdvvilVzE81
vELfacriQEZDDJrTqgFmJeSxk6+5UIcN9ywXflXR6YHKRrg196IGePCBSwGo2/i6uPbAzc8/IbeH
SaaHvow1j7Wax6AG1t717xQ1QOlF4ArgMNg/Gjw93IIPZvvV2/ht3CV8jIU/NXi6/hVYwiYICmCZ
lhHTwmcRauAoLZFCkVAfoZjCEvgab2OrNM+fRjKomtR69KBl0r3OLxLEAQ+KUFMeP00j3L2LEOeT
Ier3p47ddE536z+16t+dfXhwVa98dpt2DYGuUxFPXBOUCV8VFLcG69EcHRUj1qPTjbMciCIxSfXA
DwUeH4qEymCdp6k0WDrFfeuIi8hsOrXn9WOD1wHbhMPGTWvrSpNoqht0I2Epv6VyTCUMmdY8SrSC
Ny+6x11AOzzYgd2jfYw0Z2gn7oAOPrPJHqXrHX7B/Uxz5xSNrmFe8aP9Yz2qB/BiS2wp24BPS41d
wrHrGw8BLcP9WKTuGckIpf/OuJ8XOIlcql0PHqIjlJ714aB7/Lp7fGofd79/1R2cDF92T1709u0z
8DzMYr83oGaVh9ZX6XiIWPLfOQUYTMQWgoXnADMWOWXiUAUJWdq0s4MIcd15fRKkvdyxLEl46qwW
ku+cCyglJEwpk7lPTiRYIbOUDWkHvzl4ozgerz5GKyKNWFo5Ys6YqOUhXugWOZJOyX97n0dMCRYw
BYRVrLMZfhyzcErPGrA7yViKtVbmTirgZieHWM7ykmwUveoKeKi40TpHNqXGphFyZ8rUdMhxAIRq
vqFWhtRdMHEBsgdHmPkTODg66S0j1SHczdHpwuvdQ8QGODs12HFpFixCNJbnjoHeymD0wL+lZZl5
xZW+/gi+TFOu5aLTFdvNSFjoGv84ZfWf82bRGNbPPtyv3d+8WqeWsQKUC3FYYeF8L6YhIkM1ztD7
wOD+JvgsZRhVHKRbEHJsiApdvv5vxFOJnxLsR7IG0+vfxjwGmcGwdGI+DEoPotGwnBsERxcHz0br
s6btQoHfusFv1TrDBxAqCJ6NVsXI29XnVXLH83Lgf0FxWQGVXPlSxL6gISEjjM2CaZ+qvZoXzJ1C
9p+Do6Ec4NBbjMWAMUYF5zINhoT2KjRrEDKlhyV+F5Ga/yJeq15WsfspTpZU5RGrQX93MHjTO94f
ItvYfXV44haYXwX9TMxbL3lIBh7E6Io+CJzKxidZHIr4XWWMbd8Smn0cLifdL86U5bqsWoXHhlMc
5pJo3tzhIQ37QK6umRrYB9VqrfLPW6psrlBxpYSMh1ixPOYppmsoAuzp2YKbOHwGg4PeEYoRgRkd
FL6VG0yeEeFiJvRlPmVo/lWkjUPKmK0y30flaKG9u8Cfc18bsCcj7nOs2xSZK1FlbM37RNAF+vlv
Tq2YBcJH64kHKTjoIy/Cd8UzeklnwpBqwErsp1LzCf6PRVexZJEQG/IvfGkGdEkRiZKMiFGSz88P
e093Dwen9l7v6NnBc/vs1DZrxegxtA6ra6fTvhNIX18mHKY6CjtrbXrDEognnpXoev/EomecBfgW
cc3AsFOuPSvT4/pjq3xMVeVZM8HPMQragoJTeda5CPTUC/hM+Lxu/qlhyxZasLCufBZyb4OEaKFD
3llAxx//gfaOB1gyxnQXdjo5H203891rbYI7xiZEWzE6Mo4xRBZMUz72rKnWidpqNsdoiWpMpJyE
nCVCNbDTWF93VtG89c1BzLlUSqYCi2ZBiNKXIVdTzv+UAU1fqc2dMYtEeOk9ExOdcr51PpnqJw9a
re2H+PcI/75tte4We3oYbqHzLdXlQKgkZJeeOmeJ9QWDqKdq1WRJ0kD1OzMvDy/dopCvUVFQjElK
s8j4SAaXSG/xoGeZPkGLCgOFUF54XlfYw3GRoNgOxGxx0eTP6pA68xEnboqED5W1m7j5tmOJwLlc
CDU7phslQrDEIMQ6RODxScraKmFxB6fIMmAa7aZZQo82KoKSDl6P+fKVhG7KI+a/k2O83/AGlnB+
gxGYcCIVOJ6uP6JhDOeluKDX/L4sUlSTFF58zqGxlNrq/PGrMbNg4bbB9SdAR/AbrMNsZZIKNehd
nozb0hIxkzNjjrmKLNmTIqKxfqcywDKQCqHCjBTPytWadlMwrBSbDeHDEMpQkP2VkOJ2Q+bHgoeB
yW0lb5sUb0paNdyYk81qTkrbIhw3iJY+0o8bxpDC+4zTbVMiuBUSJHX9ccbDfIIooXGiMwwemgYT
TkOJklPeUqnZwsGgH7GYTTjdRG/ur20alZ3bvzpoN80GIH6SGMQUzDPPeMX9ZJrAKkrtblVDsYwL
7H+pBvNaN3zG6hxR7xtLgeNEqevfyMvyAn0L690yxInwWXGntNywLOJ4eAOKEMnmYo/AVSiUEE1R
ltB/0W9UoDt3iceBGG8vZLPias7AvtJDSCV2/XwBm0IWdnKRiEbO/OmNXJqi6xdGOra1TlEiFzn8
zYPCwOLgtlkgcZ93ZL4QshFFNzfUANdacsQ0j1u+Hylay+IBESeZBhqonqX5BRZUPhlzdFk3GJcx
/oOd2+dTGQY89awf8KdOL5b5KgWHRIJXAzyK7QhjhhcyZACBWRtLP1MVB5vGkc5XO/bqhml9lS9z
gmYBdoKMl91iFYEzHWPRoZKFz736C3zpV28OX3Sn5OSlSwtX+mV7Y35enx/ADobXrQmSGmuj9Ze6
sHfT7JL/y5mbpvmXOzLKtJ6PmJGOAf/q9O0ySy/N5xF9j2E+hROrsE9lo0hgqa+cAbnIcngSgBbH
WpM4iKEkhp/+D1BLAwQUAAAACAASeEJdGi+hlIwJAACBHgAAFAAcAGFwcC9wYWdlcy9wYWluZWwu
cGhwVVQJAAMUx79qUce/anV4CwABBAAAAAAEAAAAAMVZS28juRG++1fUCg66NauHPbPIJrYsQ2s7
2QFmxo4fCTaGIVBNyuq4HxqS7bFnd4D8iJxyG+wh2FwXQYAco3+SX5Iqst9qyZogmxi21CSLVcV6
fFVsDw7ns/kWF1M/Etx1Rmdn4/PT00unDd99B+LB1/tb23wCcAB84rZxEMXvcICfNNraVhpHSNEd
zqWYMylc5+Lk1cnRJRydXr25dJ+1YXQBXgeHo1cnF0cn7sXVa9efj0XEoQv4oDSTGj6H3XYHdgx1
BL86P30NItLSFwp+9/XJ+Qk40AP1NhgzT/v3wm2TLkp3h+JBeIkW7rWzh0o5cDAE0vGG1i0tKUiU
U6G92cZaN6jgScG04GOmYXgAh86SChyXXeebbtjlsLOzZ36dtlWFc8EvY84eUbLrR7pd6HQUB0kY
/e8164DSUsfaD3Gt+/yXgNopp11S+MXOT6GtFGF8b7V9eQFvrl69gtGbY4y2uS+FyqZPLxuXhkB+
rs8ODmAv8MPlg1ejogOOIaNx2SRf7/l7qmqPz7+smMPI8qPb9faYy1gfxUmkczKyzdtEyMcVlqEd
wkPfOe1lfv1ncLH4wViO+4uP0mcKnvXxhMLMHcA0iTDE48gIQ0egwm1IlAAXBbf3gEmJAfftFuDP
9lTGIeVxce5aBFCKuYYJZuZuG0dOZoN9y2K1v1UyQVZuEYgd2MVfm9C8U0WDDUIYfn1+enUGX30D
3Cmklxxrj0Mq5vF8kxFOKMmub+xoGiNnb4YnQ+3RgNuynVokpb3eltcOd25ucqfh2HPS7R8syzjR
VZ7IzzfGSM21DzhGzXfoodutyOBrzN7qfrvtfzB2bmV2ziReb3NSyuiIT4eHyL2klBQ6kZGh3N/6
QJG/+4UBOxMe7u4XJhtMDmdzL3Zo7p0Qd0ZvPJFzHIeokHMhbunrUkj6+k3C7Jdv1x7M1+LjhMyy
HbCJCGi3ia9xyObuNKLQaZtEy9hfG2vag7+rHBop2zeddPudeFQu6d5OY/41Et3HCkLmK5hKgfkT
aQwUlyKGcfQhQwKGoW6SYSkmW2lMot9VHG0Qe61abcFhyyCM5QCDIThOEZHp7On58ck5jT04xsrW
yeZfvXz98hJ+3tqkQtktqlKiRkHgFmuv2QOtZoSHaJUH1xrOs0iRraGHPExV2MNg3KLtnohy21Qx
6Jm1wsxXOpaPxUl8bo6SHuEXOSalKm1tv48jMdLUDiihNeKh6wRM6fGtiIRM89eAMBGeSLmGUEgZ
S0PrSbQaEFN6ooZAJ8qYgEfqK8ZN9xGp8UywQM/GCJmTQISG4nC4NaAOBvwpxZ8hR9yjae7fg4cy
1UGLBQJbDPPZNWJbQ5NAg0MUSXCdb4WDgwPYRSs7VyFqLu99jql+/AYxjAGeiYEWIaQaMOWgsWsM
CJGyjRhgla2Lv1b2Hg73cjVmrh/Og5hjquyD06ln1oPNrIdrZxYr7dwYMf/6459MWyQxlkOXFrnQ
zA8cTC2n52A/lWmFUXE47FlhDGZSTA9aVmoiA9cx7Z/vxYKgHilbw98KCcQsmAk16DM0Zx/tmRkb
ezd/ug8V439m3HjtxHeIw2s98I7JqOSAdB9FB56L7O84OQqiI0YKsEMUU0r7RMfh4qP2PRr4ERo2
WnwfowukxKgKe8XGvdUbiy0hnlFxYYw4c6ehHnP0ZFmftnFoj3xlWB/ZbSp+70cz5PU2YRGPAcGq
5nPlR8THf89CsO7vwYVoICwdQyhNX6y0WXaAchQWP2DLLUMW9J72RLkLQWvubOKNUaHFbPERELdR
SxaguqZBuUWFVQ9G3Pew2zDHeHmGTYk5TlI5E1qnKcQKNlmIneUzFGCAyM3QnAIi7GkYzGOlmElB
mAQxzjMSNsdkFNEti+LeCjNUznkrEdDoo4ulJI85JWzPlBJ5TPJ0ySwjynCUWlrt0lSJxJAZ6VD7
GcyeD0/yImWtRc+DPi4sU88zKSHWB5RwhsfjPuvA4h8B1kk8MBZ0nMD985r4/pJ8tHrKbaIjwL+u
iqfaPoStZY9kxbSc8tmcSflCljVJaaZkY2OgScwfwZsxiifJ5nVbEczS4jjAW2ZavDC6EpHWfQQq
21IgbjWZz/gd7YA5oJZs47Sz5KwZZtBPPY1RscrxYNSfYuuZSNFqPmG6ag5ZPxm6lRKhCNFlTzex
ipJwIrAKWXcQ8OCMm95Xr53IAM/hsMnL81WbvHSTMbftY0tLRWFLfWx7KCpgTq2tIrCDf/4d6nLy
G6wVM4v/ICpxWdO28LrC3L6rux070dxxJU+lTP7/abyiCd0wk0+qJn0qfzdMsaW8Kopv2gNarF+t
ngjn+nEJ7msB0GtE8DpeFMUAawQ29b6MsSgQcvSWj2tROlCiWb8kyLGLSdVapiiYFNe5rCW2d7pG
xvnWwF+9aAgwRqOSDl2DRy3Qvg5EZga6F1qhmGrGBs3zGM7I7RMFonG9O+RYn5/6Aeqh9CPp8c7n
erZnUouuAc/xzoF1nrvpjRX6ULo1PMPrt02yn7Uynf4j1UzOLoGVLCDnKa6D/ir75+U7det+Y3j0
k6AxnvKqX1B+Evr/N/HiXKgkjDeFB7zjYNuIxYAFdD0IsMljPxFI8Dy36GLVlFzmUAOul1EL5wac
P1VxkI431aoK71GpnFfK+IudtMVZIcy+h/wEQfa9IJNGzFwufnwwcr5cKyZ7v7e5nJdNPXLBfqMe
uKZE3rinWrCnNWnOKlTi93TjtPzzGzhdyp3shHrVXr4mkYtLRnbB/8xc2Az81oCD3wown+kdA6nj
J5EiLxS5kJFOL4XrZUQiweANbBN9i7dBubmsJcZpmhbuoXuhVaYMeKtgqCKl32TQps6uz4OnkCzv
jlaD2QZAthw4BGAjTGqf416wb45EQytbx7HFnymJCTAWf1n8TVBmozu8u3g69T0BgsYKsU2EbG2r
+IlXF/veyvfi8t2FJhc/0mx+e6kiZhktNZsEon5XqfZTZIPlrqLWSuG1Fc1wgZdeVjLfLcE5Z9U+
aEUPNDCqVPSqI7imUwwHWuLfbHjMqFTgAw1GaPfv42IY3BeD4/z9TTpxpf3Af4+FR9qpPnHsW+41
iVRImkpuufsyrxfXNF+kcHNKaJ6dN4qtD6qZRq1F/u+AvMjoFcCE7FbDgmWcvugca0xhw56Z9ElZ
Z+IzKtP7LZPlLdQaRfL8iKO43B5qJm+FztrDDRh4Igi6ZduYf1KY13tqAzalTYkSMmKhWLfLhEJz
h7WqMcMt1SDBCQrepYCvoGP21qaAtH8DUEsDBBQAAAAIABJ4Ql1CpuALCwgAAGIWAAAUABwAYXBw
L3BhZ2VzL3Rlc3Rhci5waHBVVAkAAxTHv2pRx79qdXgLAAEEAAAAAAQAAAAArVhtbxs3Ev6uXzFZ
GN1VTy8XX4umsbQ+NVZ6BhzbUIS2B0EQqF1K4mW13HC5rt0mP6boh6Lox+I+3bf6j90Mua+SnJfe
JbAsDofDZ4bPDIcenCabpBXylYh56Lmj6+vF5Opq6rbhzRvgt0KftI7CJQAMIVx6bRyJ5DzGkVZi
63kp/orXbe9o8fV4OnNF4s7h9BRct02qP8iYo2rKtUYtz6WxSxOKp1mkcSrOogjHXCmpaA/XPWm1
xAo8u82jIYna8GMLEQDJVyLSXC1umLIqHXh+fjEdTxbfjC7Oz0bT8eL8upQ9vxh9jeNvPmvDEC2t
WJTywhj9y/cdgvPHbz8ac2//+A/E9z9LuP8Vsi3wOOSK3/8i4fz65jO4uf8pEqHsOSfGxFvgaLBu
L5LxGs2J5Ji+WYTtk2o+JZ8xnl0/UTxhinvuy/HF+NkUPoXnk6sXuCEGlKfw7T/GkzHaWaSaKQ2D
IZzC6PKMJIgJfBpfTc7GE/jqnxAozjQPF0zD2fjlM7e5Y9fntzzINPdmBl/HwpzXtYpth3bBiutg
M4oiOu+PAJ8oqXmASD4E/p9ASfbfDZEFWtzwcekNU4rdIVmijKeeHVgCeYXLHVjFyDakxdA30b8j
zDpLrYz4x9AmM4Qu9xHplNtw2GwgtcfHX/T+iv+P3RoiQ2WD+5NP4FG+rk5BY+6Gq1AEZG/myldu
B9xrCuUauUaDcao5EhCTJQ4YMTPJlpEIWCghZoBJxXruvEJnaWl2bsYDM/pDEIQsXnNFG38VydcZ
ZwZF4TMmN9ljIYOQg+aEbfL8GXz+xZPjDqb6FskBkcAghggLnoJ7laJY3aAzmPa0KJBKcSFB8X9x
odkW1dfs/pf7f5tp6+wBj96FOeYZYooI9CWlrwXQjB7J0fr9TxQ1o9DcpMaj1zHbcpPIC8VxnxRr
o01m6IGLbvXAFLcaJRhQ/fp7GKeLNde4DL3ERcZSB84uXy5GdQbpW/0e9el30/qCsmTOGlFwcx67
xN+S1E0V4p9L30iFBjvzeSCtiXywo2JwubkJC7KpQI6wXEHgV8o15F8b+WLzLpBRto1RhEeC10Qb
mTGbHzCCgXGbRlBSmdmyxDMZq03GHumZSyvyW6cDVvuAbX6bmNrk4iqv8HL2eG6Tt2J6u1qXk+Nt
623r1G8NUlwvZAxBxNJ06ARMhY5vNAYbXMpVfaZLonzaqITixm8gGmyOfcoopuimOb8e9FHQ1EgK
i1ssjGjthcT7loGhcZ79hsfAgWE2pYmkAVYvFkFoKwMMToew8QxbMYr+oJ/UQPVLVLi78SEfraTa
NtxZyvDOZHuXphzYcr2R4dBB8jrATGCGjsDr8raHDUXdcREnmQZ9l/ChsxFhyGMHiEBDJ3HAlOah
o00c6qsituRRgSDlTAUbsL+60drZiRO6KAIZe67VcMnRpkYdhOa3uoAgKgx5oGyWn/pOGXsZSweS
iAV8IyMM0dAZ3/aewpfHvcePn/T+9mXv8ycYAiVY14DG6VrX4OC5vM6E4mE97EaxJlhmWlfMWuoY
8KebYIvF1J2T406z5VZoJyfNoG8X1aywXQPrDRLCgY3iq8K/TEWea8ON2WI6Nsqj2u01bxv3C27y
nWI/6LOCMcSE/Dt1kfaysy1V3rg9rR8EpcAepxy/LmYRx3bBfHaNIZy2x2JGlsDE2Tpzzd7YVojV
CW036OeJ6rdaNVy2fiKi2RFGjVN/QYeAv/HKCeZ0l1uVWVkP59ZeDd9aiRDoo7tlIi6y/+HC8IHF
4XCByItEg4f+Dkv3i8bBwpGvIk/3isBOIShFacIqRrJwzcF8dnNbOi8ouZSSMp8xcbXbkI067+s1
ZpcSmi0j3v1esWQvvYtDfFQeUXHrzW1fVYjNTTdv0m4/KNij6DtI6AguebzJtqxkucxAxNgfYk2Q
tp+lJgxlQZQJKHqT/fhZDmKTsrf1wPjVcNI5AE5TaPyBVviz8c8LDIM+jkgyFUk1eCGxrZMElk5U
Ceydfq5mx+ZysMM+Gexb4wc2pQw8IDfeYHZzhlXX24kusBS7iMMxtlbJh/AgbZOZG4hQ4REZemjy
OPTLZreQlLnCoyhnRGXAupxQxu3YeZCy8pVT38Sw0q6i+DzgP1aUPAQnB+n0QJAqZlKc+MfGie1X
65ybtlyHeaNnvs6LWl0UyWZ4WRWavGV/f4DRBHqU7scWp+3DaGFi6u2+lSrt/yGm/QOMRCElzcGE
K4t+pVzraKp7wIz/bJk2lZm6tUnRYWF7bgrvXp19JmNiAYMVPWyArSW2awnHWlK8gACryZIFr+Rq
JQJOhaS40N5VG2vX5c6lUfVIeBLpocpirIfav5RbenpZgJQGKBuEDf5BumVRVHKhoLRt/nM+hKF/
4LZo7DTBPEu1hNGhPaz10rZ9N2D7jhuKbRLJkHv0auvsqbSprXcbOZ5HHR+dZfebZ7f7sVjxtbWL
tkyOelgaqPKXRx06vNnDbrT+b+hRFB3KhSPc6gJd4SG2Mt5Syqi9G8G9nKu1R7XVw5qX5avpvZdq
jOUV6MNU21H1HMFkQdrhDSrM03+7/3z5qPv0oV2/Zyre2xebNLzUzcv/PRDgGo+PshQCrE4cvOn0
gnpemwrlXzC1jlxT6iBtd/DRlaJRJWPxAzN3MGZ3448dhAFvaeqeI74udPjuo6yO03bd5m9OD8Zl
r+w1g2KIVZD2mmEJsg0/xPjQjO9/fwqDAL31Q7GGv6QbSX+he0fGG92H341llc2luxj/C1BLAwQU
AAAACAASeEJde2IjLnwSAABwPwAAFgAcAGFwcC9wYWdlcy9lbnRyYWRhcy5waHBVVAkAAxTHv2pR
x79qdXgLAAEEAAAAAAQAAAAAzTvbcuPGle/6ih6Ea4AzvEiyp8qRSCryDCdRrTxSJM2kUrKKBQFN
sj0gADUAXTzRv6xrH1JbW/uUylPeoh/LOafRjQtBSrKdZFX2FNDoPn3ut24O9uJ5vOHzqQi579j7
x8eTk6OjM7vN/vQnxm9FurvR8i8ZY0PmXzpteEsYvSU8TUU4SyZuEND4QoQ47ogwbbeScxveJ7EE
wLf2BS7jwRQ+T7PQS0UUMseV0r1jLX6bShc+nF+0d1iSSoDJPm/gHq1PnMfwhSZOpiJIuXTO6RP+
2Ve2ehiOWGvy2/HZOYxcsL09ZtudYhZPUteP7NKsfGR5ajyzawBhpDLtosOmgHrruk2TrtmL4RA+
Avn4VfI0kyHLZODYPASyfDexO5rEV4ogmHu/u7HRmkZyoXZj53YgwjnMRaCwFbMXUSquo+Kd38ZC
uuo9BA66xeDEd9P8C/GZSxnJRMHF9xtXhiin/H1DTAH/yen45OP45Nw+Gf/+w/j0bPLt+Ox3R2+B
2CESdHx0ihqQi8H13AgFq4TThtX4/dzGcc0eoIomE3S1AAG5vvBA2K400Agi0Q74mBFiv2aClsHS
hvkEvWWnulzzTC+HxQtnCUY+S8OoA9GMXolDPkGtV6JohlHIZQUMNWGZmIvdglFeFE4F8eoFX8Tp
nQGRfwDGXmjW04I0+sRDLWs9CuzmrjdnDpjjbJLEgUgdu//dSR+VE2VRsLbN3IS14I2XBUagcRAA
E1sJkORx4HocQP2q97KFwFBX1eL2bmUxqYUCoAymBhz/gCRwKBmvrryvIqHoOwc9ZRVizr9LOrsX
r/oGgfPNEgPuGxikvMq1G2Q8Ub5okoXiKuNOPqddYSzIbCwlWlWYBcFu5YOQHCHGrkz4hN5BUIqv
Wl0Moyuy72i45a2QVy80DnUhKOsm+u2D0Ed8WcyDiC14GCUsW7CDYxZl4Ip83rNLHGA8SDiC9qIs
TA2NbMReb26u3eY9AH/48VYsIpzKlKYwnzMP/Bu75j9U9qmQkdNsbK5Z+I1Ewaa0qsfeCc9lYcTm
Ikkf/iKFFzHO3O8z2NwFOpM4Cn0u4TnmvvAjQk3yRfTw54f/jpp5sLicgE0GPKxjiPzYfoQfRzlm
LI5gJ4hJiJzmECwGvkjXg3GerOGMURtgydQFvNbtmWtJGVihgK7vc5+xms23Yg6chFhaG566IsDp
1WGlc2rHOiK/gUg/ScWCTwKxAGPb2t6sWXcrTuWbOfc+oRVsLn87TV2Z4pYL4ckIQTmpzHgDlG8y
f8ZTmLm12dvcZf0+pBmzLASpdpDLaZS6QQcNDaWdXGUiUap4fHZSheULmd7RY87e2l4J52GNBzQu
yDdAxtMdgX+BjcC9HbyHaHnGDt6fHTEM6wLE5njClx0mYlAkII6egOEd0Dw3icIO8+Ah5f7ETYvn
y7sOy+UO4232cf8Qgi9z9jqs/l/brnHH+HDtwdBPw2OTJ0VBLjkq8xE/AbbkrQhahxa0l6cqrZCw
RU0bQRW1JqkRgLJbOPCa09agRAKa5BDrz1sSYhiw0L64aCP8dWuXVlAUwkDRuA1O1HknGzDMS5uY
pBmlqbL+/r+fiz3u//439vA/oFoLNxGQLbKZdMHN7IBfIisAD5RmboBz+p9xi3vmvMUkWoDb+StP
2j1rmZ+0ZZ1tjbOaYyH+NbO2dTO/U2IF3eLyGpRt4abeHJjR/mnEQ5L88COo0IJBPg8QXYgxCjZy
w/mMO97/q6nEagB47ENdEaXcQ5tCGK7ADNcBqwVV/nkE+2jgEQMSC7JpsxmEFva5FZslFushRue2
zxNPihiLGlA4VRCwPWYhk+qf79sW26EQ2GOQqsSRZGAVEaNEEnydFC67DCIIgMDlcvT45zIX3Z7w
+TJ31bjhbLOLaHl6oRddc0x1JxD/xDX/mRL5HuShpGJYgrmOy/LaCsThmfmrNPG5OvZC59yrcCaK
FV9WTSHSQndBWaFYxAEkCg6mx50861y4sUN1ZKzqSKNVP0unOlqO9ey7gpeuB1cwXYRekIlC+5NC
/ROGidkU0rEFxlyISC4aihKOiHZAHkT0SlnQ/nleorTXbL16wWoB4t+yEI2MqmFg+6u10nqEK+Dm
s4VLWTUgtGBo/NNFOgH/6IDTzXNqVHSwa9BPSEj5w5+jZJUJ//s4gfnml9vreKE8rcnoRkO2/Rqb
QbXkjXVLud2olL2tg/0EXu+wEPJ2No+ya8yuF3Gk8j30LKh7mOmTHkYy5B73wYXGXKY89Pg6vaOd
n8tx/FvPdfxr5rzaULPx1at1ipDqnCyVToHXGitWMpLRNZadqUSPfQ2GL0lwK92t2fARbdf8ZOhi
EfQ9+Z1UQsBn35C5P/zYhcjoTnnqQlaOvgH+g6qLw8KUY04OyV5JRv+vRLM8uioWUBmxip0/RCEH
Vy4/TWias0JeeS2ic9bHt0Yv3h3xW+5lKXdKiW+HOEMFh34BrpWaC7qMxWLpxoGAkEFKgT4Zn3XJ
2aRXQTSbYH0dyTvTupzo5p2P3cYKFrWyvleqZ/fA/zmqycH4Al6Uo/RTM4V8ZNtWMasBF1XQrlWE
gmf31b6JWlsXGAnqRkLWPpkGbjKvS0oN2knmeaC2QGzuz3Ng6DK3ltCEaPw5R3Xz4h5UXZQyN2tp
+k4NqIoTqkdsFroQMEq4VVsGuj5nX3zBXmh7qZMKEQp47FGZFUyddiM0KKtPwbiDGcY06ucQ+oBM
Cjh0oMZBAWfBw49SRBTwWfLwFwp8kfK9bpBS7yUKwC33GkSAAUP3GvBxBbq17mMpXbK+Cy2TLnE5
g2RSgesUwJaIu29sQmMzCNC0CZHysAv6W29NC1+fYZheq/BVl7bc9mgl6VKf4HR8OH5zxl6ydydH
35pOwR9+Nz4ZMwK7Z1chlI1c+GW7bGEuTjPAw3oVhc1Voc7JXIdJRTDVHOc5MgVTcOaReu/V+wpP
UpgVDK3joBpb5/l37H3kCQd2Ipq86BM8aJXFH47f7p+NDW9Px2es2Aw53DHvl3fqPYv9vBGD7zVx
NDnsklQavGg+VJOX/mv0o4SRUF6Ul7wocQq7RY2h/jGnVRJ64bjAJZkdlE/KN4eSFk0dYkfPaq90
ptQgrZuopBMqFXXoOIMO+GAb3fxCYigQ1b9ScKq57p9Zx9fU3HqP6g3ZeRwlycP/XfOAabNmZVbs
PLu8X2aT6R4/Wu+SejwJ/Yq4nlnvNuL3rzCy9x8OD2t2poaK3mZtyJ+AYcw4Gt3mL2KRzzM/Uoi1
9kfh2EkgYVGpC50dLPVgDTcfMcuf3k55xKCvoyCNMkadokJJOgwRxxMlLMtLBDSkIfjXMw0MytaO
kjXVft4OqBT9O5TVNfU1vCjIFqGGDh8IcVUV95ozvvuGcLMiJt1vQHzvv2SH6MZmQPLL/kbrSi0Z
Lh33Vi8EIIyWOvivHmUv3wggbUlsuuqQuik1cc71KJ2zf2PSteIY3tcfx+a1k0dKYb6dmFf4BmWT
Hj+jR/CUFNx1n5w2P8+xvjD+pCBDI7ULjGnFMzphcW+drY5JYCqXGLaICVDcwbzXm3gH4WbOJTc3
BbDMXihqd8DOCDWyN/iY3IiUTh/U5hoXzwWXo9HYIewIJmXvyVWgHWN7l12CreWtSrWq4NtOeZXt
lJzNwSn5Ebb//m3Zu+Dw0Vnjp8GQIfJtu2HHQhrVHWsb5pALCPfq0sSVvu2RE4+D6lbKBOINfO+w
dweHZ+OTycf9wwP0oZODYzP27nD/t/D+8as2gVk686uwQIdWIkfERKQKqNiPgZF2qbGUCw6kJmKV
Q8fbQYSB9EpbTj02VDZDI2WHB/85ZjuB+MTZ0Ul+ilUabN4Pv9CO9n+gSwAO9fCxMNcW6MAfSMmG
+Z7ocpTHrzgRohAdNE1qk6tQ5gCmCsHdMZDAckg728tHp1lIhmPQw2kYJsBtNOTrVp6vvzn68P7M
edmupu2fzYb3lnIFRRTKd8BhOpEsbj3phP2NcoR4rL9m55crtwQZvB2fsG/+WDpHZG/Hp286GCjx
AWTz7cEZpixcwvR37zBM05mEg66gC9YO8PFrew36MrpJKpXGvrrMtTfaGCRcXdTyICYlQ8tzpW+N
iM+DOTg/cCOlL10cyj/TFF9cjyqOfjDfHuWOU7KD42TQh4HqjFhDXACaAO1D+TYDHZZQoajOTYAa
VB726+3e1tbXvS9/3Xv9Nc4t3jf7218N+nEJqb7BCnYnGvI3upBUJucy8u+oCu5COWuxBU/nkT+0
QBNTi7nEmKE12BuyuQlSbG9UZgB88xI5nUwFD3wHvxbfRBhnKUvvYj605gLq5dBiWGAMLSyyLEa3
UuBF354CuCXA8TzOSy11Xr9Thq2Zr6lxAw5uhP7t0nxrNACTAvcwotwZa4Qiec5zCrkz6OeTljKI
QRaMFA7FkXTemMAjaU7oDAIxyrnDkfRBnwZwFfiwfOEufQBwVeT7FdUxi8R0t8LDgg26m/l0RuCK
gg9v1IEPZ27euvypbDBX7ZARN3VG3DyTEbRL4F6CWLRmYisZ8C6rD41dRrdagczFMKNFW9aI5SSq
7g38LyNDI5YcQHVxZgGAQN+ThQu44u7PEk/FAWi8tR11Z1KUncQyhWQsjP6FydGN1cCSJHbDETgQ
7RjAk9DQ8syU30IQ5W7OGtVlshg6vaH12mIJVFcBMRB2xkBiGQcUhWCGdL1tHgXAmaFV9jNf/Gpr
c3fr69e97e3N3tbmFrkaAMyvMqx2tMTrV+tQyhqnOlebWN3EQkysm7iyzMaGWQX/vqXe7SrO0byy
liHWWsNU29fCVDPg4SydD63tzU2jbhXai3tV4Byr/Bzf9nYYnhao7FHd2grcO2ozmpMECvB07uNH
JQYv09/EwCUmkl41q9XzmFgwclyUW+u4qRbwAGJqzkaV/lpUt3XVpcHVS2l51duoJZOIToETR13c
/KSuJS97wkaAam1NcJ9IVvhSu8JI+RbsgDWjooT7qqaDBVrlr5WWK8hPoafqBVfzrq+2XCG4VdKn
jw1SLXO9i92IVfTa6hYvlpBIKlPRmih+RDHewsJHNaJsY4iGVVEOuiXabFiVa6TKuhbCpCQIyrH/
2F10fcipIYSl6uDWfrUFlN9BNVzLVp7EzJrrN8OXWZoWeeJlGjL4vxtDPe7KOyunLskuFyK1SE8E
BCnHvnRDG9HQSeGgrwCtjzflFA5ZAYlqP89UIfr8hKSVmaeuKuaSchZXTgz1Z5MNzngpGRQQQG97
oNL1ALc62YuNbPVJ0NPXqjq8rhy6Ol8SbtUIEmC3N28KI0Y6aordbjLKClo5rBytqzpGVw2u/1hG
XiapDOio3B5CuQ4rrhRul7AtJtaJqWuoVgXzHrrG6afuZVKFOlasq8Gs5XJ566dwqrS42bEO3NJm
5El0i6bwmCLpql6IcZkWm0s+1Yyq/2ik+qOXyq9YPnXoty/4eHWhTTlnt8KSfHA9xVjnbgd94Fjp
Fd1WpRhTp5d6G331RZW/hAGpji6H8cAUqZY8yQKF+E7pLbEJwcI3FtWYei3FbOBowLs30o0rxZVO
/l9QCduQ+Ztakn43wWKsTgnFq+I6lf2eh3M8A9UNdi+S+kI5e/gvc8VYtS6pXJpjj14f24aYOjMl
mp6iKa4jiY2XCnYDoqhCXl0VU+RGUz4rR/BtVNTEkE7OaUinc/mr0nDzuq8P8kszKH7oV42NFLM5
CHlf3WFVX/uprFtfA36DFCvm9SZFzQZdI4KBYV8EeXmHva40S7BWbEwCBnUUig9+OWPHbiUpChjk
KtsC06ITXTIfrg53L6o2ZBru2o6A4gZx1BDwoJbI9bSAY873VO6/GgqtUWyYXLo+HncDgx5dpjc3
hBvzpAsXQIhpH9mKyrJtKcuGSi8IKsSb6+oacYy5z8YDQRWNWWxBV1Erf2tTx2/Z7ViqScFzbSWP
YT+VKaTNRidWJ2HGe2Pk60Lustozr9Eeloo0gLg39kWK1Xcl4tAYa9KvckbEYZrd6Lwr+BadD7Kh
oT4IsB9P+1U+89RuluFLiD+pypPmvMEwtE7ULYBGqsxp8x57y8UtHUxVzqzwbpC5N4a3yoUf4Q9m
1sipoH+ps/bUhlp+ccFat0D4lRSmOM+mWyCrkuYKgtWEWGsV0w9QcIQzwKKaGWv9ydlaVaB1vC5r
EChpMs9VqCmbXkK1ljgt87oxhjVO/QVV62MUpHTR0zSpmghfee6598/WInXD4N+jRivVJkeqpjf5
ZYjHFAd/Y/XL681S17YKo8mHN+Qbj/UJYEk1+YABTKvWN5HLleQe/nhzJkIX1TXPavGe2Ywum0m6
3rIqM9eZeKf6U/Pi1HavUqL+A1BLAwQUAAAACAASeEJdt6Raa60SAABhRgAAGAAcAGFwcC9wYWdl
cy9kZWZpbmljb2VzLnBocFVUCQADFMe/alHHv2p1eAsAAQQAAAAABAAAAADNO8lyG8mVd35FCoNw
AWEsFNmieygANEdiuxXRLXJESjExFI1IoBJAmlWV1bVQoGReHeHrHOemmIPD4+iTwzEH34Q/mS+Z
9zKzqrI2AKTUPWaryVoyX74t35o1OPIX/o7NZtxjdss6Pjsbvzo9vbDa5Pe/J2zJo6c7TXtC8GdI
7EmrDfch0fchiyLuzcMxdRz5hgWBCEJ4c3kFdzMRuHJcM3y6s9Pk4bcijOB25pFWGAUwkzRv2odk
IoRDhiPSwou2H7D52KXRdNGy+r9tHQ17Hx539p7s3zXbrUvafb/b/eer1tGhvuxefdjtHDy+S960
j9722r/Eu6sPe50DmNXnVgfXART4jLSa4/OTV29OXl1ar07+9fXJ+cX4+5OLb0+fW1dkOBwS6+z0
HKn/sIMkNumUCsBYo9uG2fj+0sLnMOPoiFgWQsbBErqagIDmLKBBCklCCwDUe+Gx8buARww5lryS
c4NLS1xbV+YU/HHEfLzgYSSC25YF0+kYQdsUyNICkI+Z1QY6AQbzAFkWAno9YhG8g8FhB6578r0f
iIhNI2YnI5ZTJw5Xf2MhabnUi6nTtgzU8Gfm0BDEEcbTKQtDWNj6d8CDKDzIVLgp8OrFCdti9Z65
6h1hTsgKnNBoSC1DJI6Rm5R4q/8SZCa4xucwQ0YOvDLBplcBs3kAiLTiwGlZcgPwqQDM23r4XaVU
b1jAZ3xakixDrbe9cLxg1IkW4yD2TPk2J9SGATQI6O14xp2IBS2cdGmFLACYwLCO3BfNZRu3AkIK
IxrF4ZiHY+DZxGEuvITx8ikQVdCeRwVwRS0q8u4lMm2x+khwBrcFUmAz4glXXiA7bFElE8kQIGfD
AlMRe5EeiHK2lQrox0VccYSByPOX51KrNOE07JE37HeUCEQtos4CxtAJ5UuxtdIYunshgDKEVVgR
/vrCs0GJ3DzYz1WaSFwzL6cweuOO4S+wbOmLIBqrUR0y4d7egi1bAfVs4Y4ntxELW3tftU2J52yC
nDgOmCduqC2QQgWRrv4EQsb7UyLHEOqB4nERABeBdzEKZRZ7Uw67KDApruIZzk/W6JHjCOwEf8+I
gE0OLGOrPwlQniJPc3x8IPfmMQ3s4oaTvgX8TE7UygyS/A/sJrDekXDEO9h0YJ3cVsmcy3mJOW+3
O3moSi9CNua+ZUCtBmUOTiEWAEaRU8SyHiAOrgOE9gZ8amjlAW2kN51XS3Mo6Bg2HjcR3QZyNq8W
NAiexg7o+zLazE5zcC07l9F4KryITrcAaA6uA+jHE4eHYMQZDYVnJQAfMdePblNIhVFgxQDYY4uA
/9m1ChBd7oEVB41fZvysRdEYXIehjCLAj7C8eOq1Ww2uA6ctEIRxIFobVBc0qhZcxeAKuFfklyru
Sx4oJ6WCwJbcv8m+axddiY4jLyEkS518xFw0V2BeSOxKN4W3YCBXP3pcdAjgBLEESMgR6D0nTm8/
QB3v+VHPqrLlEp98sPl471dve7vyX+utDWHn/l272cfwUaGb29vw1JVRcot7UbvpXj6+IgOyV3gy
IntPvtpAnwQLfr1AY2ZXMYxiBLDr7cJ/e8S4fvLVGuqm0a3Pxjaf85Tj0poYaBtPAfuD3eo3I/L1
wVe7u2vpOCUXF98lJDAgJ9B4A1Cm5gNl89iTYUUVzk0vTGOkG+rE4PZyAZO6cakPLg80E+QixRf6
DtBn9d++MkSVWbh2uxwqeeFaUl54Nv8hZsRnoEwuQ7cG8kg8WxomVVMB6zM6XYALA3Ig9G16xbXy
O8ErqX8Rn8anv3xoenef/q4i3dWfzR2QYnWz+ujARa+RD93vqhhd5BEswnHn2KzVeOs1OiiKAtPA
CoCSJmpkmHkIDn4NvvkRuOoZhfCrxNnSDMwcowDspu/QKWvBdIDRy2RnDK2MwqosiTlng5pq6y/I
+elxccshhLwtQQ5BAAr69+stDIrGJu+1ZBRj4c5yJxDVBw7zKge20Vps3GURWwLugHPAfse4DPFQ
JcQk4HMarf4K8R3sNx9kCUMD0BPirj4uuSsQNoHMBWgHu1KjvQYReU/5SBHxi19AklikIjcSqVB2
JGdcL3/7drm32327/NXJlbFP81O3Fl0VeQcmdZgbuwTUy4tg97bYsncIGUMcskyKBALgRRT54WG/
nz7sB8wVEHq272dWTZddsq45fz4gX699PyL7e5s0gEKavsgIl7og+VGyvf2vQRf6+3sbhW3GCJm+
ll9e7mpV6FubZEWBLsDShtycTxeMB3BNS86cTkLhxJGocQk6yvhifqEqeMl7iMx+J2ujEadV1AJW
Xuw4T8vWnftjnwYhAyAdOXSjkbdenIG7AEYE/D1kWKGuYsCIre15ZWBWsuz6dbsUmilkSnRes1tZ
0VPBWiefDnVUMtMxUpGOmTx08uF+Jx+sd0qhdicXKnfMQLdTGaZe5bnTnC6oN5f6cll4lclVUoRC
va4SCjIji3nDy+Z1Et1KxU9eKZ7DyyoYJipSus3rp6VBdzVyTZBIAFQtINni0uAazFAAOUm7DD6j
N+FJLcn4Y1YkmtedCjq/LAW5CkZWCwDhRrKKF2rdgefg4/7G8D7RZHzVSRncrsAsq7KOVS2jikGl
IsdzYzmiyg6ASK9YDU3IA0WVpqeVbI0Eow5kTjGr3PLGwu9ogArfONWxnLaNbmyryswHUD6dId0R
sCYUnphp012PnOFTdINsxngEWZDkHkMPMVn92QWXRxwwwpScLNn0HNxChOZYhoyYVwQTB1IlG8Ie
sNawfhpLPn953sECGZhRFFFIXp4jfjZz2FxVlQhWfpLsCwGcYV1XvaJexLuhT13yv3/4D4T1L9+l
S3irv5IX52fgwOicBb3GRq0qM9uwNA9iuHUaVhY9gfEUS3/kmfBmPACRYA4wFdybchvxF+56nlQq
SmGPVFUoq5VRFWjpDadKqlTrpdQEXRMrrZhfbWPBLZtyt3O3s9NExTqO8H6Y9RYAs2g8Zx6gEIHV
pREuKoeegAtcN1TVgpPR34AVz43ObLvsHUnj/jpwYMiEgntBpGVluK/LmUHPX/gQJjSngfAU8kOC
17pULltQqv6u3hn1+DmYNXh9NNoZYMdLmSft8Q4JPMYZA5vfkCkQEQ4b1GGwW+TvrhzXGA3AJApv
PjpOCuRaIrr/ALqTGY3DQV+PThk9iJ2RWjwzzbphhpZ5KfEYOBwGDclCdgLgvi8f4Czm2XriU/kC
wCms+4B2QhcM4jN8v7NjUjMPuE3wVxfcstfQE2URVY+A0NluQLIbLYQ9bGA9ogHhc8SFN2wohMpK
BMs0DPpg1DQMZiBS5titdsJV+Y57fhwRDJyHjQW3beY1iEdduMNCb4PIuA7wVHptQgUB2mDhDDS7
+MgYkohuVNpVg8XeSHaqwAgN+nBTHuEnkN0YVLYxOpW7XhRNxFQEAQNLB6FLCNEMdQd9v4BBv4TC
YBJHEaiqXmESeQT+7/oQpNLgVl6HbkNzJYwnLo8ao98oFgz6arLBib5ihfHEkLBkzETYt6hdbhd2
xPS6gkfJcCmjbiDeNSp44tAJc3IjiRo/r54gJ4HB90YvDU8GOwAfVY829QEz2kQb0CY0UpEIL1MN
vStyhUNUQLByP8Rg5uzKhfSPTSPanSq73uWzrvYbw8b3aPSJyLvgEJwUpijKq4L4fcGlFihDHCT+
lZR9KbjgnJsEJ4GeEpIhX2hXiNpU4QrR7YBdBOkf1bLYhdB3tPojpnjKa0llBYdCbS67OA/3xAQ4
sfrYdWASsFPZNEVuRafMY9IVAoiwB2KWaJXVqC/1aCv9WqtUr3R99EEKZWQrW+hVrsKbV6+fkEAs
nLaS2mh7azK92J2wICEU8jCw3xzM9cEuXNDlsCGLrtWE6jrwAwissnM/vWE5r+pSb2FnUBUoOE3N
pCR2BKrFO8Bhr6ATKS9yzDKKydLzJkDXbtPXrqwjyvi7Ry5W/+0qPyLDSR5UhZO4mZXxcImi7cvs
rm2Z/MyojD5os6WJ/xZbzazYbtBDg6snOAOTGL1TVx9v2DYV2/vxUet4/tliP2Wq9LBMRkeN0ffM
C8GEuvmaLHjr/QLQrayCtgiyyMs8iP6BVorkQmjGvIjVyaVWJkb9RZoFh3nzaAGqX2caCjXpDSZC
sbWJJWiIYMKIR/HqR8BZ9k5enIH3+4CKfKcemG62R451eTZEZ4OFV9zioZQmbgUapq2xkJx/f3Em
HTOdglOGDXJ8/uzFi2q5Vsv0HuxPN4JMtnxIo2x59EQiqcV7TzEYda+cGNBYb9wrhQI7ikT2ThbC
gYBw2DipKG9XEid5dTwFtiLrpW6RSOAJLfjnKkX2wrwmdxQXQCIuxpZk4gi4xrly13lz6kEcBMwN
iB6FDMOblFuFnNo8M8KWYP7YfeSY5m+59nQ1p1QpO8vwcoDS0N8TMpyKWBdLBA0IOMA4A4pA4yHh
uhkYu2n7oUfOMTp0WGcDV2QUhayp50w5jyjkcfU6PF2wUoxf0kE5aCKWiR7mC66puj2WCqeZWDzZ
oNj42MIDDkQCZLY85wBPRuX1z3D6VIbVroj4jUhDXn0eELs2TjyHEcAu1c+iU8iJthB+Pl0jUmka
o2MwjZKdh9KtYgeECF9rb4oFShEUP2A3IG08lJicTsQDfeSGh6sfwZkY2g42TW4D3ChKUNt5hFds
HshDj0njo8IZPDxk2hArA69VYwgNVwApJbe3j5zzIWVWiteR5dc6sNzfq7ZT+TbY1k69//iADMnB
E/Jk/yAzDV8otdg2+Pmm2KRq6ZRu+4C8mMjK4taW2azur92Da890gy3poHXUkUmUeSg9qq3UHdRX
6bQgZ9+e/ZSR0Ilx7FAvWUwdPy8sKvTIZK4dgqWBIJoGZH06UEwFys2kuqQg52rf0Pccj4T/EFMH
jESAMY4M5dURy0Y+c6hsN27IIbL8AUCLWPV2jVQi550wIsozWWvtfTyqaYtQoKruF1aJYW1Fq6aU
lauWlutahppV3A76iJLWQBPTYoVroNUwV9AsrLJdLTFZqWb3LfZGJ6GMndIEtKqyKMcWq4tKOQrH
9pVC+FU7spxql4qARb6khcBKqhyDfVGVhFPiB3Y0Wv2nE6Ejmav2A4a98HRgq/w4aRccAUkzNxrb
UUs/ApIgOpB7tsAAL/amyRa1JN0IrExnCZWTxFn7KrqAyxwyCgXwX626boQ8eo6dlV08lHqftb9J
3bha0DQPSQiit33S6Ngafm3VEhe+AAsxo8rmgVOPgG5F9ZpZNU4jHZC1P7B1oj85ka2HCnFlnEXh
qgnIVnnKCims94z5BdMvB0wYZnieW31C7Tkj8rcOyV+i3qgqfHy/VbcAjm1U2coLwdJuR/K6KD2H
R79OIDWKAY+rfHMmtaTx9mhNaiOn1KY3hqoCoHrrs4FE1T76nI5RfrVS92jrphHW5OvAVjusUMyi
ordCDABPr2XBpgNPurAQid/Igr8MCOlcBLTafynJKU9VkGber2knZURUP6ffOi/GYvfxW7q1emnp
DBA7wem5QMgM3+hPo2x5HgBPL2XbqGqqchLHkF/rT7huUgDWPTyifPyPoorp52H3V8eadmC1Via8
Dh6mlJ8VQ6Sm6FEq1uxLri3MkfyKojHCEgrQg81UPBFOjlP5q/xB2nrl+Sg6PhernzrURqvcwdg4
Dhn59JcCNz79vVxVyTBPfEI1lnEWICmaagSZwcua+SVuyL5+GNzUcyUF5fD1A+QgM/qVa9RZgcrZ
OfeOiU3iCADDSwurhklustm9ZiwYmt8qSqeqAaYfKm6iXcKpj5LqOJArAG2NrMJNfpuVWq6EBarn
h58ifvofkta3tgZdoFsFNxBd4Zlp9Qq1gsuCGq6NR0flN0P4GDUeTaY6F1wY/WCUEsrwo8mk0fIl
ZCFPpWzYF/njKjUhUFwR68g31XW+N5pTFL8+TNKvQ8V9ZFz+aNEk5k40DtkPOugHNNDMJEc4sLyH
DX4I/HgADFIGhhaOwrVePz8jT/bba01KdbH2H8v354oz989cn8uCi64jYVXJj+QRbu6hMebvE8CV
xYifKbutqiSpwtFJ2m9ovX71XVLRqy8jmisK/7a7tvBaLgGuqfilx9ySSh/w1XNuCbeTklQXYhUI
XwJOuxK9YSPDHkt6hhw/O8pQAxvJ+Rj/dtj4JwMLI/rAl3ILPRM+rzqetEasG4Qjvy3+/xNJajRy
32G36+WjCn05CanPo39G6RjFxi8kn2qLm3w5DrYy6UZ7eJxpAupInYUgg6mw2ejfuvJwUVeLUj7T
fUN1OlJGZ5553iE5iIxG9h2b1NjXBwb2uQNfw4ZK4uRXcze6UHtETo0upHYojC9p7qN4eIHfVqn3
YOSCqm/cv3waoaV7H/WZYwC3MYe4ZrdGVptx40tltcZb/ef/AFBLAwQUAAAACAASeEJdiwLfASEH
AAAfEQAAEwAcAGFwcC9wYWdlcy9sb2dpbi5waHBVVAkAAxTHv2pRx79qdXgLAAEEAAAAAAQAAAAA
rVjNbttGEL7rKSaEEZKuZdlB0xa2KFWJlcSAa6mW3KAwDGFFLsVFSC6zu5SjtAH6EH2Boqceeuqh
9+ZN+iSdXZISKdv5ASpAMbW7M/PNzDezw3T7WZS1AhqylAaOPRiPZxej0dR24eefgb5h6rjV2d2F
8fvfFiwlEFBg6fs/fcb1o6RSvv+dgxNygXscYrLiuXL3YbfTarEQHD8XgqZqlksqHNeFn1qAH0ED
JqivnFzEjp0RtB3brnvcetdq7QRzfcSDYO7gilbisFS5uN7uvc6pWDn2ZHg2fDqFp6PL86mz68Kz
i9F3oE1I2233Qqr86CmP8yR1XPA8Dw7uNsxSqUhMRGl6hwrBBVq27ePWjlZ3mla/WFaA8mOm3WGZ
xrYjWepTDZUo6tg/tpN2AC+O2JG090AqobhiCW60Dx9DwtJcUWlMtYwvmaAZEbh9gt5Mh4UTMccw
z4hSNMmUhJcvhhdD8AVFAwEuQxf62kX6hvqozrn6qGXEtkKj1wauQqxN23dG8k4QGAEP+jA4P6nj
6XkakNFdQ4Xh2oMiOsbwWpUHRS716Uaa8FDM/Vc0MFHeCKD+x8cFlXZmk+HFD8OLK/ti+P3lcDKd
fTecvhid2Ncmx/Z4NNG0LRLtSxHO/Ij6r7RuvbJJqBIscRyMEksXLqrVgld2rljM3pKAC1TY72Pa
3UoyI1IaXLeEMqTPUpCZPkHXcghYyxnQhVcVLKNuTbMTmhDJSEAkKGQVUWyJjyGJI722D4NFTgSW
WUUfLoGakxRSviSJftq3C5DvgMaS1s3cn+3dWsGU2dXPKWqEMp81LfW8FjG8rh/ItZV1Pp3alvE/
h4cPQYfnhotgtqSChSvHRBQZkusIllsRkZF97dYjpT+6xTCezgRd0JQK5N2MBY4SOa1ZMkCQHpPJ
6egcU8kCTYqSa2hE/773dEykmhEfg8/UysiZ2tlW/3klW1RLo1SxKK4/qPRyfDKYDsu0TIZTMMgq
9ab6SuXBLeUpv3HcIqLa2W1DOhXrSKeUBhIDqiPu3JGDPRgPJpOXo4uT2cnw2eDybHorK58AvqH0
DvC39OGn5lBDvCLMLVz3e/yu8QuDOIuYVFzfHppShM9YynxdfHahpKoA7b99OgYb9qHoY43NLTP3
3mS3cTTjdXqO3WwKp+fT0TaDHG1102Nd+GFwhv0OnP4e9N1tTu2ByX0d2F3ell3FOGuKeMtL+99f
fm0UftWlnE0z/gIOTUNu5q7/fzWyhtYjsC/XHRl4DmWrbZtWi0OIz3GyQE3rBmiGh7kgqb5DdFN6
fjZ6MjibXNlPR+fPTp/b11e22S779Mn55MkZCvd73QcB99UqoxCpJO61uvoPVl+68KxMtcdTS69R
EuCfhCoCfkSEpMqzchW2v7GqZc0Qz1oyepNxoSzweaqd9KwbFqjIC+iS+bRtfuyhB0wxErelT2Lq
HWoliqmY9k4NL8V6uPrnb+j2PcAiMOhd6PfAYO92CoFWN2bpK6RijHCRjDxNkZEWRIKGnhUplcmj
TidEMHJ/wfkipiRjct/nifV5slJn1jeCyE8uJRcMmdtQItUqpjKi9JMAdHwpH/VDkrB45T1jCyUo
PbpZROrbLw8Ojh/j9yv8fn1w8LA8M8KIM1UcqW8HTGY4fHryhmTWRwBpAinZIVm2j+b7S68Irx59
cbzQl4KOsdbSKZM+58EKRz8U9CxTrHpTYqDwZmqstyULKG5qBnYDtmxumvxZPW3OPM4SInA+QWPd
Dh6+TyxjeLGWSs2J6LD3HC9SAQRiLHMkHl0I0pUZSXtYZdts2e92zBa6c1jTkvVOxxLmMcehGotM
akoqKpYkxvLMBFd0wQJTqQTecpz9kXSa0jKPFZY1ZFQfxF6yxGOCSv1CYIqS8T0UwTanECIu5gnI
939B0RwRTFY6+iGfQ86V1fvnD+NMOeTahvq3agHrw5QDLO/MY2kGY1Dk677MJcSk1cDB15lkG49A
0mOVRzzASuES2USMFs8qzJoLwBzG/q/5Y1pbzDT4WtTxrJlNQ0bjwOS+ltdH28WPKXtUT1kFKsHu
j0wa+BQTQTjMif+KhyG2FwxWnRRFuGvm8W0P0BlK/Ahf21BbRCXCwHZ9taNbIN4PiVxcu0d1ZNs5
wo4lFJh/22U+tGzhtuDYzyzdK3JZkB23UecWzzdwaBqUiI4b4TCbZogs7qIHesq3Px2ZkarwmKU1
HLP1IUAsNFg2GzGZ07iyYpJnbaEwNba5s8qia55haZYr0LHyLEXfIImKO2Pz8mEBkianFavKy7qI
LMGbE5tmFlOlZcqZBD2kr3OcQgJzIOR+LmsedQzy3md7Mq7ftx91phrXKocaL0bbyMv/FGhvhCoP
PoR7niu1Kdq5SgG/7Qxf5ohYmee5ftkyT/HCKoHJfJ4wTPwwVYJgUgotVQfSZd3sDR3d603rN6PA
f1BLAwQUAAAACAASeEJd7ByQYMcHAACEFwAAGAAcAGFwcC9wYWdlcy9wcm90ZWdpZG9zLnBocFVU
CQADFMe/alHHv2p1eAsAAQQAAAAABAAAAAC9WFtv28YSfvevmBIGSBa6xEZbBI4u8InV1kBrubLT
ojACYUWuzG15y+4ykZv6xwR9KIrzeHCe+hb/sTOzFCmSonTsHOAYiUTuLufyzcw3Qw3GaZAe+Hwp
Yu479unl5Xw2nV7bLvz+O/CV0C8ODv0F0N8Q/IXj4j2XMpEK729e490ykZHZvbE94UsbhiOw7Q7Y
PleeFB5L1kt4+EAswTmcX01mP05mN/Zs8sOrydX1/PvJ9bfTM/s1DIdDsC+nV6T//QEpPWQoAIU7
SksR37r4NO3f2LSOT4zHKBmNMoeN9PwBEsR84YkkZrKUZiQag9HccoX+1rbnjo4AlUXOlk5zptDp
duoC6u62C9icaZGC+JQ2IsRoYpyFYWWRlkQ6T5lU3DFuFCZ1zBPu5iwh8dmhrPpdyMXQ3SDS5nrz
wD3wUHEDoLyxU4kJsUIjB/B8nwx7CiLWXL5lYQIPf4HPI6YE8xO4lSz2OTjRw4eViBLoP3d7dkVd
zdK1L1V0TADtvbrPY1+8yThkEYP80Yc/H/5IOpAmElOXRyka9fGfFw//gt94pj7+DUmG999ETIQf
/65ZUzofLeYYs5DHLTa5MIKj42d7bTqtWoKGIAQID8QJFECgBPCYZB6uc7Ubk8/WcrfUKU3B8xfd
EUYJc4E79tXku8nLa3g5fXVx7Xzuwtez6feQykRz1OLDT99OZhOgTMEnx3YlTdYCuyOEy8s0d24o
+nlOvW6cI6McjLZrHlhy7QUvkzCLYoeA2YKlCY31fiP6Hn55+ABcafw0Zt4KP+lZdX33TwTmtyTm
84jJX+e+kPrOabpZQ+z8AjnoGs4vrqcVoBwyr0M1pjST2lzx2O+sg5pqZJMOeJIzPD1nenO9uHPh
x9PvkM3AGXeg9s+13SYyrYBjEeO10VzcoHJzuZWLHUypd47bgUxxGbOIO24zXmFyOw+E0om8c+wS
5XlBin5i5zpK5dsJv6bVJ6cej5H3uFonng09UG/COaa8eIuG4q0NpxdnJc4wGMIJL5bQZxjhgtqf
qPYJImCodo2EjU/QbQ1E+4SXiwbMJkqHgSCndiR2AwCTYu+k0Hy+DJkKmjmWL9oq8zyuFOJbT/pG
wgNHgo89BhhCWs8WIeKO6zEjTaxnbRVUD7mSDB6DBe/p6h4vikWizCPcsgl+5jNgiDd+LpCKbxGG
k3JH5Vuq2IvsPChoIN8Q+gtIFIbSR556+BMvS8MV1oNYsQi/yHZYhAnyMFqOdEZasKvVcZEcSxJL
zMlkWMlFVTuYV/l9ayeXPEre8kYfF34RuLK/Cj9vrM8qcvdk7eftTGkE13iywZHCf93otYcp6Sjz
x3H/J3Y6Q/OuJ/uN220P/e0ofoOjyEs/rZR+WtS9oTi7Ke1T8j7d5D1lC7ZezBZOhVml/K34Pypd
7g8wTQ5l8k4VkcX8I093xXU6O5vM4B8/l5RD+JlInYYheTMeHQx88RY89EQNrVuJMNNHF4eF2BoZ
rQOFwhCe4hB2cX+9ZbYDLAGshspul5YqR8wxVDPaKuxBcDw6LwqvWmqDPu5sH08LNRFmAKq4yInE
DB0Fj6iCSDoQcYWjBw1LVOK/mNJFKkgoJjQ+FYxRVDIb9NOG2f2a3WiW8bayUoFPs0XIu+8kS5vO
09tGMZxi+NwTGO/zDmc4fQcpgXjB4yCLKuPmJovgZRJxj0PKCbvzS+Qn/FY48xE9Ub7jpEWueomU
XBDx4s3ZxVVv201jIE2DW5YNjFc1F60W2zUBMxpoif+D0fklDZ2Y0HzQx1taOtsMiOXaadmUi6VC
jxS3gbZGp3j+31zlu30S3s8VtRiwSPy7lnXjGfZ4zryApnyqHmwBh2l7EHJZsn0j3/TLJExwwMU2
bAI+GA8hcDb176J0tLbF1BZJHg/DblNOnZqeIq5u0zLSc1/nppUzHEo0Iivpa2oKVMTCsOZOOesV
VlBJPNqWdSR3HjXHzbtpxHWQ+EMrTZS2gBnSGVq5IduUiJZYhQ4Rh/geb4HPNOt6SbwUMhpaM66F
RN5lec3k7yZYAW2RGsOkmBGILhIsOC/MkDBSVIBfBUc8fOiGyN/73TEuoRJPyeV8KXjoOwY4EaeZ
Bn2X8qEVCB+5yAIaYocWtXwLsL4zvFl3fWvfA8Ivj5OmfI5Li0lg9BgDF5nWG1YXCFt3oWMoLro+
jUjSWqtX2SISGBYtdMg32G6QxYhJwbohW/CwbX8X8nmqkVbHxgiowM6TLDfvv+RNnxJnTxruTFJD
JjvIAme/NV+8aKXpfgvV4CIxYyur4vv6siap0lQG/XV3HR38X5rtpSkhLh/ZX19FkFM5dcuczp/c
IE1tVw0m9IiRoy7OJN6v1icUfhPnrVqr7z+y8Mofzna27+IdvL1/V7iUhRxf8Mxn1zyDaZ6Fo2Y3
Wv+kSP1oZYQOQlFQ7yqvA7OwnZaDPonrbwV6V86ZPVOchYkGrLZWrlIW1zq4Wdg+V0VV85UuMKXa
tqo9skZVQf0nvJzH05B5PEhCzJyhNVn1TuDo+Ze9o+PeV1/0nvWPv7DQkjcZTsd+M/uMS5/uZm0q
eaKf5U8GmMFsFfL4VgdD6+j4Wbu/tZ/U2p0ufrN7mruVtDNVlReQavO5zvlE98T0qRT4inbXoPoK
L6uAQDTEvCGQNoLeYoMNP1eYbn3qP1BLAwQUAAAACAA2eEJdB96p0NMOAADXNwAAEQAcAGFwcC9w
YWdlcy9zc2wucGhwVVQJAANXx79qV8e/anV4CwABBAAAAAAEAAAAANUb224bx/VdXzEmhJAMREqx
g6KwKcpKzNRCbEuVFL8IBjHcHZJT7+6sZ2dpyYmBfkefahRokAZ5CooCzZv5J/2SnnNmr9xdSrSc
XghEJndn5tyvczI4COfhliumMhBup314cjI+PT4+b3fZd98xcSnNg62tbREZ7irG2D6LIm9sf3a6
D7a2QxG4IjAieRMKV7pqnD7FJVu7u+xUzCTsYYFij+HL8mctHcUU0yKKPTra5Wz5T89InzMVCs2X
3y//Ak8V4zM6vhPDm2j5M1uIN90tOWWdO8IPzVUnwe2iHeNu1X5x0ZZu+0WXffIJi4QxMph12oia
fT/WFhVXAYV39vdZ4/5vt4Beth2zmjUP6J2nZuM5HKb0VaezHV+0M3LaL9jBAWsDiH0A0VYv2wx+
IhaOChwvBh612X37ZMq9uYrbO6wTGQ3YdnOSXOXLQOan7RBY/OBG7nA19vhEeJ10KyKBjxH/PmsD
BPgnPxfe+iKIgKV+fiZgATQIn7e7lqyEa2P4t4FzOa54JLHrwdbbLRLL9vhsdPp8dHrRPh39/pvR
2fn46ej88fEjAEi8ODk+Q+VKuIvIAoNzFMf4PiUiQdGiZfRVsouQfC2NMwdwuLJbeIEfh0eCtYUv
jdTt+6VXBBWIlR6ABaB+pwKb3mbAE+jFD2nfVHpG6PGC6449b4d9dfTkfHQ6fn745OjR4floPHp6
ePSku4pc+jFzrV6zQLxmp3EADBajS0eERqqg0zoKXPkqFiz2mcV1sXzngdL02TF7Ikw7YqPA0Veh
YXHEe4qFXHPGFzJSEXMFmG0oExPqt2oIeFt5ktqu7iS8Z/vDjIM7LOEJPrTEvqg5tWgO7dwZwPbM
Dt+oQKDKtUZ0MnOENnIqHfQAZbo631pAb7t1BEy04C/BtVSFrkWgQCY1Uq8nMV0PNE6VduAbPk59
S6IRyZsX3VuS3T610Ip0k4U2wUOvwTrwc/k9LO2Sz6hVyWaGwEFguLUc2QYdFhHYwUW7hBAwwOhY
AL7OnC9E6QF3heT0BPxWJF5UUdmOwyQYIK/bcegp7rZrcAayBEcbnnlq0sFt4LJ2PwXncHCfXbxg
PGLbynOb7OdhHHgyeNmhNTfR8QxeQjee73A/VKTWaqLljIMUZcWd5PzCWDAGMx+dXdit5CWC2POq
CNAOoTW6NxkY8C9T8C1aK219yzcnT44PH41Hp6fjZ8d0aA0V+CGvSgeB/6zuwkB35ybo4wfCD6hk
LOohVXlWgn+nDP/4a0wR7shobGUs3DEyNg9GQK/xw3HAfQG6vA6tNb4wFRHGjkQdwShGkaO8OeQK
DJR2LqSmDILes1DLBXd5n6ylbqEq2l+/TjXXM4PEidRF8g1Qxobss7099in8vfv5B1LZPo4yBMmF
Fz2jWf7Nx9TJX767hEDMuDeLg4h9/cUDBpmCYMsfYIfPI4mLZ5pD7rUhVdvm0hTCMIpxPBMGsxUD
6VfUJNNmhYX1oYo6eDC4jR5+vhj97ugZS3Ii8h4fyKzWcS7M9z9+izhZfN6+/4UFmDcCW5bvIHSi
zftgFexk9JR1jLiErxhXHeULcKksVJrluHVrg+UarrkAB11C4rrQlSfqCj/7IWRZzQx6SEwO4wKT
6bwdEsbtmdR+hoyYKglERtHyp4Xw2Czm2oXwUzAG4JHLDd8Ff71rzXh3Q9156Mx95abI7/1mb+8W
GUcWrW4baY8CSFW9cqgFz7D8GbyDqiOwOYLOjQmjuvCpAhB+bege2z11RNTTbddnSUiy3wam4Ja8
QDzBZR4aianH4/PzkzOWhAssxGwl8khEvHHBhhmYrxZikwzMrr99bkXnlHKrjRDnJuaefLNB8mjr
tFrM68BAkc2hlqqevs6MD5NKWEAgC+bCkRjZCgBzy5p6PJoDm2LHEREp0wlxi4lgQaEBSq1I6AU8
0lhI5MU3h/pBOILxCZeXCCswGCcFLIdI46oog/gWeEV11zmizCeegByn6KESJGyeA7onekMIJE8B
Iag6O2nqapHWyFDhmE6sPRIvpbZQR26jDBkrVt5FqRaSrm1wPbYvUa2e8VVSxgUimMc+ErFti9m6
or5wqishOST4hMmBzeDoB1Tl8BJW3y+iEDFKoxM4pBxn4FqLWIM8PGEiYQscWtMq1TwtWBFqRQ6K
TviyznVBxr1teyInUPS5REnWhMEMDbHCnDB/OmT39h5sHQy3BtjrSfI529HZTzZ07zN4j0IZuHLB
HJBitN/iHlJPf3uvuQ5aw0zOx2lj5uzsCeMygOyrEHml9b4AIKAMJVe75wrKZgapmgJHj5EoW6ox
MUsXsg6YcoQH3u3fZSpmURwKIF93Mwyo5g2VC6fM4BWcFRX5Dfk9LsEq0+WvYtm31O0CeSkjgD9y
+gAJL3Kmwsx1vBkcAPtL4gBtswyzJoC+NWcg5K7DVv0mWomhuMdjo3paTME+5/utey3clDO+gGnx
iBzJXEJhYv4kkuWf4Qt21tgcfiEKVqczcg+GmbkzwVRRviRZQCdUsDbusy9VMJXaF5iUphIre7WB
A4IZRlfYWHKMx0DGJobENogmXg8svR9yMx/s0qoV0gTkPBViDpm4FE5sID6VGoQFBP71x7+yETYZ
w+W7mQw4S/05i9QbGcx5fxVQJv61mlGQ+UxLl+Gfng8qn1jDIAIXBq46XQTh2y0YymAuOOpo4W0P
H7XKBA4I+mpgGMzvDotegEga7MLT6tIwBeHHRsDxKOJ5Qy9xJXpCxT0c7IYrGO1WUKr6j6qNZGsx
9Wa+MHPl7rcgBzUtxolR+y2LWsHro1nUkATLnEhPoawUntshLGUAKTMzV6HYb82lC6rbYpj8g0FC
WG6xBfdi/JHG8rpjJ7ExubwmJmDwXy9SU2O/+K0EQBRPfGkI3Rofi70ZV0YYBF3bmUFDxcXSwcid
mDD2M4aHKT7MMm6wa5FYZTkyrY7nZV21a61iFZ4UNJXUbKLcq4qaeekSNMmojj0o9oFrhucyBDzh
y8B1U22iWHdB/5Ai0TerPrioqjIraoMOuqorFdDUHsSop/QqBjYGC19GkbItsrWwS8c+g7IvSg/M
zEWhE/G556U2I30ohFzRwZC9w9Kob+0nok7GDWE21m2IzHPb0gWbXv5AOK1Z7Ta/tAxGtKe+Gbsm
5RAYAt7EcCMSjK85IRMR5T4DtkdiGkQhzy2FuzPB6G/P5QFE3dZwRK1mVGhceRMg6N8LgPbZZ5+v
B2UzDzJC2gKBCv/dDOJaCOpl8/lN9lcBtdskpbVW0Xxwswah9lSrtGYdSq1n9cZspVZFh7aWRVhB
poImh9e4OhCx0RwM6ijgpU2J4VSJvdZzUKJPXcBiFl3vS9azzjbhbf6AuZa/fGcgvG7OP3t3gLdw
eMxNOchvxEGr9JZ9/HbsW6NiGXtXSXsV84Aq2zUMJkdt0wByZMKvuNZiJpK6pyqIG4WPeipgizfc
qgmYuc5gvM4KwHpqNk1VUvpwX8+urIukFpsPzmHILhuPbZLcilE3B1s6phmV4jkZSnsN6NBZ9WnV
bE78/PCEal1nqj6NKjOptp64DRM+25wJULn7XF99nLzSU87LJKm8DVuavcJGWWhmsuCkbCGU2OOv
XRct/7Q6LrJBYZS2gQ7AuBtnKWhJNlBBExXs/T9opiJ3Z+mq1J2lYwMouGfkdXh78/LKntrgrrB2
z+BeM3OyNhx9ScMoy5/cm8WkNOf7iiZWCkHp1yxYbsiTTMgbcSdQBpsYBtlBtOcPsnZNWnikR1Ym
aOqkW0Y99dHpEZ6arXXNg1CLlB5YW0HB7rdwtdgwYq53ijkjCWdIWfLeHl4mTYXEOS6r2AXb61cV
fCOXkTz977dbSi3ZG3qUYotmprmJpVE7zKaHbpJkcswxffL0HP4U5nT0db7hhpZDl509SAOcl6vU
lhFOq90KYafiVSwjQD66D3w2WgWzzdtIyT5m8GoRiA1VgG27gDMJdOtAGGrdVrlaD1CG4zCeeBD6
EoNT7OgEr0MKbeV2GXLHFZ6YpRk+Bskuw55zqDTo7m/3UtQQhIZMTyT3o/0KTsd5Q9qxPU+cJHj0
7CyXId0KsfJIwYowaw1j86Lmo2SpdNvbS4jZb50Q9jzR1WzosnhpymdK84OPn94mk1dNB/8HEqli
gy6dzCJqr8mfKE/IzG8u0N5KVNOzibosp5HFBJJ9RTNdegcEGvl2KKF8iyL+AAoLYiB5TCXUVgT2
ZukaPa83eryWev+jHSnT73/ZoaFaKwtQdhw5AKMQqGiBnUS5t0ftkOrooSd9jAU8yrXn72ATybQa
pwsYFTvwBccsIuHzgDeGicZ49KFab4cZerj94+uuHYxsOrekH3T4uoqBsqgRTXkWxjiv626VMMXB
lhRPmprMEF1xpuXRVmJX6IEDnCsP4st+a3TZv8+4Cy7+4T2NhVs/hIM1hgUtGttbDYpJLzc145r7
N5wyq9xX3rxKqo6aNpv3/0npU3cxfMNU5QRMUVwK7HDv4Hhx0dM7yg/pOlLF9CrGOoizT/uZLnxA
pkL2uy5V2ci4IURalfExF8b7XZJYD6Naa4X6cqTLBoIocyiQfcDO4klkJGRtbCXy4aVNv1KQfLDX
SIebVk+s8xfWLRQF3ek72rBdhnNl3bQ5XYSMA2Up3AIZBfutNdV14IvzlIDAS3F1PWTcU4RJcYfC
Tgj8X2jeCwGSgEhg32yMFI0g22TSX/4AsYl1VOiA0nDveuxoc6sBaCGrvqa19z/g1+om3JquFaut
hvrkoC7fpdQkGa2lqQ07BoDTRAXIO7ROrfiTicZnUDMsf4KiAZJwXFSc0Exuj/rsMIGAW5M5Rdf+
Dz+FK/4ddFE2YcehJRFAbgFwtFKmnFgU/XhdkXlti3iNB7+B9656bvTaNQNqVaddcdggEglKs1Ae
5lpsGgek6pp4g4kVtv9WiC/75I0zqLLjTNFWZaeZ4IW23IxXn32h1WsQX0SS/wOIfIEFJuQ5Phxo
T1BpCxOHefx0RJ0mPcSlnMmeByoUa06lszeDyAT1WwgO8fHZ+Vn3I/rnZBJx9cBfqa+dm7TRPKtC
CIOqGZcVOg2yRdVeyVL+DVBLAwQKAAAAAAASeEJdAAAAAAAAAAAAAAAABQAcAGRhdGEvVVQJAAMU
x79qUMe/anV4CwABBAAAAAAEAAAAAFBLAwQUAAAACAASeEJduStzC1sAAABcAAAAFQAcAGRhdGEv
YWNlc3NvLXRlc3RlLnR4dFVUCQADFMe/ahTHv2p1eAsAAQQAAAAABAAAAABz8Qt28tENcQ0OcdV1
dHYNDvbnCk5VSM7PK05NL01VyEktUkgtLklVSMtMzkjNLMpXKEjNyVdIKsovL04t0lFIVChILC5J
VEhJLEnUB6k8vFAhtaIgHyimxwUAUEsDBBQAAAAIABJ4Ql0sSIovigAAAMAAAAAOABwAZGF0YS8u
aHRhY2Nlc3NVVAkAAxTHv2oUx79qdXgLAAEEAAAAAAQAAAAAU1Zw8Qt28lF41DBFoSCxuCRRITOv
JLUoL9FKIa80LzlRoTi1qCyzSKEgNSdRoTw1icvGM803P6U0J1UhNz8lPrG0JKMqPjm/KFUv2Y5L
AQiCUgtLM4tSFRJzchRSUvMyU1O4bPRheuyQtCti1+9flJJaBNKdX64D1F8JFnQBMhTSivJzQRIo
5gEAUEsDBBQAAAAIAJh4Ql1TItWPHgEAAKsBAAAJABwALmh0YWNjZXNzVVQJAAMPyL9qD8i/anV4
CwABBAAAAAAEAAAAAHWQwUoDMRCG7/sUY+uhhbqLFw+yFCpFEKyCXoslm8y6wWQnm2RbLDn4EL6B
N68+wr6JT2LWWgXFgUnm52e+TGYI86vbs0tYH6cn8P70DDPDeIWnUChqWpQMShm1tOQgaqi7FwKB
a9Tg0Pa5loJcmgxh5sAw55kDZkw2gULW8eRUl/I+FoJ5lgGCLZSoncjAd68aKCJaMLZ7M1YSpJVn
nKOLwPxcKnQL5nkFg9EyHWkRXKOkx6/raMPUvnSVDluqMSjiD8FV4XMwjqF/PnhtxofhbpmOB9ME
YuQX5YJEqxA0iRVrfbVdcbKY8p3fxw02rbQITKn44Vqi2LVm+97fqIP/WddWxGVFEm0mkfX4bcyj
gNKS7s0//Dz72cE0+QBQSwMEFAAAAAgAmHhCXbK1gogJCwAAiBkAAA0AHABBTFRFUkFDT0VTLm1k
VVQJAAMPyL9qD8i/anV4CwABBAAAAAAEAAAAAI1YXY8UxxV9319REQ9h0eywLOBIoCjCGAckbG9Y
Yll+8dR0184W7u5qqnqGNVGkPOUHRPkDhAcrsXhCfrHfmH/iX5Jz7q3+mNlEiSzh2e7qqvtx7rnn
1jXzyednHz81v/zl7+ZB1blot99vf3Tp4ODaNbO5Nf/o4ODI3Ljxe5e67dtgSmcKFzt/7gtbhmTO
zp6aJpilLb4N53jobtww18986lxtzS9//Zt5OK7m4sN7xtW+89E4E10TNjbubvjUdb9O5lFTxO/a
bmZ8kzpb7S9q4/Z9Gz1+XfdNUa19g92LdfTNyqbDmbGd58ZhDXtT/4d5/Pz56ZkJy+hXttu+x/di
RB02jq8nJ8zh84NkQjuEwyR67y5dse5saWFCiGZdIzJ25ZrO0Te6HkOA1echWlNa01pYb2Bb8p07
HLzBg9ZVYfwzyhoXN56/Nyfzk7l5vsazYF6undm4mgvGIJvtP00XbcedilAH09C6IjTnfvtm46p7
ZmMrX9L2nDNLa1yJ/WdwuVgny8cVItH75+vl9n0F99PMFBd24xBlBA7frdY2lvyRtu95nLGFSynQ
JLorwdLDV+vYnwmbVr65ZAhwlqV3ZoVwih3wXcM2y4biKTde6DdH3cJYvE2D6bZH5lvNWRsYWLvu
Qo30FraWHCTHyCOsm+0b7krLnrm0riRQ/V59VrFVA2O2b3CmNdd5PhxyK4BX7CcelqE7xIFA+GM8
JmYKgKOvjbtaG18H7oODQ+2T4GRRNmlZzW/HC9g5b7vFPWBDUbCXSOINFWEWO8txpEVy6CPf7e82
g6e1RLzysBW+R2dQDGXwaS4m/bEe4VTS/tqlHROJ1UWTjpbVrcnGgGhrI9OVoalhYmjWteb/y8/0
hMWfXsPtPy8Ym85ddhLf6F44L9/QYYA0rZep8916+67HPE1hafDrfFq/gYCYAYlatmtA47WVyjD6
ganXpY1qwIMXa7CMYmD7BiCABZaIOfeNV1DDBhg1ukKcE1eo/IifLC0L6rCm882FrRlCwFHe7aQT
3/gVyaYPwsa9nmWo0L4deByO+LhzcPDpuik8LCdAg6St4lkCRmC3IZs1bigp1hO3G5M3Rctc8fZk
mhsJ6jKGV/iEQU+9TxLNi7Amua07r6GEa7MeiHYZGde+AHYi9TbMzRfGljVimcA0NAXpLKLPlEPu
K7bvS8Sl54egWAUr3SwCXxzl/Qob5t0lYcuIw8Bq+y86uUJPUXzCuQvno0DYPDk7RWDAD5E29K94
vG3tKsf73NcKg+c2unPkfcQB/pDyiKFhQNxl63sWnwkFZYbKkCK9RuH9nrnSEH4AAd0R/ka0CZPC
a+YOu8AAnHXpwbyEBOAggEG0YAXdZGLN1Y0SuhXMQipqnJuXISCk451Ew3Eu3GHP0AqSqgz/XB4Z
1gqD/9qFd1ejCaPIgF9pi18/OZ0NMYiG7kTtdnh59vjB0cndj2ZmQAey8hDd19tpyIUvMxykvJcW
bpX8yXjukflozFtpR2BzZY2dLaXqd3jo3FYXYmHt0Lsnrd9KGx/zN+IJCiMkUviHH57hnPjhZ+Wc
TUBT4FZIQgVYRpoPp+bmNIbO9bwHZmUXLwLt7/tKAAJ6SoDEYDWgAwEa+LuGZ0hTCpmIT8fqcjFq
6aDXWWa8jWEj7ZrZIn4gL+q2QkhAh67RTtKW4Zv0EjzvFqwvhABNAaeqtNByWwjg0dYyYYHG8TdR
iWNRqB9+oPQxd4+P4T6XoiaqHvCZzrV/39T/zduLFswO7rL7LC6dLA0xQXxes+x3P8+OyDZQE6EV
2pDAL6YnkEuRZlc5pSt3Ccz6TPDApfqlIsqZLrRBKxqn+iMCzEfX5eaPIOPp615tjSx8W1lzAaS4
y+yZrr0nDcJfanr0bNOrtkW7XiJINxdzM/l0ZhYIXogAj27lzAI16rqELLCA6qkhyPAL1+UQT4Al
ApKnEFToR41NtGUxv+hswU4gue4C111dakZnqVpaiNl3G+eTgOsBMnPhDCSk4b93DkUvraJsg/ir
wmLK4rKCsChvypOjPmVMz0IN/mJaSKePT7MB+EMVZK16OLskqYATYCJrXrllpqmNT0JxPVLB+Z4t
iVGEVyqMJoKoJ6KZJCIyI+XQ4GZKCgMilF04mrzRDspAVPC4DuxaxL4VAyhSgB5FUR9VLc00IuXk
4OAhqT5zalTpqNxFisFWWU9jE4rz853ufn3iBklX2gt/7HUBPnqE5nGY+/kEGGBkMkspcZFKibV0
PHiS8wU7bMVOOuPT3MREPMOB+e35HcHkr/SP45sndxbs+KglshkaFLi5Cvic2163ig3QlmccW1ds
34kkbeGtrVzhDtmLRLiDoNiOwD1ZXGiBgEUpQGUoYn9HNtwLYINgQePV4iy5JGQ6EhhRaLE+Oqio
MtxnQtwl+DxJ6LWSSA8C2ienaVybJrtFB6U4OMTWHBrqiT4vCsKP9X3My2ml9A5Uwe7OjLrmGw5n
lItxKw50YEJgVjE2U9rPGcqdTET4nq3qSSmTCbrLwz4J2tP7I3oXQD/VKvRxBKoFaP8reurlIxWj
V/WLeKU4gSDgHsOU44Zmf30BtOC/Wye/WRwO+gMOSg1o4746UkwJ2O0Wci7BxCSlVtIi4i9X66Du
72uJslWbU0hXqd+hXid1el/Uf7P9XlQ+96G7vQq3aX9KY0wYbltwtsB7mJk4dqarowplApt4KyL2
k8kMAR4q4EABF60oDWYkMdEytOztpad+lu2UKXgy79wTehTpP8GNcX0/zuM+k1Q6wYfOvbLNflZn
RmRF5VbDNlzUbN+nKwpxT1lhP6ARk7P4boOOVWZ4Kgt63T3MakEhQS44sgqBjY40CknX5BD0dHrr
/6RTy8XHmQwflb6bUgoyz/sbKU3hu/wm6/pSxJBc4vh8QwF3Aj5BfYS9KM7NA54+y/7acTZ4SyDJ
QRs6R6dw9mQw+FH1K1Wk3id9+DlHeXJnlhWTljwFXc+Qwub79xigkwG8o0KWe5JoefFyX0aDOt/b
7KrfnXT01c2xREYQfLhaMyvzfHm3P/SQvJRyeAkmvIuIXWnGrj/lBUpWOR8xrUfm1+knjlOyJZxo
EwemfsKqebuE3G//0bhcIl/uzlzOnD5/JlZVvpZbEimDNhfnMG3dOhbXdGwmR2A4uN+zLmtHZhin
0R9nGhmjau0l+5w9CGVE3tVjc9Qpcmc2nEqafsbT+OT7N4CdBg80NiWSTIiMyvanqvOE8iifnLAg
e55Ta7lSujIsu5vTmgv7DGN42yW9wNu/TOjv6FjEjUQ2Ky9RzhsUl8QJk90fnnph7Zylc/9yLTnD
HIHpo2DdjBd8OHWYXfPFAyJMSeG2P+WpwCQxbL8D9bpFpKpc9wyfDdHnbWnX3wcp0FwsacLumHvu
fKdMj+5Thx4M+SogfOsalfKi0HNkOZ0tQUIoH70Dlruvr47k3vtIPhouviZXUKpzpU+mnetZaluz
+F3HD3+7GGUVBCgDqnGhKvdLL3ebuQo/9ZnW9VKplZtKkomsoVG3To77TM+GC1WZEA91i6s32Pxs
Z+V9U4WCrqZOLxez9FD/OqozmYenMTl7fjaMKJc+T+rcVLqYSlHoyy7yxq38ptVVva4UPcr5v/Ki
A8BrHJIFel8dfRriK4tUlvy1GG78pmWOzioUL4AO6PWT6088Ymmze0WRC2kQd8IwHbxOWRnRru/m
ffc5Pjg4jb6mBu0p6t7IebLv5o5kAT5IDyndbFRXUxE3MxeDrphpDLNh/+lCKXvYw34Pjvp2v5nP
D/4NUEsDBBQAAAAIAJh4Ql3LJj/bnhEAAK4pAAALABwASU5TVEFMQVIubWRVVAkAAw/Iv2oPyL9q
dXgLAAEEAAAAAAQAAAAAlVpdb9xIdn3vX1HAADutTn/Yku0Z2MkiWlm7I8RjKZbGCDYIzGqypK4Z
ksXhR1v2eoE8BchrkB8QJw8L72KejHmZfZv+J/tLcs6tIptstbEJDENsknWr6n6ce+4tfqaePr/8
1TO1vj9/pP7yr/+pzvKq1qne/GHzP240OldLHX/nrq9tbJT1j2aVmaqm4l9llK4bndq38msyqUym
UpuvtEqMil2m88RVKsddHZuqcqp0rp5MHkMsZCmnCm1zk6qzywu8q29MCZFOLUv3ujLlfDQ6VkWq
a33tykyrGnLqcvPHCsPK2lSPR6P7c8z6q26Nk4kaX3x1of5GXf7jM1ubo4PHyuVYC1YH4RiP5Zxd
VGqZuu8bo7k6w3s2r0251ikui9LV5sbi0Vz9xpRcJUSvjC2dSrR663I9Hx1y3ksMwXulqVS5TJO8
Sjj/4ZTL06o0SZMnm//OY6uxDOxnTT2IAFW4kprH5ImpYl2W5kZnMzxIXF/lWHlm86Z2GOcv5qMj
Tv1887HqaY0qjV1eNWmtuzl0Xer15kNFmbHOChdsnbRqh35PaYa1KSuYOyjFYmRhck1FrR9MZaln
F8o1coVdGTU+OXv64gDDZ7PZaPTZZwpm2BpBjavNx6FJg0EPgsFOSqtL6LWCiVTuBhuZ0m8UjTiZ
fDm/x3mrpjCldXgIUbEpa4tpYDt1eflsPlJKPXcZbACf9N5WQepNY/XjdoqhUmGFySRapvOjcuWq
el7UkUgOaoONU0u1+Pdg1p1X5+qcOrWVqjd/zJR4V6kSew0HgxtVojIoErPnWFjrNGrzAe+mMLQY
QByrCh7U+YK91dBNkLm2rZKCwx3Xdg3FwTTmtjZ5tfkR24aqsPx8a0YMpvqSsPnxQMFTRcsm5trm
FkFOAf59uGhUJO5V9X2KUdFURf7qKMLCore2iILrnXhv5dJ+eyZTO8RWVWMXkNSGinhdf1rZMaJC
27ft0qaQjI3gVgmdUprKuQHGeSEAAYG1KxwNGVnE8e28WBURJ4GR3I3jtvsS56MHXOIFQ1ggDMqv
vKwQ49j9HGs+7u5GuigW3O7S5vIXcXRtb+QyAfQsZP8hvvFDVli4BGuk2QXXNj+sDdyhMKlWr81S
fHKmTuk/x4WGQogLDEIg4EovLTFzqJ/O6SH25Ddni19jcfh7MCU4RfNVrWNOFGETcdpsfqCjf7t5
DzjUjPjEAlz70+Y3Nr9VhON2AVMsFUgV00WpNr/NpvRQr/yA1megF9i4FE/Zbl7emZlbkxWpm1NA
FOYc5AmRDLwm5sHi3pKdLiv4MDHhtkBAaawKjmEwqgFurS0UhKeZSVcMHjG+dwLakabcvMciYMPR
QwmIZWn7QNImDlo4yNXtGMqxvew2VYzRgniGuePNx8TeuN2XHvv97XdxLH5ZtluLHcfPwuBYu3l9
W9N3YldYYkGY4YmXCEu4dEUMaGrLBEoU8OpK9brUM6itEuTSCZAfgFTyFWAuhp93y7WZbEDQpsEr
2A88AdYtZc7BWKWJToItlvHWZTUAE6wguKSRYjJdI74yOsp89IhqftqDi8fQbWvhcgfixFurbVZM
jDyWHMtB8GKkssvzY0Z+URqTYwUUMpl0TwUnsCkmYApA0nZiCsYQM1DwPwTusqnM32+R+Um7rqAP
ZYAYJXAAV7dQgkHG+qKDB8nw3IxObGyx+LLlBt7f8IPJBHl2qpLhtlqwFpUPHxXl5mOBXAUH/XJX
c+ov//Yf6hR+X9a6BSdRm1dp4XNib9GKAfCdyaddaqN6SKMO5w/mTLyfqSt4+TVjg4bbvKflKiRg
BH5cuhwJ95jJorAS5z8yOWkyoeECxPEQd5JXw5O7W45dSQZVubdkeJCE5WDKW5vBiTMKeCsUwROV
x6MZzEACuOMUAU36xKdNvcBIWu5avzXZHu5z8GQrU6c3zeZDRs2ofnaHWs4LsWcqHhwSD/IVvB9Y
oek/ceM3CdfMnKBkBVyFvhCHARuI8Iwi2IR7q0XN3DFA5wY2koAai46HSA5bJoOg7pId5yH/BW2N
omi0cEW9QDr78v6CqQdXaoHsvnj9+vXim6uzZ2e/PX56/mIh4MJ7l2dXp/KmMJIZp2Y2FFmjsf62
Ie25wwIk8jT0t3LtSg6855wME4Be63zzB53QCkGBePH5J4CvzZL+j8/KY6rrLoYw2SAkMozUrV6C
krUQeSvCdyS2WYaSnxD520IjxFLe5LEwqGaJjFI3Jjugx0UA5DyRdM6LV3jMH+QKr5oyjR57vDJk
D5uPtS0cfSpCfRGbV6u6LpBix1j72oEPgeta5BDqgsYDYHln+urq6uJSxlVAWzx+ZZPUvBInNRRw
//AehnNQVXlCU2bMQJqlBD2bpgLLKbzzNZVfRV3ShskrVCC3FoKQQEGkK6OG9DVkUND7zXtBK6Qv
DnnToY8n7R1Q/vPn9w+/mN/Dv/uf/0vUo+0glXdrmFAUMCmozU85qZaUWxKaANIb0xZzmHqQYKYq
0wSpSirBPnbsYvehevk1+RJE5jJEAZNvM3cLwiMEK+9x4wF7n6sT+qhsGaapdFAAuGOx+WmZ2tgJ
l5pMpMjCRh4egc+vS8MaSWSHFF3KSvNhISWbJLEK5RrWPg9Fy1k7zLWaIs0A2zpOM/0Mtr9dvHDx
d2+mHZKW3nanF6fPhNMSvWOkHiEVCFsUwSteJvl1WFSqZm+UAY+clagUNIb/4hfyuDK6jFedie4O
6j0hIODPpekm9PuWJGhLKbAKy51s46+jJ7Nrx5gdRze2XjVLsLxsURU6W+mmWoRJIpZ+hz6TGkZE
uY/GYGlIbDtbRcaGqyRqVqpZpRYV8Sx3CEabd4nh8JeLxKwXeYOdvXsHitsYDs2+QzSqWUDJ1C7b
5VBH8Spzifri4cM7T1uN+OJF3B3JtZdyO3ob/s58xSfuF5vIh3y0MHW8qN4gPrMk/GWJ0MIPVhad
Xbx6ev7q8vTFyzMAd8RywA38En6LfPl9YyXjfopEzQeW8yTfNbeGicgHBclBu+qoF/TAFULX5v0s
DTxK7O7ipvDGDvEA60mZdDlMenetFReKBtomx3ImK6xWatFUULOLdeqN2DPCvXt3nu6R0PPU08TW
ooaOkVI7dFAETfTNi2d/F+0QI96/Ov+H0+fyREiSN2fiC88+XlwBMEMWJ0PZ/BeMEIh9b6v/hxVz
i7W2CLdc3b/jZz4tz/Gu6W0tVOxO2Njj3oNJ94+U4P+psHNVIdcWtc8PrQv2FSjAw/pn6WvLIjU1
FVe1TNxsfoKerl2vcSHFBrNs8MA9OQd6X2p7K6k79JhYylIgAFBLyisDcmu4mS/SSqRioOFd//Jx
FNcohjVofk7Uc1oCevsIGWKZGjWb5e61GsRoF9pSpPwaufo10FA4vdSF3zwl/7k6uWAO6HMNcMgU
QA+7lEhnWS8jAiSeSo/GkyLAPzhQ2Gu0LTV2mipsUkmbsdWTjKQ+E5DyH3LrkNeETAbuJ8vH6tXZ
c4UXVV7Nlun9bZdpPvJ3/BvH/DMAF0/6Lk2L6YQGMGlcO7ztEWu3cSWl9k1jZu4xdFCwf5Xo0JEK
fMyw5BQsQvZH6i6wKctuFZGsTXqj8wBXvRRde74eO7itJUwzBf/8p8s9pWBAuZ//TGfql0fI7Bgk
GHfT5D3pg86FlFzU2TgSFR1GB8r7elUY8ratHnpmfeBhwFTCaLeOTcq4p0i7HBY+vPWyy+n6xpW+
ZCMR2VVBaGeIBhxUcBxoa+J+/vNcZgt4hMRAueEX9lbqxDe8uFBxYm8CkjGuYq+OHV2OpDsPXcve
phF8AX72EB14D7Cj9QPpgcvE0hersIdsSgPJHjEUfjuZnLAAtE7W3WuxsbCakSPIA99j5pXv8rYR
gA3x5h23pEVqXdES56iOSY93GmO+rc0awMueTHxLWpq2pfnWIHtsQ7rTWUTSe8t/ERV/HLq6SwGj
nUng7i1pw37BHdkpYSXXTkoJ55WKUystXs+F87XFpmkGlDy43xXPl19fXShh/mDKlu+H1ovebgd5
SCR7rs7+XaCx3dFEyN5V2+RJwpQlF/PCZKbergVxm6KYY+NUdLN+5EfLIrqtsS0htd/XTXKHd4za
wN6JSy8oa+gI4vFS/7u52vx74OCsxlHiQGKtsyWrch1OgaJTFNuXcHBAZtJBSOdY/fa39I5C7FYM
8CE4SZC3vqQ8M4cv9Fy0Z89eELwcdDV6XZI9HY7R6Js7bYzpMBF25ptMWBvWvsS9AwYd2o2Zgx4e
+dr00NdgcMu/pcJ/GbUxDbrrUuaNqC3UDiNOTMu2NDH0tLoppEAJaViqx6M70oNYCeSrf7qa9rsD
IaftCK0lGSKvsL2Sbe+LC4SE4NNdm/I9DHly5UUTDm7AdLUHlodBkVUPbPi6d5mQeFD/+YNA3/P6
RNNXZY6VZtb1itnF3F8mbtEyZzqxZQidzoCVsINwKNEVisneVhV7StWWf1Z9M/FwoP11FPl4w1Ae
JlLYOHWu4LIOenFu5OAhQH7bymgP3zKV21x6Wz0vPh40P1ChZ0LfSZG0wOrwBZS6rFmHJzW0ee7W
naGovFBk9OHPqXF4Ydpv+Fx+dTw7fPjoQBoW2wpaJ/4w9KQrZn7+U1soI+Gp47bl3A7ZiacbeJCU
85oFaGF1rxRVAk1LVsGMEX9Ym3XtdrxcLfyhFB120LZX1zpdSc2TGSv+1cokEPMs0TMcZoo9TW/Q
hQt6BsKnFik7/i0S2JU12O4LSMFeuwwsbid78b12wx4bW2uw53MxtYhpabs/y3F7O2q5P7D2Wx+H
I5SDgOGtyftlvOZB/pE/gGWXSdCMTWB/HzGW6O0ZG9uB3oUSs9Nf2/HW/lPR7tuZMMV9zcFPuB4W
8GDfIeD2DFCmjG3GQyGmTenzbgvs4RFhqd9+UmU7TtPby51jL7PVL3IHz3OxMfFo+pSoq6XY3UlW
0bCcXxBfvVP86BM8UK8KjWMybZbhWtyzPaXqV6XHW5t939ipwBwKefAfXHVSg09n8q1FthPlPXy4
kl6iruHUwMYAJY443R2fsAmpzDX06kajd/Bv6uNdGNm28d+N3kGk/Mc7O/2BT6AjhNxvO/Uc9cK0
bX0Ek+un/Xfq0b2W3Vfy7gnPJkUuBEoKrOSXkNXx1dWzAww6urcd5W3pMusbq++kOoPiJKVPvQbA
vmNx6S/a1PPXIuaBIOrxTgTE+3z4odpi2Vw9/3Rre+eQnYnW+1NNZiRxze9N5NCovyVxJCpafrCr
L0lit6k+ljNwz5eEKzr1FS43H0sbO6EbvmYdcO39DJzsYc+hne8+R7ulqbxeI2SdP50D/fbeIXUD
sbJiU+13nP73bDa/DLukBsBYV23qx6JDL6ZHVWvX0tTWtU+G33uocT/t7TwE0j21JCk8kE/lS4dt
VqAV6P646Sun8Kg9o2l5xHh9OD/sf3Zy4E+Kw+tyWgmSSSNgSnaVff/9BsxEB8oGx/EFIJs7U7ZZ
5LuS8FFD/+sHEze1Fk1jXa4w7TmdPwL1vfHB6RZLyGem/rxSp4jON0XNUhGOZcOZZ8YOFfPSaWbp
4b3vZZiQe4SpY5bBhV1ggx3L1gUPZT1og4kzw/lvKExNACsN6YQ3Pk8Lttz6iaRFPg3lMtKjlDB6
MAiI24RjOl8a983ZtjV9pc1IlMX1tkM+G6/0mkfJKHMJ1TxkUyvXrPnFiSYp5+dMsuhs8yGxer8C
JDiDLDGeJ7rToJD+J0exW5YDJY19rlJxU4K3eedCNp/0IoYdCkoKXfgCqm78huUkSUEkcofErmy3
f+7UnUT7MxcPFhzWO4ryslAROuybAkJmFfqCjV2DdfgTbvpZKwC+JEcpPSJO1/QfgpARAgwTOQ+M
/L0Zd7L9hoBHUEUqFfMTqp29RJuvN+85bHo31d5lXmINKJt8PBE4kSqqjQKOCR9x5NuvOMwQ6v4a
tD8EAEENYl9athwG/jgKZyjzaoWS607oDw6izNYRT/Pat0O3RYopkaKALvNuMVzL9uvFwH34peW0
ByZ0rqWrpfLZwgrBQQjJhy0DnI/+F1BLAwQKAAAAAAASeEJdAAAAAAAAAAAAAAAACAAcAHJibGRu
c2QvVVQJAAMUx79qUMe/anV4CwABBAAAAAAEAAAAAFBLAwQUAAAACACYeEJdl854djQCAABcBAAA
GgAcAHJibGRuc2QvbmdpbngtZXhlbXBsby5jb25mVVQJAAMPyL9qD8i/anV4CwABBAAAAAAEAAAA
AJ1TzW4TMRC+5ylGyh4SkdhAIw6pECrQiEptiWiPFSvH62SteO2t7c1P2SLOnHkDDki8Rt6EJ2G8
m01JVA7gg9caz3z+vm9m2/D28ur1OSyekRfw68s3ECuR5cpAIoAbPZWzwrLNj813A3om9QqewPjd
uD8aX0DOLAMDE8bnZjqVXLTa8B6kTsSK5GkOGGKgGVgm7yAx4KQXBE4cFjrPHGZ6YTUeOizPaQ8m
UuNeP0p7CJYwzzBiJyrRLqFdEGBcgE2FtHhCionhRSa0rynShCUYv958vQiXTliYKHNbiBAeImIj
Qgc9avNzH4+knnEunCMtLF1g9acW4FLSeaFhMDgC5xSk3ufPj6ubOi3WLBP4EjmyqXGe5P64VV1b
YzzQBbN0uVxSFDFRdV1l0oNV2/R2gI+5sF4G77wAehiJ52INhJCmYLxv5RB0odH1wEvamrzBOmk0
fIaPNDhdos9l7XIZHC63/nY7tIy6W8lhJUKvgakt5UqP8IVFI54O6th9Q2O015Pgdu+gNaF3vFDe
uENWN6STJaW7VTge209/yVRzdGlW3hktSiyZly4tK21cVBJKn+Xd6B85H7xPb8j/iN4h0D+qvV3H
U6mEg6iwstoo0F2fX0U4i5jivJV69jhcMARTo7+jvtxRqUeJqwJdn+Ik8JmMw1+ZuYf7vThcvflw
Nr6OR2fnp5cnF6cQNV2Kw6xGTbLjVua+muvHkJyDQsvVkNpCUyTbn+ZZGHHisEeNrPvWb1BLAwQU
AAAACAASeEJdLEiKL4oAAADAAAAAEQAcAHJibGRuc2QvLmh0YWNjZXNzVVQJAAMUx79qFMe/anV4
CwABBAAAAAAEAAAAAFNWcPELdvJReNQwRaEgsbgkUSEzryS1KC/RSiGvNC85UaE4tagss0ihIDUn
UaE8NYnLxjPNNz+lNCdVITc/JT6xtCSjKj45vyhVL9mOSwEIglILSzOLUhUSc3IUUlLzMlNTuGz0
YXrskLQrYtfvX5SSWgTSnV+uA9RfCRZ0ATIU0oryc0ESKOYBAFBLAwQUAAAACACYeEJdhou7MGgB
AABBAgAAHQAcAHJibGRuc2QvcmJsZG5zZC1kbnNibC5zZXJ2aWNlVVQJAAMPyL9qD8i/anV4CwAB
BAAAAAAEAAAAAHWRTU7DMBCF9z7FSN3AInVRaReVsqCki0qIooafRVVVTjIBU9e2bKdQVhyCO3AH
tr0JJ2FoQpGK2PjnefTNm+cWJJfp8ALWJ+0+fL6+gUe3ltt3A37jA64KsMIJMOAyVWhfsBacGyuF
q3WOIedNZbPzpjKiJVPtHS9HQBCPlQ/CDQgBEMH4apFMFuloejtOJtMB3cFuPzIlcwMFEqm2Uhj3
bRGOrHFBQK8LSq4dHjeUuknXPRgf2jYMyKk2K4RCwIvRgkil1AQhFTKRL01Zkhs2u9EyzFmCPnfS
Bml03NgmZp3IAZmdlQFdrDE8GbeMjFZSY5vmucfA7oQO/p83NkvrCObsemMx9nJlFbLRM+YplYSY
V95xn0nN9xY0RA74WjiuZPYrV7A/Zgf5cQomyqHfgShAt9P5E4y0px7DoJYpGmRT9Lv+RkelkKpy
eynFPO6R8bGmq1Lz3XxYDDfxqlJBRhX9zM94X1BLAwQKAAAAAAASeEJdAAAAAAAAAAAAAAAABAAc
AGJpbi9VVAkAAxTHv2pQx79qdXgLAAEEAAAAAAQAAAAAUEsDBBQAAAAIAJh4Ql2wqVaKBAIAAAED
AAASABwAYmluL2Ruc2JsLWNyb24ucGhwVVQJAAMPyL9qEMi/anV4CwABBAAAAAAEAAAAAG2SwYoT
QRCG7/MUZQjMJGRnDIjIxiDRFQws2WCOKk2lp5I0O9M9W90T3ZUFH8IXEA/i2ZvXeROfxOphAx68
dVdXffX/Vf38RXNokmKcwBguVpuXl3Cc5k/hz5evEJBphx6wDa7uvgWj5dJQhVAZe0AoCbSr0ZbO
Q3a1frW8Wi0uRwLqWeTlHSPtCUjdCaYdM9Xg3V1keLhpIwAE4YmPpnRMPgqJDG+sZmfNHdZAp0xP
0HoEB1vU1263M5pyeO0DgddsmgC++wXdT+h+B1NJdgTdtEbosEdGGwyLLPpEuu1+dN9dtFEbKx4l
/HCoydexU/2PhD45j7SVg+VmLcZxT3wOiz3ZEkU4ZDF1BCKyld5SE4NRsgk06XHsXDiPDIDCNaGQ
2T+bFltj4wkKjSLg4IrSFbGmfyit31ZnkZzHTcG4SErSlYwz84GNDircNuTn09EsScwOsvWbtdos
1kt4NJ9DqiuTjuBzIh3FtAnZYCPzaZy4jiPp5xBEKNj/rDV/bweCvU+YZIRMUBq2WFOm1MXyrVIj
yCEtsGmKrRgTOdhEkekskbbqoUiVGFC5j5Y4ixqHDHPg1qqG2LjSaBXQX/sscEvyHi0Yq5AZb7P0
7JhOYIi8P06gTzh52clHQX2AbMjvUtmXl2X49EP8asP6lNSb1gcnoQkMxMysD9+Lo34Wj6XfX1BL
AwQUAAAACAASeEJdLEiKL4oAAADAAAAADQAcAGJpbi8uaHRhY2Nlc3NVVAkAAxTHv2q1x79qdXgL
AAEEAAAAAAQAAAAAU1Zw8Qt28lF41DBFoSCxuCRRITOvJLUoL9FKIa80LzlRoTi1qCyzSKEgNSdR
oTw1icvGM803P6U0J1UhNz8lPrG0JKMqPjm/KFUv2Y5LAQiCUgtLM4tSFRJzchRSUvMyU1O4bPRh
euyQtCti1+9flJJaBNKdX64D1F8JFnQBMhTSivJzQRIo5gEAUEsDBBQAAAAIAJh4Ql3aXNiingMA
ABkHAAAXABwAYmluL3NpbmNyb25pemFyLXpvbmEuc2hVVAkAAw/Iv2q1x79qdXgLAAEEAAAAAAQA
AAAArVTNbtw2EL7rKcZaN7ILc2U3QQ4b+NB6t4hRNxvYW8BAmxqURO0SlkiFpDau4wA99QGKvkDR
Q5Bz0Euu+yZ5knykVvYWNZBLpItIzc8333wzg620tSbNpEqFWlLG7SIa0OGXfBDPSpUbreQ1N+xa
Kz60C1oeDB/Tx9//ovGzs+9OYHSkjRGktCUrzFIW2ghLJqsKZYshjYXNOQzmnDj5GFRowM0vdVnK
XJAg22bWSddKxNKEy4WQRtNOIajUpoafW72vZc53ya7e08uWK4TQlGvlxOoDvlfvqJClMAIXQ0SZ
9umpEE44n5lXThi+erv6RyOlET0mq6+lWmh4+UpQK+0Yrd3uHlyplqp1Gt7dxwgmRF/fvt6QQhsq
nfMqtb4b91D2xRtjhSPWRog7UQXKXr31RTl9KdQItDSSGw9/LEqpJGr+Fw35+MefNLlqtHFrFoqu
HdFPpyeH8fbr0M0LHEZs4VxjR2kKBrNqKK5E3VR62LhUdP5m2CyaN3E0m/4weXbnG44jdjQ9+fb0
YtodYTWg7/uWVhAHNaLSfX+i8eRsdhfBn0YsXXIwKrN0bbTGAbAC4aLx8Sk8dgppFK8FxdveK96N
o/oSd8Qaf3V8Cng/PveG9aVDAd1lOuxinYcHTnRzQ+JKOjqInOENJaYmVsIYznFCk/PjWRQEFcil
JZek2ppynoF0Xi0gU+XJhGp5GAGISlqHD1TajwO9Etmu1+XGLFhgMmIEbeW6bngvTSi5FBKKDSzd
KnyPQhZcYny443sI5p0ARuXe2EAG1IZZaXkF8XXhulhKUy1s7QHNW8zOMJIlbdHRdDzxBOWtqYjZ
M2Ks5lfMSbD6cJ/YU4rPWWgMm3XS2g49jYnpNUPEXlHy1WsvmItcF+JNgh/QEJh9Qm4hVISBoUrP
54DHHAX2mf1N5RSXoA/YOFQxX8Plm5shDr7r5pQy8qB/RngPO6atQ4q/2d+P6cVnE2EdNdqCh6ez
2XMK/v/dQf/LNKAzLBqeB/bQ7tud5HtVCeenbbn628u5o3JuREPsJSW//rI9m51Q0vMDeW2R4xIE
Kzq4vd1wGCB6PUo+T1ePAbtLZH6QsGh6OLrFaY3oSbdla66cLPh9tYn6bh1iNYzQhMLvyJJfC9PR
HGYgDBa9oAcPKMcEMdvjX//awBwS7IcE+aLWBT1+9GhtHdXLu5HqXbtpY92A3V9wqKKXc8Ghvp1N
IjtwN9B0QYlNwWOaJtgCnwBQSwMEFAAAAAgAmHhCXUyzAR/EAwAAVwcAABMAHABiaW4vY3JpYXIt
YWRtaW4ucGhwVVQJAAMPyL9qEMi/anV4CwABBAAAAAAEAAAAAI1Vy27jNhTd6yvuBAYkDSR7nAAF
mpfrxh6MATcx/OgAk6QELdIxUYnUkJQzmcBAP6J/0GUxq+7a3fhP+iW9lOzEBpxigixkUjzn3HN5
rk5b+Tz3Gq89eA2dy9GPfVg069/Bv7/9DokWVEORQWFFKj5TpjSoAjRnfCak0EAhpyldaBrn1Bju
ICZGQZCoDNT2KaZg8G4QHoMp8DEuYDLu9Xsf2p2rIcENQAkwFbJRMsaUZULW3drpM8Y5ojc8xpOU
ah4Yq0ViiX3IuTlrhieeJ2YQIBQZtQc9eHV2Bn6SCj+ERw/wj38SNjgYrf6CXDEOhmtc4klhERok
hVTIOQXcQelUMmXqN/IAYZee5h8LoTkwoSXNeEBIpzckJIQ6+A2a542pUhbl0Nwp9k88pCXrQ4RR
S4m6l1wHTmOtcMRnUKP6bnHdvIVWC3w84rS/yjW/Ixm1yTzwG79c0/hzO/7wJv6+TuLbx6Po6HBZ
a/gRlBjhpq7ZvRaWB6NxpzscRnCA9h9/k5s3MjjC/h0dQkI1TSzX3BxDyrEQE4Fc/Z1xrfApV9Kq
COarLzMuXfdJWDnz5GqztMmbFTKxQkmg5teyPfIOarlWWW5d38sFb92MZK42exVQzdoH9GWDQRDY
WBP4uTLiExGG4j72sgXbC67q3mUIx2B1wSsg56QDQ3/gBzPnaUpcnwPfOIa4ZD48bzC+aMgiTf3w
BJaVggXya1SZBWv14eyOo4aKBK290c+F/z/NyyzlzgHiVDCa20JL5C4drOVN1ODs8wfbsYIgW32R
IlPQfLPVLXQVgfHU4ebUkOfcYix3Qlm95QRnU4KVpVwGyBTCKcK9dI3auxhgeebCgbyQ81RBxqUy
u3Lqe69FaRTW5QKJSl/kMxtCs2aUqz8UhlHIRDCe7Qf3amyKtbOpC1fNWJcsNo3PMUm5GxL+qNvv
XoxBMHg7vPoJXHIMvH/XHXbLZ5dnPNPyq+PxeTUSeHBdhuzWLc+pmeM7TtS90oy4366iCAbt0ej9
1bBDOt237Ul/vBlCNaRDIQ5vxjHNFyotMhk8RXZX4mTQaY+7a2mj7niXyalbCy5RUeq2SvcKTgTB
btfmpOqOzDE6Sj9geCpHSWkooSm2iTK6GSER4H2pBjmje0egv3G8vLS7VxJf+/rnYwm0/PrP0yeB
0Xp5uZfAU3xrX8G9y1F3OIbe5fhqXXWw6UW0W3yEHyBOLWeE2hB+bvcn3REErQjcf7jrRFXR2hCp
7oNwryXPA5C44cjUlhsX5cI3ODF5/q5te1ABruv3/gNQSwECHgMKAAAAAAASeEJdAAAAAAAAAAAA
AAAABwAYAAAAAAAAABAA7UEAAAAAY29uZmlnL1VUBQADFMe/anV4CwABBAAAAAAEAAAAAFBLAQIe
AxQAAAAIAJh4Ql1P9bnS7QIAAAMFAAAZABgAAAAAAAEAAACkgUEAAABjb25maWcvY29uZmlnLmV4
ZW1wbG8ucGhwVVQFAAMPyL9qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAEnhCXSxIii+KAAAA
wAAAABAAGAAAAAAAAQAAAKSBgQMAAGNvbmZpZy8uaHRhY2Nlc3NVVAUAAxTHv2p1eAsAAQQAAAAA
BAAAAABQSwECHgMUAAAACACYeEJdOBeebiYEAAC2BwAADAAYAAAAAAABAAAApIFVBAAAZXhwb3J0
YXIucGhwVVQFAAMPyL9qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAMnhCXdZiz6VKAwAASQgA
AAkAGAAAAAAAAQAAAKSBwQgAAGluZGV4LnBocFVUBQADUMe/anV4CwABBAAAAAAEAAAAAFBLAQIe
AwoAAAAAABJ4Ql0AAAAAAAAAAAAAAAAHABgAAAAAAAAAEADtQU4MAABhc3NldHMvVVQFAAMUx79q
dXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAmHhCXekMyfJ/FAAAtFIAAA4AGAAAAAAAAQAAAKSB
jwwAAGFzc2V0cy9hcHAuY3NzVVQFAAMPyL9qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAmHhC
XUghFhcqBgAA9xIAAA0AGAAAAAAAAQAAAKSBViEAAGFzc2V0cy9hcHAuanNVVAUAAw/Iv2p1eAsA
AQQAAAAABAAAAABQSwECHgMKAAAAAAASeEJdAAAAAAAAAAAAAAAABAAYAAAAAAAAABAA7UHHJwAA
YXBwL1VUBQADFMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAABJ4Ql0AAAAAAAAAAAAAAAAK
ABgAAAAAAAAAEADtQQUoAABhcHAvdmlld3MvVVQFAAMUx79qdXgLAAEEAAAAAAQAAAAAUEsBAh4D
FAAAAAgAMnhCXcTaEHhfBwAA1BMAABQAGAAAAAAAAQAAAKSBSSgAAGFwcC92aWV3cy9sYXlvdXQu
cGhwVVQFAANQx79qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAMnhCXdoY5RAsBwAAtg8AABEA
GAAAAAAAAQAAAKSB9i8AAGFwcC9ib290c3RyYXAucGhwVVQFAANQx79qdXgLAAEEAAAAAAQAAAAA
UEsBAh4DFAAAAAgAEnhCXSxIii+KAAAAwAAAAA0AGAAAAAAAAQAAAKSBbTcAAGFwcC8uaHRhY2Nl
c3NVVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwECHgMKAAAAAAAteEJdAAAAAAAAAAAAAAAACAAY
AAAAAAAAABAA7UE+OAAAYXBwL2xpYi9VVAUAA0XHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAA
CAASeEJd4LQYE5ULAADSHQAAEAAYAAAAAAABAAAApIGAOAAAYXBwL2xpYi96b25lLnBocFVUBQAD
FMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIABJ4Ql0mD3WaIwgAAK8XAAAOABgAAAAAAAEA
AACkgV9EAABhcHAvbGliL2lwLnBocFVUBQADFMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAI
ADJ4Ql3e6veGLQUAAO0NAAARABgAAAAAAAEAAACkgcpMAABhcHAvbGliL2ljb25zLnBocFVUBQAD
UMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIAJh4Ql12cTACsQQAACQKAAARABgAAAAAAAEA
AACkgUJSAABhcHAvbGliL3Rhc2tzLnBocFVUBQADD8i/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQA
AAAIABJ4Ql2ushud/gcAADIZAAAOABgAAAAAAAEAAACkgT5XAABhcHAvbGliL2RiLnBocFVUBQAD
FMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIAJh4Ql2Ozs1LbQ8AAMQuAAATABgAAAAAAAEA
AACkgYRfAABhcHAvbGliL3VwZGF0ZXIucGhwVVQFAAMPyL9qdXgLAAEEAAAAAAQAAAAAUEsBAh4D
FAAAAAgAMnhCXQGHyg8mDgAAMScAABMAGAAAAAAAAQAAAKSBPm8AAGFwcC9saWIvaGVscGVycy5w
aHBVVAUAA1DHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACACYeEJd16JdVjAMAADDIgAAFAAY
AAAAAAABAAAApIGxfQAAYXBwL2xpYi9kbnNjaGVjay5waHBVVAUAAw/Iv2p1eAsAAQQAAAAABAAA
AABQSwECHgMUAAAACAASeEJd0AzdoQ0FAABXDQAAEQAYAAAAAAABAAAApIEvigAAYXBwL2xpYi9j
aGFydC5waHBVVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAAteEJdxIuPb3UEAACk
CQAADwAYAAAAAAABAAAApIGHjwAAYXBwL2xpYi9zc2wucGhwVVQFAANFx79qdXgLAAEEAAAAAAQA
AAAAUEsBAh4DCgAAAAAALXhCXQAAAAAAAAAAAAAAAAoAGAAAAAAAAAAQAO1BRZQAAGFwcC9wYWdl
cy9VVAUAA0XHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAASeEJdDnjwlP0LAACZKwAAGgAY
AAAAAAABAAAApIGJlAAAYXBwL3BhZ2VzL2F0dWFsaXphY29lcy5waHBVVAUAAxTHv2p1eAsAAQQA
AAAABAAAAABQSwECHgMUAAAACAASeEJd3IWSqEcJAAA5HAAAFQAYAAAAAAABAAAApIHaoAAAYXBw
L3BhZ2VzL2VudHJhZGEucGhwVVQFAAMUx79qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAEnhC
XRF6v+rDAwAAVAkAABMAGAAAAAAAAQAAAKSBcKoAAGFwcC9wYWdlcy9jb250YS5waHBVVAUAAxTH
v2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAASeEJdF9BxZpkEAAAQCwAAFwAYAAAAAAABAAAA
pIGArgAAYXBwL3BhZ2VzL2hpc3Rvcmljby5waHBVVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwEC
HgMUAAAACAASeEJdpAMI2JIJAAD+FgAAFgAYAAAAAAABAAAApIFqswAAYXBwL3BhZ2VzL2luc3Rh
bGFyLnBocFVUBQADFMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIABJ4Ql0aL6GUjAkAAIEe
AAAUABgAAAAAAAEAAACkgUy9AABhcHAvcGFnZXMvcGFpbmVsLnBocFVUBQADFMe/anV4CwABBAAA
AAAEAAAAAFBLAQIeAxQAAAAIABJ4Ql1CpuALCwgAAGIWAAAUABgAAAAAAAEAAACkgSbHAABhcHAv
cGFnZXMvdGVzdGFyLnBocFVUBQADFMe/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIABJ4Ql17
YiMufBIAAHA/AAAWABgAAAAAAAEAAACkgX/PAABhcHAvcGFnZXMvZW50cmFkYXMucGhwVVQFAAMU
x79qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAEnhCXbekWmutEgAAYUYAABgAGAAAAAAAAQAA
AKSBS+IAAGFwcC9wYWdlcy9kZWZpbmljb2VzLnBocFVUBQADFMe/anV4CwABBAAAAAAEAAAAAFBL
AQIeAxQAAAAIABJ4Ql2LAt8BIQcAAB8RAAATABgAAAAAAAEAAACkgUr1AABhcHAvcGFnZXMvbG9n
aW4ucGhwVVQFAAMUx79qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAEnhCXewckGDHBwAAhBcA
ABgAGAAAAAAAAQAAAKSBuPwAAGFwcC9wYWdlcy9wcm90ZWdpZG9zLnBocFVUBQADFMe/anV4CwAB
BAAAAAAEAAAAAFBLAQIeAxQAAAAIADZ4Ql0H3qnQ0w4AANc3AAARABgAAAAAAAEAAACkgdEEAQBh
cHAvcGFnZXMvc3NsLnBocFVUBQADV8e/anV4CwABBAAAAAAEAAAAAFBLAQIeAwoAAAAAABJ4Ql0A
AAAAAAAAAAAAAAAFABgAAAAAAAAAEADtQe8TAQBkYXRhL1VUBQADFMe/anV4CwABBAAAAAAEAAAA
AFBLAQIeAxQAAAAIABJ4Ql25K3MLWwAAAFwAAAAVABgAAAAAAAEAAACkgS4UAQBkYXRhL2FjZXNz
by10ZXN0ZS50eHRVVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAASeEJdLEiKL4oA
AADAAAAADgAYAAAAAAABAAAApIHYFAEAZGF0YS8uaHRhY2Nlc3NVVAUAAxTHv2p1eAsAAQQAAAAA
BAAAAABQSwECHgMUAAAACACYeEJdUyLVjx4BAACrAQAACQAYAAAAAAABAAAApIGqFQEALmh0YWNj
ZXNzVVQFAAMPyL9qdXgLAAEEAAAAAAQAAAAAUEsBAh4DFAAAAAgAmHhCXbK1gogJCwAAiBkAAA0A
GAAAAAAAAQAAAKSBCxcBAEFMVEVSQUNPRVMubWRVVAUAAw/Iv2p1eAsAAQQAAAAABAAAAABQSwEC
HgMUAAAACACYeEJdyyY/254RAACuKQAACwAYAAAAAAABAAAApIFbIgEASU5TVEFMQVIubWRVVAUA
Aw/Iv2p1eAsAAQQAAAAABAAAAABQSwECHgMKAAAAAAASeEJdAAAAAAAAAAAAAAAACAAYAAAAAAAA
ABAA7UE+NAEAcmJsZG5zZC9VVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACACYeEJd
l854djQCAABcBAAAGgAYAAAAAAABAAAApIGANAEAcmJsZG5zZC9uZ2lueC1leGVtcGxvLmNvbmZV
VAUAAw/Iv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAASeEJdLEiKL4oAAADAAAAAEQAYAAAA
AAABAAAApIEINwEAcmJsZG5zZC8uaHRhY2Nlc3NVVAUAAxTHv2p1eAsAAQQAAAAABAAAAABQSwEC
HgMUAAAACACYeEJdhou7MGgBAABBAgAAHQAYAAAAAAABAAAApIHdNwEAcmJsZG5zZC9yYmxkbnNk
LWRuc2JsLnNlcnZpY2VVVAUAAw/Iv2p1eAsAAQQAAAAABAAAAABQSwECHgMKAAAAAAASeEJdAAAA
AAAAAAAAAAAABAAYAAAAAAAAABAA7UGcOQEAYmluL1VUBQADFMe/anV4CwABBAAAAAAEAAAAAFBL
AQIeAxQAAAAIAJh4Ql2wqVaKBAIAAAEDAAASABgAAAAAAAEAAADtgdo5AQBiaW4vZG5zYmwtY3Jv
bi5waHBVVAUAAw/Iv2p1eAsAAQQAAAAABAAAAABQSwECHgMUAAAACAASeEJdLEiKL4oAAADAAAAA
DQAYAAAAAAABAAAApIEqPAEAYmluLy5odGFjY2Vzc1VUBQADFMe/anV4CwABBAAAAAAEAAAAAFBL
AQIeAxQAAAAIAJh4Ql3aXNiingMAABkHAAAXABgAAAAAAAEAAADtgfs8AQBiaW4vc2luY3Jvbml6
YXItem9uYS5zaFVUBQADD8i/anV4CwABBAAAAAAEAAAAAFBLAQIeAxQAAAAIAJh4Ql1MswEfxAMA
AFcHAAATABgAAAAAAAEAAADtgepAAQBiaW4vY3JpYXItYWRtaW4ucGhwVVQFAAMPyL9qdXgLAAEE
AAAAAAQAAAAAUEsFBgAAAAA0ADQAgBEAAPtEAQAAAA==
