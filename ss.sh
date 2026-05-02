#!/usr/bin/env bash
set -euo pipefail

# Hata oldugunda hangi satirda ne komutu basarisiz oldugunu goster
trap 'echo -e "\n\033[0;31m[HATA]\033[0m Satir ${LINENO} basarisiz: ${BASH_COMMAND}\nCikis kodu: $?" >&2' ERR

# =============================================================================
# Outline Shadowsocks-over-WebSocket  —  VPS Installer
#
# Mimari:
#   Istemci → CDN anycast IP:443 (TLS+WSS)
#           → Bu VPS  outline-ss-server:80  (WebSocket, TLS yok — CDN halleder)
#
# VLess ile ayni katman sayisi: CDN → sunucu (tek hop, ekstra proxy yok)
#
# CDN olarak kullanilabilir:
#   Cloudflare         (anycast: 104.x.x.x) — ONERILEN, idle timeout yok
#   Google Cloud Run   (anycast: *.run.app)
#   AWS CloudFront     (anycast: *.cloudfront.net) — HTTP/1.1 + AllViewer gerekli
#
# Cikti dosyasi:
#   <cdn-host>.access.yaml  ← Outline istemcisine yukle
#
# Kullanim:
#   ./ss.sh              → kur / guncelle
#   ./ss.sh optimize     → sysctl + GOMAXPROCS aninda uygula (yeniden kurmadan)
#   ./ss.sh uninstall    → kaldir
# =============================================================================

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGIN_PORT="80"        # CDN'nin dogrudan baglandigi port (outline-ss-server dinler)

[[ "$(id -u)" -ne 0 ]] && { echo "root olarak calistirin: sudo bash ss.sh" >&2; exit 1; }

# ── Renkli cikti ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[HATA]${NC} $*" >&2; exit 1; }

# ── QUIC bloklama (UDP 443) — Video CDN'leri TCP'ye zorla, WhatsApp/Telegram muaf ──
block_quic() {
  info "QUIC bloklaniyor: WhatsApp/Telegram/Signal muaf, diger CDN'ler TCP'ye duser..."

  # Eski tekil kuralları tamamen temizle
  iptables  -D OUTPUT -p udp --dport 443 -j DROP   2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j DROP   2>/dev/null || true
  iptables  -D OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
  iptables  -D OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || true

  # QUIC_BLOCK ozel zinciri olustur (varsa sifirla)
  iptables  -N QUIC_BLOCK 2>/dev/null || iptables  -F QUIC_BLOCK
  ip6tables -N QUIC_BLOCK 2>/dev/null || ip6tables -F QUIC_BLOCK

  # ── Strateji: IP yerine paket boyutu + baglanti suresi ile ayirt et ──
  # QUIC video streaming: buyuk paketler (MTU yakin), cok sayida, yuksek bant genisligi
  # WhatsApp/Telegram ses aramas: kucuk paketler (RTP ~200 byte), periyodik
  #
  # Cozum: 256 byte'dan buyuk UDP 443 paketlerini REJECT et.
  # Kucuk paketler (ses/STUN/TURN) gecmesine izin ver.
  # YouTube/TikTok QUIC paketleri 1200-1400 byte oldugundan REJECT olacak.

  # 256 byte'dan KUCUK UDP 443 → IZIN VER (ses aramasi, STUN, TURN)
  iptables  -A QUIC_BLOCK -m length --length 0:256   -j ACCEPT
  ip6tables -A QUIC_BLOCK -m length --length 0:256   -j ACCEPT

  # 256 byte'dan BUYUK UDP 443 → REJECT (YouTube/TikTok QUIC video)
  iptables  -A QUIC_BLOCK -m length --length 257:65535 -j REJECT --reject-with icmp-port-unreachable
  ip6tables -A QUIC_BLOCK -m length --length 257:65535 -j REJECT --reject-with icmp6-port-unreachable

  # OUTPUT zincirine bagla
  iptables  -C OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || \
    iptables  -A OUTPUT -p udp --dport 443 -j QUIC_BLOCK
  ip6tables -C OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || \
    ip6tables -A OUTPUT -p udp --dport 443 -j QUIC_BLOCK

  # Kural kaliciligi (reboot sonrasi)
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save > /dev/null 2>&1 \
      && success "iptables kurallari kalici olarak kaydedildi" || true
  else
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    success "iptables kurallari /etc/iptables/rules.v4 dosyasina kaydedildi"
  fi

  success "QUIC bloklama tamam — WhatsApp/Telegram aramalari calisir, YouTube/TikTok donmaz"
}

# ── Uninstall ──────────────────────────────────────────────────────────────────
uninstall_system() {
  info "Kaldiriliyor..."
  systemctl stop outline-ss-server 2>/dev/null || true
  systemctl disable outline-ss-server 2>/dev/null || true
  rm -f /etc/systemd/system/outline-ss-server.service
  systemctl daemon-reload || true
  rm -f /usr/local/bin/outline-ss-server
  # Eski kurulumdan kalma ws-keepalive artiklari temizle
  systemctl stop ws-keepalive 2>/dev/null || true
  systemctl disable ws-keepalive 2>/dev/null || true
  rm -f /etc/systemd/system/ws-keepalive.service
  rm -f /usr/local/bin/ws-keepalive
  rm -rf /opt/outline/ws-keepalive
  rm -rf /etc/outline /var/lib/outline
  rm -f "${WORKDIR}"/*.access.yaml
  # QUIC bloklama kurallarini kaldir
  iptables  -D OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j QUIC_BLOCK 2>/dev/null || true
  iptables  -F QUIC_BLOCK 2>/dev/null || true
  ip6tables -F QUIC_BLOCK 2>/dev/null || true
  iptables  -X QUIC_BLOCK 2>/dev/null || true
  ip6tables -X QUIC_BLOCK 2>/dev/null || true
  iptables  -D OUTPUT -p udp --dport 443 -j DROP   2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j DROP   2>/dev/null || true
  iptables  -D OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
  ip6tables -D OUTPUT -p udp --dport 443 -j REJECT 2>/dev/null || true
  [[ -f /etc/iptables/rules.v4 ]] && netfilter-persistent save > /dev/null 2>&1 || true
  success "Kaldirma tamamlandi"
}

[[ "${1:-}" == "uninstall" ]] && { uninstall_system; exit 0; }

# ── Aninda optimizasyon (kurulu sisteme uygula) ────────────────────────────────
optimize_live() {
  info "Mevcut sisteme optimizasyonlar uygulanıyor..."

  # BBR kernel modulu (sysctl'den once yuklenmeli)
  modprobe tcp_bbr 2>/dev/null && success "tcp_bbr modulu yuklendi" || true

  # Sysctl ayarlarini aninda uygula
  local settings=(
    "net.core.somaxconn=65535"
    "net.core.netdev_max_backlog=65535"
    "net.ipv4.tcp_max_syn_backlog=65535"
    "net.ipv4.tcp_fin_timeout=15"
    "net.ipv4.tcp_keepalive_time=300"
    "net.ipv4.tcp_keepalive_intvl=30"
    "net.ipv4.tcp_keepalive_probes=5"
    "net.ipv4.tcp_tw_reuse=1"
    "net.ipv4.ip_local_port_range=1024 65535"
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.core.rmem_default=262144"
    "net.core.wmem_default=262144"
    "net.ipv4.tcp_rmem=4096 262144 16777216"
    "net.ipv4.tcp_wmem=4096 262144 16777216"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.tcp_mtu_probing=1"
    "net.ipv4.tcp_notsent_lowat=16384"
  )
  local failed=0
  for s in "${settings[@]}"; do
    sysctl -w "$s" > /dev/null 2>&1 || { warn "Uygulanamadi: $s"; ((failed++)) || true; }
  done
  [[ $failed -eq 0 ]] && success "Tum sysctl ayarlari aninda uygulandi" \
                       || warn "$failed ayar uygulanamadi (reboot sonrasi etkin olacak)"

  # GOMAXPROCS guncelle ve servisi yeniden baslat
  if [[ -f /etc/systemd/system/outline-ss-server.service ]]; then
    local NCPUS; NCPUS="$(nproc)"
    if ! grep -q "GOMAXPROCS" /etc/systemd/system/outline-ss-server.service; then
      sed -i "/^ExecStart=/i Environment=GOMAXPROCS=${NCPUS}" \
        /etc/systemd/system/outline-ss-server.service
    else
      sed -i "s/^Environment=GOMAXPROCS=.*/Environment=GOMAXPROCS=${NCPUS}/" \
        /etc/systemd/system/outline-ss-server.service
    fi
    systemctl daemon-reload
    systemctl restart outline-ss-server
    sleep 1
    systemctl is-active --quiet outline-ss-server \
      && success "outline-ss-server yeniden baslatildi (GOMAXPROCS=${NCPUS})" \
      || warn "outline-ss-server yeniden baslatılamadi — journalctl -u outline-ss-server"
  else
    warn "outline-ss-server servisi bulunamadi — once ./ss.sh ile kurulum yapin"
  fi

  # CPU performans modu
  local cpu_set=0
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov" ]] && { echo performance > "$gov" 2>/dev/null && cpu_set=1 || true; }
  done
  [[ $cpu_set -eq 1 ]] && success "CPU governor: performance modu etkin" \
                        || info "CPU governor ayarlanamadi"

  # NIC ring buffer
  local NIC; NIC="$(ip route get 1 2>/dev/null | awk '/dev/{print $5; exit}' || true)"
  if [[ -n "$NIC" ]] && command -v ethtool &>/dev/null; then
    ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null \
      && success "NIC ring buffer arttirildi (${NIC})" \
      || info "NIC ring buffer ayarlanamadi"
  fi

  # QUIC (UDP 443) bloklama - REJECT modu ile (WhatsApp'i bozmaz)
  block_quic

  success "Optimizasyon tamamlandi"
  echo ""
  echo -e "${YELLOW}Anlik dogrulama:${NC}"
  echo "  sysctl net.ipv4.tcp_slow_start_after_idle   # 0 olmali"
  echo "  sysctl net.ipv4.tcp_congestion_control       # bbr olmali"
  echo "  sysctl net.ipv4.tcp_fastopen                 # 3 olmali"
  echo "  sysctl net.ipv4.tcp_notsent_lowat            # 16384 olmali"
  echo "  systemctl show outline-ss-server | grep GOMAXPROCS"
  echo "  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null"
}

[[ "${1:-}" == "optimize" ]] && { optimize_live; exit 0; }

# ── Sunucu IP'sini otomatik tespit et ─────────────────────────────────────────
detect_server_ip() {
  SERVER_IP="$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1);exit}}}' \
    || hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$SERVER_IP" ]] || die "Sunucu IP'si tespit edilemedi"
  success "Sunucu IP: ${SERVER_IP}"
}

# ── Kullanicidan bilgi al ──────────────────────────────────────────────────────
prompt_inputs() {
  clear
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        Outline WebSocket VPN  —  VPS Installer          ║"
  echo "║        CDN: Cloud Run / CloudFront / Cloudflare         ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Sunucu IP : ${GREEN}${SERVER_IP}${NC}  (CDN origin: ${SERVER_IP}:${ORIGIN_PORT})"
  echo ""

  echo -e "${YELLOW}[1] Anycast IP${NC} — CDN'nin public anycast IP adresi"
  echo "    Ornek (Google Cloud Run) : 172.253.152.86"
  echo "    Ornek (AWS CloudFront)   : 13.224.19.229"
  echo "    Ornek (Cloudflare)       : 104.21.80.246"
  read -r -p "    Anycast IP: " ANYCAST_IP

  echo ""
  echo -e "${YELLOW}[2] CDN Host (WS Host)${NC} — HTTP Host header ve YAML url icin kullanilir"
  echo "    Ornek (Cloud Run)  : myservice-abc123-ew.a.run.app"
  echo "    Ornek (CloudFront) : d1234abcd.cloudfront.net"
  echo "    Ornek (Cloudflare) : myservice.workers.dev"
  read -r -p "    CDN Host: " CDN_HOST

  [[ -n "$ANYCAST_IP" ]] || die "Anycast IP bos olamaz"
  [[ -n "$CDN_HOST"   ]] || die "CDN Host bos olamaz"
}

# ── Bagimlilik kurulumu ────────────────────────────────────────────────────────
install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  info "Sistem paketleri kuruluyor..."

  # apt kilidi bekleniyor (cloud-init vb. arka plan surecleri)
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null; do
    if [[ $waited -eq 0 ]]; then
      warn "apt kilidi bekleniyor (en fazla 60 saniye)..."
    fi
    sleep 2; ((waited+=2))
    [[ $waited -ge 60 ]] && die "apt kilidi 60 saniye icerisinde acilmadi"
  done

  apt-get update -qq || { warn "apt-get update basarisiz, devam ediliyor..."; true; }
  apt-get install -y -qq ca-certificates curl git openssl ethtool iptables iptables-persistent

  # Go dil derleyicisi
  local REQUIRED_GO="1.24.1"
  local detected go_ok=0
  detected="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true)"
  if [[ -n "$detected" ]] && \
     [[ "$(printf '%s\n' "$REQUIRED_GO" "$detected" | sort -V | head -1)" == "$REQUIRED_GO" ]]; then
    go_ok=1
  fi

  if [[ "$go_ok" -eq 0 ]]; then
    info "Go $REQUIRED_GO kuruluyor..."
    local TGZ="/tmp/go${REQUIRED_GO}.linux-amd64.tar.gz"
    curl -fsSL "https://go.dev/dl/go${REQUIRED_GO}.linux-amd64.tar.gz" -o "$TGZ"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$TGZ"
    rm -f "$TGZ"
    ln -sf /usr/local/go/bin/go   /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  fi
  success "Bagimliliklar hazir"
}

# ── outline-ss-server derle ────────────────────────────────────────────────────
build_binary() {
  if [[ -f /usr/local/bin/outline-ss-server ]]; then
    success "outline-ss-server zaten kurulu, derleme atlaniyor"
    return
  fi
  info "outline-ss-server derleniyor... (3-5 dakika surebilir)"
  install -d -m 0755 /opt/outline
  if [[ ! -d /opt/outline/tunnel-server/.git ]]; then
    git clone --depth=1 https://github.com/OutlineFoundation/tunnel-server.git \
      /opt/outline/tunnel-server
  fi
  cd /opt/outline/tunnel-server
  go mod download
  CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
    -o /usr/local/bin/outline-ss-server ./cmd/outline-ss-server
  install -d -m 0755 /etc/outline /var/lib/outline
  success "outline-ss-server derlendi"
}

# ── Rastgele degerler uret ─────────────────────────────────────────────────────
generate_values() {
  SS_SECRET="$(openssl rand -base64 32)"
  SS_CIPHER="aes-256-gcm"
}

# ── outline-ss-server config ───────────────────────────────────────────────────
write_server_config() {
  cat > /etc/outline/config.yaml << EOF
web:
  servers:
    - id: server1
      listen:
        - "0.0.0.0:${ORIGIN_PORT}"

services:
  - listeners:
      - type: websocket-stream
        web_server: server1
        path: "/"
      - type: websocket-packet
        web_server: server1
        path: "/u"
    keys:
      - id: 1
        cipher: ${SS_CIPHER}
        secret: ${SS_SECRET}
EOF
  success "outline-ss-server config yazildi (sifrele: ${SS_CIPHER})"
}

# ── Sistem ve ag performans optimizasyonu (200+ kullanici icin) ─────────────
optimize_system() {
  info "Sistem limitleri ve TCP ayarlari optimize ediliyor..."

  # File descriptor limitleri
  local LIMITS_CONF="/etc/security/limits.conf"
  grep -q "outline-nofile" "$LIMITS_CONF" 2>/dev/null || cat >> "$LIMITS_CONF" << 'EOF'
# outline-ws-installer: file descriptor limitleri
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

  # systemd global fd limiti
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/outline-nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF

  # BBR kernel modulu (sysctl'den once yuklenmeli)
  modprobe tcp_bbr 2>/dev/null && success "tcp_bbr modulu yuklendi" || true

  # Kernel TCP ayarlari
  local SYSCTL_CONF="/etc/sysctl.d/99-outline-ws.conf"
  cat > "$SYSCTL_CONF" << 'EOF'
# outline-ws: yuksek esli baglanti optimizasyonu
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
# Soket tampon boyutlari — WebSocket throughput artirici
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
# Video akisi icin kritik: idle sonrasi TCP slow-start'i engelle
# (video buffer aralıklarında hız sıfırlanmasını önler)
net.ipv4.tcp_slow_start_after_idle = 0
# TCP Fast Open: el sikisme gecikmesini azaltir
net.ipv4.tcp_fastopen = 3
# MTU probe: paket boyutu uyumsuzluğundan kaynaklanan kasmayi giderir
net.ipv4.tcp_mtu_probing = 1
# Gercek zamanli streaming: kernel send buffer'i sinirla, gecikmeyi azaltir
net.ipv4.tcp_notsent_lowat = 16384
EOF
  sysctl -p "$SYSCTL_CONF" > /dev/null 2>&1 || warn "sysctl uygulanamadi, reboot sonrasi etkin olacak"

  # CPU performans modu (bazi VPS'lerde hypervisor kisitlayabilir)
  local cpu_set=0
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$gov" ]] && { echo performance > "$gov" 2>/dev/null && cpu_set=1 || true; }
  done
  [[ $cpu_set -eq 1 ]] && success "CPU governor: performance modu etkin" \
                        || info "CPU governor ayarlanamadi (VPS sanallaştirmasi kisitliyor olabilir)"

  # NIC ring buffer buyut (yuksek trafikte paket kaybi onler)
  local NIC; NIC="$(ip route get 1 2>/dev/null | awk '/dev/{print $5; exit}' || true)"
  if [[ -n "$NIC" ]] && command -v ethtool &>/dev/null; then
    ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null \
      && success "NIC ring buffer arttirildi (${NIC}: rx/tx=4096)" \
      || info "NIC ring buffer ayarlanamadi (sanal NIC desteklemiyor olabilir)"
  fi

  # QUIC bloklama (REJECT modu)
  block_quic

  success "Sistem optimizasyonu tamamlandi"
}

# ── Port 80 musaitlik kontrolu ──────────────────────────────────────────────
check_port() {
  # Yeniden kurulumda eski servis portu tutuyor olabilir, once durdur
  systemctl stop outline-ss-server 2>/dev/null || true
  sleep 1
  if ss -tlnp 2>/dev/null | grep -q ':80 ' || netstat -tlnp 2>/dev/null | grep -q ':80 '; then
    die "Port 80 baska bir surec tarafindan kullaniliyor. 'ss -tlnp | grep :80' ile kontrol edin"
  fi
}

# ── outline-ss-server systemd servisi ─────────────────────────────────────────
write_service() {
  local NCPUS; NCPUS="$(nproc)"
  cat > /etc/systemd/system/outline-ss-server.service << EOF
[Unit]
Description=Outline Shadowsocks-over-WebSocket
After=network.target

[Service]
Type=simple
User=root
Environment=GOMAXPROCS=${NCPUS}
ExecStart=/usr/local/bin/outline-ss-server -config=/etc/outline/config.yaml
Restart=always
RestartSec=2
WorkingDirectory=/var/lib/outline
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/outline

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now outline-ss-server
  systemctl restart outline-ss-server
  sleep 1
  systemctl is-active --quiet outline-ss-server \
    && success "outline-ss-server calisiyor" \
    || warn "outline-ss-server baslatilamadi — journalctl -u outline-ss-server"
}

# ── access.yaml uret ve ekrana yazdir ─────────────────────────────────────────
write_and_show_yaml() {

  local outfile="${WORKDIR}/${CDN_HOST}.access.yaml"

  cat > "$outfile" << EOF
transport:
  \$type: tcpudp
  tcp:
    \$type: shadowsocks
    cipher: ${SS_CIPHER}
    secret: ${SS_SECRET}
    endpoint:
      \$type: websocket
      url: wss://${CDN_HOST}/
      endpoint: ${ANYCAST_IP}:443
  udp:
    \$type: shadowsocks
    cipher: ${SS_CIPHER}
    secret: ${SS_SECRET}
    endpoint:
      \$type: websocket
      url: wss://${CDN_HOST}/u
      endpoint: ${ANYCAST_IP}:443
EOF

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                  KURULUM TAMAMLANDI                     ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${GREEN}▼▼▼  ACCESS.YAML ICERIGI  ▼▼▼"
  echo -e "${YELLOW}(Outline istemcisinde 'Anahtari Iceri Aktar' ile yukleyin)${NC}"
  echo ""
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  cat "$outfile"
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo ""
  echo "  Dosya konumu : ${outfile}"
  echo ""
  echo -e "${YELLOW}CDN Origin Ayarlari (CDN panelinden bu VPS'i ekleyin):${NC}"
  printf "  %-28s %s\n" "Origin Domain/IP:"   "${SERVER_IP}"
  printf "  %-28s %s\n" "Origin Protokol:"    "HTTP"
  printf "  %-28s %s\n" "Origin Port:"        "${ORIGIN_PORT}"
  printf "  %-28s %s\n" "Origin (tam adres):" "${SERVER_IP}:${ORIGIN_PORT}"
  printf "  %-28s %s\n" "WebSocket:"          "Acik / Enable"
  echo ""
  echo -e "${RED}!! CLOUDFRONT ZORUNLU AYARLARI (atlama — WebSocket/video calismaz) !!${NC}"
  echo ""
  echo -e "${YELLOW}  [1] Distribution → Settings → Edit:${NC}"
  printf "  %-36s %s\n" "Supported HTTP versions:" "HTTP/1.1 ONLY  ← HTTP/2 ve HTTP/3 kaldir!"
  printf "  %-36s %s\n" "Price class:" "Use all edge locations  ← kullaniciya en yakin PoP icin"
  echo ""
  echo -e "${YELLOW}  [2] Origins → Orijini sec → Edit:${NC}"
  printf "  %-36s %s\n" "Connection attempts:"        "1"
  printf "  %-36s %s\n" "Connection timeout:"         "4"
  printf "  %-36s %s\n" "Response timeout:"           "60  ← varsayilan 30, VIDEO ICIN KRITIK"
  printf "  %-36s %s\n" "Keep-alive timeout:"         "60  ← varsayilan 5,  VIDEO ICIN KRITIK"
  echo ""
  echo -e "${YELLOW}  [3] Behaviors → Default (*) → Edit:${NC}"
  printf "  %-36s %s\n" "Cache policy:"               "CachingDisabled"
  printf "  %-36s %s\n" "Origin request policy:"      "AllViewer"
  printf "  %-36s %s\n" "Allowed HTTP methods:"       "GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE"
  printf "  %-36s %s\n" "Compress objects:"           "No  ← video zaten sikistirilmis"
  echo ""
  echo -e "${RED}  Neden video kasiyordu?${NC}"
  echo -e "${YELLOW}  Response timeout=30s  : 30sn veri akmasa CloudFront baglanti keser → yeniden bağlaniyor = kasma${NC}"
  echo -e "${YELLOW}  Keep-alive timeout=5s : Origin baglantisi 5sn'de kapanir → her videoda yeniden el sikisme = gecikme${NC}"
  echo -e "${YELLOW}  Her ikisini 60s yapinca: baglanti kopmas azalir, video akisi duzgunlesir${NC}"
  echo ""
  echo -e "${YELLOW}Cloudflare Kullanicilari:${NC}"
  echo -e "  → DNS kaydinda 'Proxied' (turuncu bulut) secili olmali"
  echo -e "  → workers.dev kullaniyorsaniz WebSocket icin su Worker scripti gerekir:"
  echo "      export default {"
  echo "        async fetch(req) { return fetch(req); }"
  echo "      }"
  echo "      (Workers → Edit Code → yukle, Settings → Triggers → Route ekle)"
  echo ""
  echo -e "${YELLOW}Uygulama uyumlulugu:${NC}"
  printf "  %-32s %s\n" "WhatsApp/Telegram mesaj:"   "✓ Sorunsuz (TCP)"
  printf "  %-32s %s\n" "WhatsApp/Telegram dosya:"   "✓ Sorunsuz (TCP)"
  printf "  %-32s %s\n" "Sesli/Goruntulu arama:"     "~ Calisir, UDP→TCP nedeniyle hafif gecikme olabilir"
  printf "  %-32s %s\n" "Web tarama, YouTube:"       "✓ Sorunsuz (TCP)"
  echo ""
  echo -e "${YELLOW}Baglanti Ozeti:${NC}"
  printf "  %-28s %s\n" "Anycast IP:"   "${ANYCAST_IP}:443"
  printf "  %-28s %s\n" "CDN Host:"     "${CDN_HOST}"
  printf "  %-28s %s\n" "TCP WS Path:"  "/"
  printf "  %-28s %s\n" "UDP WS Path:"  "/u"
  echo ""
  echo -e "${YELLOW}WebSocket zincir testi (CDN deploy sonrasi calistir):${NC}"
  echo "  curl -v --http1.1 \"https://${CDN_HOST}/\" \\"
  echo "    -H \"Connection: Upgrade\" \\"
  echo "    -H \"Upgrade: websocket\" \\"
  echo "    -H \"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\" \\"
  echo "    -H \"Sec-WebSocket-Version: 13\""
  echo "  # Beklenen: HTTP/1.1 101 Switching Protocols"
  echo ""
  echo ""
  echo -e "${YELLOW}Durum kontrol:${NC}"
  echo "  systemctl status outline-ss-server"
  echo "  journalctl -u outline-ss-server -f"

  # Yerel WebSocket testi
  info "Yerel WebSocket testi yapiliyor (outline-ss-server:${ORIGIN_PORT})..."
  local ws_result
  ws_result="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:${ORIGIN_PORT}/ \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" 2>/dev/null || true)"
  if [[ "$ws_result" == "101" ]]; then
    success "Yerel WebSocket testi BASARILI (101 Switching Protocols)"
  else
    warn "Yerel WebSocket testi beklenmedik yanit: HTTP ${ws_result}"
    warn "journalctl -u outline-ss-server -n 20 ile log kontrol edin"
  fi
}

# ── Ana akis ───────────────────────────────────────────────────────────────────
detect_server_ip
prompt_inputs
install_deps
build_binary
optimize_system
generate_values
write_server_config
check_port
write_service
write_and_show_yaml
