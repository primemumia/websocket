#!/bin/bash

# =============================================================================
# Outline VPN Telegram Bot - Otomatik Kurulum Sistemi
# Domain, SSL, Bot Kurulumu ve Yönetimi
# =============================================================================

set -e

# Renkli çıktı
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global değişkenler
INSTALL_DIR="/opt/outline-telegram-bot"
SERVICE_NAME="outline-telegram-bot"
LOG_FILE="/var/log/outline-bot-install.log"
CONFIG_FILE="/etc/outline-bot/config.json"
NGINX_CONFIG="/etc/nginx/sites-available/outline-bot"
NGINX_ENABLED="/etc/nginx/sites-enabled/outline-bot"

# Banner
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              OUTLINE VPN TELEGRAM BOT                       ║"
    echo "║           Otomatik Kurulum ve SSL Sistemi                   ║"
    echo "║                     v1.0 - 2025                             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# Log fonksiyonu
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
    log "SUCCESS: $1"
}

error() {
    echo -e "${RED}❌ HATA: $1${NC}"
    log "ERROR: $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}⚠️  UYARI: $1${NC}"
    log "WARNING: $1"
}

info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
    log "INFO: $1"
}

# Root kontrolü
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Bu script root yetkileri ile çalıştırılmalıdır!"
    fi
    success "Root yetkileri doğrulandı"
}

# Sistem gereksinimleri
check_requirements() {
    info "Sistem gereksinimleri kontrol ediliyor..."
    
    # Python3 ve pip
    if ! command -v python3 &> /dev/null; then
        warning "Python3 kuruluyor..."
        apt update && apt install -y python3 python3-pip python3-venv python3-dev build-essential || error "Python3 kurulumu başarısız"
    fi
    
    # Python3-venv / ensurepip kontrolü (Ubuntu sürümüne göre otomatik düzeltme)
    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    if ! python3 -m venv --help &> /dev/null || ! python3 -c "import ensurepip" &> /dev/null; then
        warning "Python${python_version} için venv/ensurepip eksik, otomatik kuruluyor..."
        apt update
        apt install -y python3-venv python${python_version}-venv python3-distutils || \
        apt install -y python${python_version}-venv python3-venv || \
        error "Python${python_version}-venv kurulumu başarısız"
    fi
    
    # Build tools (bazı Python paketleri için)
    if ! command -v gcc &> /dev/null; then
        warning "Build araçları kuruluyor..."
        apt install -y build-essential python3-dev || error "Build araçları kurulumu başarısız"
    fi
    
    # Nginx
    if ! command -v nginx &> /dev/null; then
        warning "Nginx kuruluyor..."
        apt update && apt install -y nginx || error "Nginx kurulumu başarısız"
    fi
    
    # Certbot (SSL için)
    if ! command -v certbot &> /dev/null; then
        warning "Certbot kuruluyor..."
        apt update && apt install -y certbot python3-certbot-nginx || error "Certbot kurulumu başarısız"
    fi
    
    # jq (JSON parser)
    if ! command -v jq &> /dev/null; then
        warning "jq kuruluyor..."
        apt update && apt install -y jq || error "jq kurulumu başarısız"
    fi
    
    success "Tüm gereksinimler hazır"
}

# Kullanıcı bilgilerini al
get_user_config() {
    echo
    echo -e "${PURPLE}🔧 BOT YAPILANDIRMA BİLGİLERİ${NC}"
    echo "══════════════════════════════════════════"
    
    # Domain
    echo -e "${CYAN}🌐 Domain Bilgisi${NC}"
    echo "SSL sertifikası alınacak domain adı:"
    read -p "Domain (örnek: vpn.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && error "Domain zorunlu!"
    
    # Telegram ID (Sadece Geliştirici)
    echo
    echo -e "${CYAN}👤 Geliştirici (Developer)${NC}"
    echo "Bot'un sahibi ve yöneticisi - Tüm yetkilere sahip:"
    read -p "Geliştirici Telegram ID: " DEVELOPER_ID
    [[ -z "$DEVELOPER_ID" ]] && error "Geliştirici Telegram ID zorunlu!"
    
    # Bot Token
    echo
    echo -e "${CYAN}🤖 Bot Bilgisi${NC}"
    echo "BotFather'dan aldığınız token:"
    read -p "Bot Token: " BOT_TOKEN
    [[ -z "$BOT_TOKEN" ]] && error "Bot Token zorunlu!"

    # Telegram Proxy (isteğe bağlı)
    echo
    echo -e "${CYAN}🔄 Telegram Proxy (isteğe bağlı)${NC}"
    echo "Sunucu Telegram API'ye erişemiyorsa SOCKS5 veya HTTP proxy girin."
    echo "Format: socks5://kullanici:sifre@ip:port  veya  http://ip:port"
    echo "Boş bırakırsanız proxy kullanılmaz:"
    read -p "Telegram Proxy URL (Enter=atla): " TELEGRAM_PROXY
    TELEGRAM_PROXY="${TELEGRAM_PROXY:-}"

    # Kurulum modu
    echo
    echo -e "${CYAN}⚙️ Kurulum Modu${NC}"
    echo "1) YAML Modu (API isteme, kurulumdan sonra YAML yükle)"
    echo "2) API Modu (Outline Server API ile kurulum)"
    read -p "Seçim (1 veya 2): " INSTALL_MODE_CHOICE

    CONNECTION_MODE=""
    OUTLINE_API=""

    case $INSTALL_MODE_CHOICE in
        1)
            CONNECTION_MODE="yaml"
            info "YAML modu seçildi - kurulumda API bilgisi istenmeyecek"
            ;;
        2)
            CONNECTION_MODE="api"
            ;;
        *)
            error "Geçersiz seçim! 1 veya 2 girin."
            ;;
    esac
    
    # Outline Server API
    if [[ "$CONNECTION_MODE" == "api" ]]; then
        echo
        echo -e "${CYAN}🔗 Outline Server API${NC}"
        echo "Outline Server API bilgisi (JSON formatında):"
        echo 'Örnek: {"apiUrl":"https://11.22.33.44:8080/-k_2g_pi...","certSha256":"CC62D1AF..."}'
        read -p "Outline Server API: " OUTLINE_API
        [[ -z "$OUTLINE_API" ]] && error "Outline Server API zorunlu!"

        # JSON formatını kontrol et
        if ! echo "$OUTLINE_API" | jq . > /dev/null 2>&1; then
            error "Outline Server API geçersiz JSON formatı!"
        fi
    fi
    
    # Dil seçimi
    echo
    echo -e "${CYAN}🌍 Dil Seçimi${NC}"
    echo "1) TR - Türkçe"
    echo "2) RU - Русский"
    read -p "Dil seçimi (1 veya 2): " LANG_CHOICE
    
    case $LANG_CHOICE in
        1) LANGUAGE="TR" ;;
        2) LANGUAGE="RU" ;;
        *) error "Geçersiz dil seçimi!" ;;
    esac
    
    # Özet göster
    echo
    echo -e "${PURPLE}📋 YAPILANDIRMA ÖZETİ${NC}"
    echo "══════════════════════════════════════════"
    echo -e "Domain: ${GREEN}$DOMAIN${NC}"
    echo -e "Geliştirici ID: ${GREEN}$DEVELOPER_ID${NC}"
    echo -e "Bot Token: ${GREEN}${BOT_TOKEN:0:10}...${NC}"
    if [[ "$CONNECTION_MODE" == "api" ]]; then
        echo -e "Kurulum Modu: ${GREEN}API${NC}"
        echo -e "Outline API: ${GREEN}Geçerli JSON${NC}"
    else
        echo -e "Kurulum Modu: ${GREEN}YAML${NC}"
        echo -e "Outline API: ${YELLOW}Kurulumda atlandı${NC}"
    fi
    echo -e "Dil: ${GREEN}$LANGUAGE${NC}"
    if [[ -n "$TELEGRAM_PROXY" ]]; then
        echo -e "Telegram Proxy: ${GREEN}$TELEGRAM_PROXY${NC}"
    else
        echo -e "Telegram Proxy: ${YELLOW}Kullanılmıyor${NC}"
    fi
    echo -e "Proxy: ${GREEN}Aktif (iptables yönlendirme)${NC}"
    echo
    
    read -p "Bu bilgiler doğru mu? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Kurulum iptal edildi."
        exit 0
    fi
}

# Dizinleri oluştur
create_directories() {
    info "Dizinler oluşturuluyor..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    mkdir -p "/var/log"
    mkdir -p "/var/www/html"
    success "Dizinler oluşturuldu"
}

# Konfigürasyon dosyası oluştur
create_config() {
    info "Konfigürasyon dosyası oluşturuluyor..."
    
    # JSON dosyasını Python ile güvenli şekilde oluştur
    python3 << PYTHON_EOF
# -*- coding: utf-8 -*-
import json
import os
import re
from urllib.parse import urlparse

config_dir = os.path.dirname("$CONFIG_FILE")
os.makedirs(config_dir, exist_ok=True)

connection_mode = "$CONNECTION_MODE"
outline_apis = []

if connection_mode == "api":
    # Outline API'den IP'yi çıkar
    outline_api_str = '''$OUTLINE_API'''
    outline_api = json.loads(outline_api_str)
    api_url = outline_api.get('apiUrl', '')

    # IP extraction
    original_ip = None
    try:
        parsed = urlparse(api_url)
        hostname = parsed.hostname
        # IPv4 veya IPv6
        if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
            original_ip = hostname
        elif ':' in hostname:
            original_ip = hostname
        else:
            original_ip = hostname
    except:
        original_ip = "Unknown"

    outline_apis = [
        {
            "id": "api1",
            "name": "Ana API",
            "api": outline_api,
            "original_ip": original_ip,
            "keys": []
        }
    ]

config = {
    "domain": "$DOMAIN",
    "developer_id": "$DEVELOPER_ID",
    "admin_ids": [],
    "bot_token": "$BOT_TOKEN",
    "telegram_proxy": "$TELEGRAM_PROXY",
    "connection_mode": connection_mode,
    "outline_apis": outline_apis,
    "port_range": {
        "start": 444,
        "end": 999,
        "used_ports": []
    },
    "bot_udid": "$(python3 -c 'import uuid; print(str(uuid.uuid4()))')",
    "language": "$LANGUAGE",
    "database": {
        "path": "$INSTALL_DIR/database.json"
    },
    "ssl": {
        "cert_path": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    },
    "web": {
        "port": 8444,
        "host": "0.0.0.0"
    }
}

with open("$CONFIG_FILE", 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

os.chmod("$CONFIG_FILE", 0o600)
print("✅ Config dosyası oluşturuldu")
PYTHON_EOF
    
    if [[ $? -ne 0 ]]; then
        error "Konfigürasyon dosyası oluşturulamadı!"
    fi
    
    success "Konfigürasyon dosyası oluşturuldu"
}

# SSL sertifikası al
setup_ssl() {
    info "SSL sertifikası alınıyor..."
    
    # Nginx durur
    systemctl stop nginx 2>/dev/null || true
    
    # Certbot ile SSL al
    if certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN"; then
        success "SSL sertifikası başarıyla alındı"
    else
        error "SSL sertifikası alınamadı! Domain DNS ayarlarını kontrol edin."
    fi
    
    # Otomatik yenileme için cron job ekle
    info "SSL otomatik yenileme yapılandırılıyor..."
    
    # Certbot otomatik yenileme timer'ını etkinleştir (systemd)
    if systemctl list-timers | grep -q certbot; then
        systemctl enable certbot.timer 2>/dev/null || true
        systemctl start certbot.timer 2>/dev/null || true
        success "Certbot systemd timer etkinleştirildi"
    else
        # Fallback: Manuel cron job ekle
        CRON_JOB="0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx' >> /var/log/certbot-renew.log 2>&1"
        
        # Cron job zaten varsa ekleme
        if ! grep -q "certbot renew" /etc/crontab 2>/dev/null; then
            echo "$CRON_JOB" >> /etc/crontab
            success "SSL otomatik yenileme cron job eklendi (her gün saat 03:00)"
        else
            success "SSL otomatik yenileme zaten yapılandırılmış"
        fi
    fi
    
    # Certbot hook scripti oluştur (nginx reload için)
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh << 'HOOK_EOF'
#!/bin/bash
# SSL yenileme sonrası nginx'i reload et
systemctl reload nginx
logger "SSL sertifikası yenilendi - Nginx reload edildi"
HOOK_EOF
    
    chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh
    success "SSL yenileme hook scripti oluşturuldu"
}

# Nginx yapılandırması
setup_nginx() {
    info "Nginx yapılandırılıyor..."
    
    cat > "$NGINX_CONFIG" << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # Modern SSL ayarları
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    location ~ ^/vip-user/([^/]+)/([^/]+)$ {
        # Sadece GET istekleri için User-Agent kontrolü
        set \$allowed 0;
        set \$check_ua 0;
        
        # POST istekleri (Telegram bot) için kontrolü atla
        if (\$request_method = POST) {
            set \$allowed 1;
        }
        
        # GET istekleri için kontrol gerekli
        if (\$request_method = GET) {
            set \$check_ua 1;
        }
        
        # VPN client'ları için izin (sadece GET istekleri)
        if (\$http_user_agent ~* "Go-http-client|ktor-client") {
            set \$allowed 1;
        }
        
        # GET isteği VE izinsiz User-Agent - Türkmence uyarı
        if (\$check_ua = 1) {
            set \$test "\${allowed}";
        }
        if (\$test = "0") {
            add_header Content-Type 'text/plain; charset=utf-8' always;
            return 403 'Men seni göryan :) aşakda görkezilen we sizin halayan VPN programmanyza açary dolylygyna kopyalap goyun hem-de açaryn dine 1 ulanyjy üçin niyetlenendigini unutman\n\nOutline';
        }
        
        proxy_pass http://127.0.0.1:8444;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header User-Agent \$http_user_agent;
    }
    
    location / {
        return 404;
    }
}
EOF
    
    # Nginx'i etkinleştir
    ln -sf "$NGINX_CONFIG" "$NGINX_ENABLED"
    
    # Nginx'i başlat
    systemctl enable nginx
    systemctl start nginx
    
    success "Nginx yapılandırıldı"
}

# Ana bot kodunu oluştur
create_bot_code() {
    info "Telegram Bot kodu oluşturuluyor..."
    
    cat > "$INSTALL_DIR/bot.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Outline VPN Telegram Bot
Gelişmiş anahtar yönetimi ve SSL destekli web sunucu
"""

import json
import logging
import asyncio
import aiohttp
import hashlib
import secrets
import time
import socket
import os
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Set
from urllib.parse import urlparse
import ssl

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes
from telegram.error import TimedOut, NetworkError
from telegram.request import HTTPXRequest
from aiohttp import web, ClientSession, ClientTimeout
import aiofiles

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/outline-telegram-bot.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class OutlineBot:
    def __init__(self, config_path: str):
        self.config = self.load_config(config_path)
        
        # Config validation ve cleanup
        self._validate_and_fix_config()
        
        self.database = self.load_database()

        # ss_url içindeki gerçek port ile kayıtlı portu hizala (master key hariç)
        self._reconcile_ports_with_ss_urls()

        # Paralel port seçimleri için rezervasyon kilidi
        self.port_lock = asyncio.Lock()
        self.reserved_ports: Set[int] = set()
        
        # Veritabanında backup_ips yoksa ekle
        if 'backup_ips' not in self.database:
            self.database['backup_ips'] = {}
            self.save_database()
        
        self.app = None
        self.web_app = None
        
        # Base64 decode cache (performans optimizasyonu)
        self.base64_decode_cache = {}
        # Database write cache (batch processing)
        self.db_write_pending = False
        
        # Port yönetimi: Config'den mevcut kullanılan portları al
        if 'port_range' not in self.config:
            self.config['port_range'] = {'start': 444, 'end': 999, 'used_ports': []}
        # Port listesi her zaman int olarak tutulur
        self.used_ports = set(
            p for p in (
                self._to_int_port(port)
                for port in self.config['port_range'].get('used_ports', [])
            )
            if p is not None
        )
        
        # UDID kontrolü - yoksa oluştur
        if 'bot_udid' not in self.config:
            import uuid
            self.config['bot_udid'] = str(uuid.uuid4())
            with open(config_path, 'w') as f:
                json.dump(self.config, f, indent=4)
        
        self.bot_udid = self.config['bot_udid']
        
        # Veritabanındaki mevcut portları senkronize et
        self._sync_used_ports_from_database()
        
        logger.info(f"📊 Port durumu: {len(self.used_ports)}/{self.config['port_range']['end'] - self.config['port_range']['start'] + 1} port kullanılıyor")
        
        # Dil metinleri
        self.texts = {
            "TR": {
                "welcome": "🎉 Outline VPN yönetim botuna hoş geldiniz!",
                "info": "Bilgilendirme: Geliştirici ve Yetkili @prime_mumia eğer herhangi bir sorunla karşılaşırsanız lütfen iletişime geçin",
                "create_key": "🔑 Anahtar Oluştur",
                "delete_key": "🗑️ Anahtar Sil", 
                "user_list": "📊 Kullanıcı Listesi",
                "advanced": "⚙️ Gelişmiş",
                "how_many_keys": "Kaç anahtar oluşturmak istiyorsunuz?",
                "key_duration": "⏰ <b>Anahtar süresi girin:</b>\n\n📋 <b>Format örnekleri:</b>\n• <code>1h</code> = 1 saat\n• <code>24h</code> = 24 saat\n• <code>7d</code> = 7 gün\n• <code>30d</code> = 30 gün\n• <code>1y</code> = 1 yıl\n\n💡 <b>Kurallar:</b>\n• Sadece sayı + h/d/y karakteri\n• h = saat, d = gün, y = yıl\n\n✏️ <b>Süreyi yazın:</b>",
                "key_created": "✅ Anahtar oluşturuldu:",
                "unauthorized": "❌ Bu botu kullanma yetkiniz yok!",
                "contact": "📞 İletişim",
                "refresh_api": "🔄 Outline API Yenile"
            },
            "RU": {
                "welcome": "🎉 Добро пожаловать! Добро пожаловать в бота управления Outline VPN.",
                "info": "Информация: Разработчик и Администратор @prime_mumia если у вас возникнут проблемы, пожалуйста свяжитесь",
                "create_key": "🔑 Создать ключ",
                "delete_key": "🗑️ Удалить ключ",
                "user_list": "📊 Список пользователей", 
                "advanced": "⚙️ Расширенные",
                "how_many_keys": "Сколько ключей вы хотите создать?",
                "key_duration": "⏰ <b>Введите срок действия ключа:</b>\n\n📋 <b>Примеры формата:</b>\n• <code>1h</code> = 1 час\n• <code>24h</code> = 24 часа\n• <code>7d</code> = 7 дней\n• <code>30d</code> = 30 дней\n• <code>1y</code> = 1 год\n\n💡 <b>Правила:</b>\n• Только число + h/d/y символ\n• h = час, d = день, y = год\n\n✏️ <b>Напишите срок:</b>",
                "key_created": "✅ Ключ создан:",
                "unauthorized": "❌ У вас нет прав на использование этого бота!",
                "contact": "📞 Контакт",
                "refresh_api": "🔄 Обновить Outline API"
            }
        }
        
    def load_config(self, config_path: str) -> dict:
        """Konfigürasyon dosyasını yükle"""
        with open(config_path, 'r') as f:
            return json.load(f)

    def _to_int_port(self, port) -> Optional[int]:
        """Port'u güvenle int'e çevir; başarısızsa None döner"""
        try:
            return int(port)
        except (TypeError, ValueError):
            return None

    def _get_master_key_port(self) -> Optional[int]:
        """Master ss:// anahtarından port'u çıkar; yoksa config/fallback döner"""
        master_ss_key = self.config.get('master_ss_key')
        if not master_ss_key:
            return None
        import re, base64
        # ss://...@IP:PORT formatı
        if '@' in master_ss_key:
            ip_port_match = re.search(r'@([\d\.]+):(\d+)', master_ss_key)
            if ip_port_match:
                return self._to_int_port(ip_port_match.group(2))
        # Base64 içinden PORT yakala
        try:
            key_part = master_ss_key[5:]  # ss:// kaldır
            decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
            ip_port_match = re.search(r'@([\d\.]+):(\d+)', decoded)
            if ip_port_match:
                return self._to_int_port(ip_port_match.group(2))
        except Exception:
            pass
        # Fallback: config outline_port veya 444
        return self._to_int_port(self.config.get('outline_port')) or 444
    
    def get_available_port(self) -> int:
        """444-999 aralığından rastgele kullanılabilir port seç (rezervasyonlar hariç)"""
        import random
        port_range = self.config.get('port_range', {'start': 444, 'end': 999})
        start_port = port_range.get('start', 444)
        end_port = port_range.get('end', 999)
        
        # Kullanılabilir portları hesapla (hem used hem rezervasyon dışarıda)
        all_ports = set(range(start_port, end_port + 1))
        unavailable = self.used_ports | getattr(self, 'reserved_ports', set())
        available_ports = list(all_ports - unavailable)
        
        if not available_ports:
            raise Exception(f"❌ Tüm portlar dolu! ({start_port}-{end_port} aralığı)\n\nKullanılmayan: 0/{len(all_ports)}")
        
        # Rastgele port seç
        selected_port = random.choice(available_ports)
        logger.info(f"🎲 Benzersiz port seçildi: {selected_port} (Kullanılabilir: {len(available_ports)}/{len(all_ports)})")
        return selected_port
    
    def mark_port_used(self, port: int) -> None:
        """Port'u kullanıldı olarak işaretle"""
        port_int = self._to_int_port(port)
        if port_int is None:
            logger.error(f"⚠️ Geçersiz port değeri işaretlenemedi: {port}")
            return
        if port_int not in self.used_ports:
            self.used_ports.add(port_int)
            self.config['port_range']['used_ports'] = list(self.used_ports)
            # Config'i kaydet
            try:
                with open('/etc/outline-bot/config.json', 'w') as f:
                    json.dump(self.config, f, indent=2)
                logger.info(f"✅ Port {port_int} kullanıldı olarak işaretlendi (Toplam: {len(self.used_ports)})")
            except Exception as e:
                logger.error(f"⚠️ Port kaydedilemedi: {e}")
        # Rezerv listeden çıkar
        if hasattr(self, 'reserved_ports') and port_int in self.reserved_ports:
            self.reserved_ports.discard(port_int)
    
    def mark_port_available(self, port: int) -> None:
        """Port'u tekrar kullanılabilir yap (anahtar silindiğinde)"""
        port_int = self._to_int_port(port)
        if port_int is None:
            logger.error(f"⚠️ Geçersiz port değeri serbest bırakılamadı: {port}")
            return
        if port_int in self.used_ports:
            self.used_ports.remove(port_int)
            self.config['port_range']['used_ports'] = list(self.used_ports)
            # Config'i kaydet
            try:
                with open('/etc/outline-bot/config.json', 'w') as f:
                    json.dump(self.config, f, indent=2)
                logger.info(f"♻️ Port {port_int} tekrar kullanılabilir hale getirildi (Kalan: {len(self.used_ports)})")
            except Exception as e:
                logger.error(f"⚠️ Port güncellenemedi: {e}")
        # Rezervden de çıkar
        if hasattr(self, 'reserved_ports'):
            self.reserved_ports.discard(port_int)
    
    def _sync_used_ports_from_database(self) -> None:
        """Veritabanındaki mevcut anahtarlardan kullanılan portları senkronize et"""
        db_ports = set()
        for key_id, key_data in self.database.get('keys', {}).items():
            # Master key modunda üretilen anahtarlar port havuzunu tüketmez
            if key_data.get('from_master_key'):
                continue
            port = key_data.get('port')
            port_int = self._to_int_port(port)
            if port_int:
                db_ports.add(port_int)
        
        # Config'teki portları veritabanıyla senkronize et
        if db_ports != self.used_ports:
            logger.info(f"🔄 Port senkronizasyonu: {len(self.used_ports)} -> {len(db_ports)}")
            self.used_ports = db_ports
            self.config['port_range']['used_ports'] = list(self.used_ports)
            try:
                with open('/etc/outline-bot/config.json', 'w') as f:
                    json.dump(self.config, f, indent=2)
                logger.info(f"✅ Portlar senkronize edildi: {len(db_ports)} port kullanılıyor")
            except Exception as e:
                logger.error(f"⚠️ Port senkronizasyonu kaydedilemedi: {e}")
    
    def _validate_and_fix_config(self):
        """Config dosyasını validate ve düzelt"""
        try:
            if 'connection_mode' not in self.config:
                self.config['connection_mode'] = 'api'
                logger.warning("⚠️ connection_mode eksikti, api olarak ayarlandı")

            if self.config.get('connection_mode') not in ['api', 'yaml']:
                self.config['connection_mode'] = 'api'
                logger.warning("⚠️ Geçersiz connection_mode, api olarak ayarlandı")

            # Dil alanını kontrol et ve düzelt
            if 'language' not in self.config:
                self.config['language'] = 'TR'
                logger.warning("⚠️ Language alanı eksik, TR olarak ayarlandı")
            
            lang = self.config.get('language', 'TR')
            if not lang or lang.startswith('$') or lang not in ['TR', 'RU']:
                self.config['language'] = 'TR'
                logger.warning(f"⚠️ Geçersiz language değeri: '{lang}', TR olarak ayarlandı")
            
            # Database path'i kontrol et
            if 'database' in self.config and 'path' in self.config['database']:
                db_path = self.config['database']['path']
                if '$INSTALL_DIR' in db_path:
                    db_path = db_path.replace('$INSTALL_DIR', '/opt/outline-telegram-bot')
                    self.config['database']['path'] = db_path
                    logger.info(f"✅ Database path düzeltildi: {db_path}")
            
            # Outline APIs kontrol et
            if 'outline_apis' not in self.config:
                if self.config.get('connection_mode') == 'yaml':
                    self.config['outline_apis'] = []
                    logger.warning("⚠️ YAML modunda outline_apis eksikti, boş liste olarak ayarlandı")
                else:
                    logger.error("❌ outline_apis alanı eksik!")
                    raise ValueError("outline_apis konfigürasyonu gerekli")
            
            if not isinstance(self.config['outline_apis'], list):
                logger.error("❌ outline_apis bir liste olmalı!")
                raise ValueError("outline_apis bir liste olmalıdır")
            
            if len(self.config['outline_apis']) == 0:
                if self.config.get('connection_mode') == 'yaml':
                    logger.warning("⚠️ API listesi boş - YAML modu aktif")
                    if not self.config.get('default_yaml_content'):
                        logger.warning("⚠️ YAML modunda default_yaml_content da boş - anahtar abonelikleri içerik döndüremez")
                else:
                    logger.error("❌ En az bir API yapılandırması gerekli!")
                    raise ValueError("En az bir Outline API gerekli")
            
            # Eski API'lere original_ip ekle
            from urllib.parse import urlparse
            import re
            config_changed = False
            for api in self.config['outline_apis']:
                if 'original_ip' not in api:
                    # Original IP'yi API URL'den çıkar
                    api_url = api.get('api', {}).get('apiUrl', '')
                    original_ip = 'Unknown'
                    try:
                        parsed = urlparse(api_url)
                        hostname = parsed.hostname
                        if hostname:
                            if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
                                original_ip = hostname
                            elif ':' in hostname:
                                original_ip = hostname
                            else:
                                original_ip = hostname
                    except:
                        pass
                    
                    api['original_ip'] = original_ip
                    config_changed = True
                    logger.info(f"✅ Added original_ip={original_ip} to API {api.get('id', 'unknown')}")
            
            if config_changed:
                self.save_config()
                logger.info("✅ Config updated with original_ip fields")
            
            # Admin IDs kontrolü
            if 'admin_ids' not in self.config:
                self.config['admin_ids'] = []
            
            logger.info("✅ Config validation başarılı")
            
        except Exception as e:
            logger.error(f"❌ Config validation hatası: {e}")
            raise

    def is_yaml_mode_active(self) -> bool:
        """YAML modunun aktif sayılması için hem mod hem de içerik dolu olmalı."""
        return self.config.get('connection_mode') == 'yaml' and bool(self.config.get('default_yaml_content'))

    def set_connection_mode(self, mode: str):
        """Bağlantı modunu güncelle ve config'e kaydet."""
        if mode not in ['api', 'yaml']:
            logger.warning(f"⚠️ Geçersiz connection_mode isteği: {mode}")
            return
        self.config['connection_mode'] = mode
        self.save_config()
    
    def load_database(self) -> dict:
        """Veritabanını yükle"""
        try:
            db_path = self.config.get('database', {}).get('path', '/opt/outline-telegram-bot/database.json')
            
            if not db_path:
                logger.warning("❌ Database path konfigürasyonda bulunamadı")
                db_path = '/opt/outline-telegram-bot/database.json'
            
            try:
                with open(db_path, 'r') as f:
                    return json.load(f)
            except FileNotFoundError:
                logger.info(f"📝 Veritabanı ilk kez oluşturuluyor: {db_path}")
                return {
                    "keys": {},
                    "stats": {
                        "total_keys": 0,
                        "active_keys": 0,
                        "requests": {}
                    },
                    "backup_ips": {}
                }
            except json.JSONDecodeError as e:
                logger.error(f"❌ Database JSON hatası: {e}")
                # Bozuk dosyayı backup al
                import shutil
                backup_path = f"{db_path}.corrupt.{int(time.time())}"
                shutil.copy(db_path, backup_path)
                logger.info(f"✅ Bozuk database backed up: {backup_path}")
                # Yeni veritabanı oluştur
                return {
                    "keys": {},
                    "stats": {
                        "total_keys": 0,
                        "active_keys": 0,
                        "requests": {}
                    },
                    "backup_ips": {}
                }
        except Exception as e:
            logger.error(f"❌ Veritabanı yükleme hatası: {e}")
            raise
    
    def save_database(self):
        """Veritabanını kaydet"""
        db_path = self.config['database']['path']
        with open(db_path, 'w') as f:
            json.dump(self.database, f, indent=2)
    
    def save_config(self):
        """Konfigürasyonu kaydet"""
        config_path = "/etc/outline-bot/config.json"
        with open(config_path, 'w') as f:
            json.dump(self.config, f, indent=2)
    
    def get_text(self, key: str) -> str:
        """Dil metnini al"""
        lang = self.config.get('language', 'TR')
        
        # Geçersiz dil kodu düzeltme (eğer $LANGUAGE gibi placeholder varsa)
        if not lang or lang.startswith('$'):
            lang = 'TR'
        
        # Dil desteklenmiyorsa Türkçe kullan
        if lang not in self.texts:
            lang = 'TR'
        
        return self.texts[lang].get(key, key)
    
    def get_main_menu_keyboard(self):
        """Ana menü klavyesini döndür"""
        keyboard = [
            [InlineKeyboardButton(self.get_text("create_key"), callback_data="create_key")],
            [InlineKeyboardButton(self.get_text("delete_key"), callback_data="delete_key")],
            [InlineKeyboardButton("📊 Önemli Bilgiler", callback_data="important_info")],
            [InlineKeyboardButton("💾 Yedekleme", callback_data="backup_menu")],
            [InlineKeyboardButton("🔄 Menüyü Yenile", callback_data="refresh_menu")],
            [InlineKeyboardButton(self.get_text("advanced"), callback_data="advanced")]
        ]
        return InlineKeyboardMarkup(keyboard)
    
    def get_back_to_menu_keyboard(self):
        """Ana menüye dönüş klavyesi"""
        keyboard = [
            [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
        ]
        return InlineKeyboardMarkup(keyboard)
    
    def is_authorized(self, user_id: int) -> bool:
        """Kullanıcı yetkili mi? (Developer veya Admin)"""
        return str(user_id) == self.config['developer_id'] or str(user_id) in self.config['admin_ids']
    
    def is_developer(self, user_id: int) -> bool:
        """Kullanıcı geliştirici mi?"""
        return str(user_id) == self.config['developer_id']
    
    def generate_udid(self) -> str:
        """Benzersiz UDID oluştur - Format: 34RT-65YT-34R3-8U6T"""
        import string
        import random
        
        # Karakter seti: Büyük harfler ve rakamlar (karışıklığı önlemek için 0, O, I, 1 hariç)
        chars = string.ascii_uppercase.replace('O', '').replace('I', '') + string.digits.replace('0', '').replace('1', '')
        
        # 4 grup, her grupta 4 karakter
        groups = []
        for _ in range(4):
            group = ''.join(random.choices(chars, k=4))
            groups.append(group)
        
        return '-'.join(groups)
    
    def ensure_unique_udid(self) -> str:
        """Mevcut UDID'lerle çakışmayan benzersiz UDID üret"""
        max_attempts = 100
        
        for attempt in range(max_attempts):
            udid = self.generate_udid()
            
            # Mevcut UDID'lerle çakışma kontrolü
            is_unique = True
            for key_data in self.database['keys'].values():
                if key_data.get('udid') == udid:
                    is_unique = False
                    break
            
            if is_unique:
                logger.info(f"🆔 Generated unique UDID: {udid} (attempt {attempt + 1})")
                return udid
        
        # Son çare: timestamp ekle
        import time
        timestamp = str(int(time.time()))[-4:]
        udid = self.generate_udid()
        # Son grubu timestamp ile değiştir
        udid_parts = udid.split('-')
        udid_parts[-1] = timestamp
        final_udid = '-'.join(udid_parts)
        
        logger.warning(f"⚠️ Using timestamp-based UDID: {final_udid}")
        return final_udid

    def get_next_number_for_name(self, custom_name: str) -> int:
        """Belirli bir özel isim için bir sonraki numarayı al"""
        existing_numbers = []
        custom_name_upper = custom_name.upper()
        
        # Mevcut anahtarlarda bu isimle başlayanları bul
        for key_id in self.database['keys'].keys():
            # Yeni format: key_id = "ELMA1", "GITHUB2" vs.
            if key_id.startswith(custom_name_upper):
                # ELMA123 → 123 çıkar
                number_part = key_id[len(custom_name_upper):]
                try:
                    number = int(number_part)
                    existing_numbers.append(number)
                except ValueError:
                    continue
        
        # En küçük eksik numarayı bul (1'den başlayarak)
        if not existing_numbers:
            return 1
        
        existing_numbers.sort()
        
        # 1'den başlayarak ilk eksik numarayı bul
        for i in range(1, max(existing_numbers) + 2):
            if i not in existing_numbers:
                return i
        
        return 1  # Fallback

    def generate_key_id(self, custom_name: str, key_number: int = None) -> str:
        """Benzersiz anahtar ID oluştur - Sadece İSİM+NUMARA formatı"""
        
        # Eğer key_number verilmemişse, bu isim için bir sonraki numarayı al
        if key_number is None:
            key_number = self.get_next_number_for_name(custom_name)
        
        # Basit format: ÖZEL_İSİM + anahtar numarası
        return f"{custom_name.upper()}{key_number}"  # GITHUB1, ELMA2, VIP_USER3
    
    def get_custom_id(self, key_id: str) -> str:
        """Key ID'den özel isim kısmını al - Basit format için tüm ID'yi döndür"""
        # Yeni format: ELMA1, GITHUB2, VIP_USER3 (artık ayırma gerekmiyor)
        return key_id  # Tüm ID zaten kısa ve temiz
    
    def get_api_by_id(self, api_id: str) -> dict:
        """API ID'sine göre API bilgisini al"""
        for api in self.config['outline_apis']:
            if api['id'] == api_id:
                return api
        return None
    
    def get_api_for_key(self, key_id: str) -> dict:
        """Anahtar için API bilgisini al"""
        for api in self.config['outline_apis']:
            if key_id in api['keys']:
                return api
        # Eğer bulunamazsa ilk API'yi döndür (fallback)
        return self.config['outline_apis'][0] if self.config['outline_apis'] else None
    
    def get_ip_from_api_url(self, api_url: str) -> str:
        """API URL'inden IP adresini çıkar"""
        import re
        from urllib.parse import urlparse
        
        try:
            parsed = urlparse(api_url)
            hostname = parsed.hostname
            
            # IPv4 kontrolü
            if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
                return hostname
            
            # IPv6 kontrolü
            if ':' in hostname:
                return hostname
            
            return hostname
        except:
            return "Unknown"

    def _parse_endpoint_host_value(self, endpoint_value: str) -> str:
        """Tek bir endpoint değerinden host/IP çıkar"""
        import re
        from urllib.parse import urlparse

        if not endpoint_value:
            return ""

        endpoint_value = endpoint_value.strip()

        # Placeholder değerleri (örn: $type, ${endpoint}) geçerli host/IP değildir
        if re.match(r'^\$\{?[A-Za-z_][A-Za-z0-9_\-]*\}?$', endpoint_value):
            return ""

        # URL formatı (örn: ws://1.2.3.4:443/path)
        if '://' in endpoint_value:
            try:
                parsed = urlparse(endpoint_value)
                if parsed.hostname:
                    return parsed.hostname
            except Exception:
                pass

        if endpoint_value.startswith('['):
            end_idx = endpoint_value.find(']')
            if end_idx > 1:
                return endpoint_value[1:end_idx]

        if endpoint_value.count(':') == 1:
            host, port = endpoint_value.split(':', 1)
            if port.isdigit():
                return host.strip()

        ip_port_match = re.match(r'^(.*):(\d+)$', endpoint_value)
        if ip_port_match and ':' in ip_port_match.group(1):
            return ip_port_match.group(1).strip('[]').strip()

        # Metin içinde geçen ilk IP'yi yakala
        ipv4_match = re.search(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b', endpoint_value)
        if ipv4_match:
            return ipv4_match.group(1)

        ipv6_match = re.search(r'\[([0-9a-fA-F:]+)\]', endpoint_value)
        if ipv6_match:
            return ipv6_match.group(1)

        raw = endpoint_value.strip('[]').strip()
        if raw.startswith('$'):
            return ""
        return raw

    def extract_yaml_endpoint_hosts(self, yaml_content: str) -> list:
        """YAML içindeki tüm endpoint host/IP değerlerini döndür (benzersiz)."""
        import re

        if not yaml_content:
            return []

        unique_hosts = []

        # Öncelik: websocket endpoint bloğu içindeki endpoint satırları
        # Örnek:
        # endpoint:
        #   $type: websocket
        #   url: wss://...
        #   endpoint: 104.21.80.117:443
        websocket_blocks = re.finditer(
            r'(?mis)^\s*endpoint\s*:\s*$\s*^\s*\$type\s*:\s*websocket\s*$.*?(?=^\s*endpoint\s*:\s*$|^\S|\Z)',
            yaml_content
        )
        for block in websocket_blocks:
            nested_values = re.findall(r'(?mi)^[ \t]*endpoint[ \t]*:[ \t]*["\']?([^"\'\r\n]+)["\']?[ \t]*$', block.group(0))
            for value in nested_values:
                host = self._parse_endpoint_host_value(value)
                if host and host not in unique_hosts:
                    unique_hosts.append(host)

        if unique_hosts:
            return unique_hosts

        values = re.findall(r'(?mi)^[ \t]*endpoint[ \t]*:[ \t]*["\']?([^"\'\r\n]+)["\']?[ \t]*$', yaml_content)
        if not values:
            return []

        for value in values:
            host = self._parse_endpoint_host_value(value)
            if host and host not in unique_hosts:
                unique_hosts.append(host)

        return unique_hosts

    def extract_yaml_endpoint_host(self, yaml_content: str) -> str:
        """YAML içindeki endpoint satırlarından en uygun host/IP'yi al"""
        import ipaddress

        hosts = self.extract_yaml_endpoint_hosts(yaml_content)
        if not hosts:
            return ""

        # Birden fazla endpoint varsa IP olanlara öncelik ver
        ip_hosts = []
        for host in hosts:
            try:
                ipaddress.ip_address(host)
                ip_hosts.append(host)
            except ValueError:
                pass

        if ip_hosts:
            return ip_hosts[-1]

        return hosts[-1]

    def sanitize_yaml_endpoint_blocks(self, yaml_content: str) -> str:
        """Hatalı endpoint bloklarındaki anahtarsız IP satırlarını temizler."""
        import re

        if not yaml_content:
            return yaml_content

        lines = yaml_content.splitlines()
        cleaned = []

        for idx, line in enumerate(lines):
            stripped = line.strip()

            # Örnek bozuk satır: "      104.21.80.2"
            is_standalone_ip = re.match(r'^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]+)(?::\d+)?$', stripped) is not None
            prev_stripped = cleaned[-1].strip() if cleaned else ""

            next_stripped = ""
            if idx + 1 < len(lines):
                next_stripped = lines[idx + 1].strip()

            # endpoint: bloğunun hemen altında yanlışlıkla oluşmuş düz IP satırını atla
            if is_standalone_ip and prev_stripped == 'endpoint:' and (
                next_stripped.startswith('$type:') or
                next_stripped.startswith('url:') or
                next_stripped.startswith('endpoint:')
            ):
                continue

            cleaned.append(line)

        return "\n".join(cleaned) + ("\n" if yaml_content.endswith("\n") else "")

    def update_yaml_endpoint_host(self, yaml_content: str, new_host: str):
        """YAML içindeki endpoint host/IP kısmını değiştirir, portu korur"""
        import re
        from urllib.parse import urlsplit, urlunsplit

        if not yaml_content:
            return yaml_content, 0

        yaml_content = self.sanitize_yaml_endpoint_blocks(yaml_content)

        clean_host = (new_host or '').strip().strip('[]')

        # Dikkat: [ \t]* kullanılır; \s* newline eşleştirip "endpoint:" bloğunu bozabilir.
        pattern = r'(?mi)^([ \t]*endpoint[ \t]*:[ \t]*)(["\']?)([^"\'\r\n]+)(["\']?[ \t]*)$'

        def _replace(match):
            prefix = match.group(1)
            quote_open = match.group(2)
            current_value = match.group(3).strip()
            quote_close = match.group(4)

            # URL formatını koru (örn: wss://1.2.3.4:443/path?x=1)
            if '://' in current_value:
                try:
                    split = urlsplit(current_value)
                    if split.hostname:
                        new_netloc_host = clean_host
                        if ':' in new_netloc_host and not new_netloc_host.startswith('['):
                            new_netloc_host = f"[{new_netloc_host}]"

                        new_netloc = new_netloc_host
                        if split.port:
                            new_netloc += f":{split.port}"

                        rebuilt = urlunsplit((split.scheme, new_netloc, split.path, split.query, split.fragment))
                        return f"{prefix}{quote_open}{rebuilt}{quote_close}"
                except Exception:
                    # URL parse edilemezse aşağıdaki klasik yoldan devam et
                    pass

            port_part = ''
            if current_value.startswith('['):
                end_idx = current_value.find(']')
                if end_idx != -1 and len(current_value) > end_idx + 1 and current_value[end_idx + 1] == ':':
                    port_part = current_value[end_idx + 1:]
            elif current_value.count(':') == 1:
                host_part, port_part_raw = current_value.split(':', 1)
                if host_part and port_part_raw.isdigit():
                    port_part = f":{port_part_raw}"
            else:
                ip_port_match = re.match(r'^(.*):(\d+)$', current_value)
                if ip_port_match and ':' in ip_port_match.group(1):
                    port_part = f":{ip_port_match.group(2)}"

            endpoint_host = clean_host
            if port_part and ':' in endpoint_host and not endpoint_host.startswith('['):
                endpoint_host = f"[{endpoint_host}]"

            return f"{prefix}{quote_open}{endpoint_host}{port_part}{quote_close}"

        return re.subn(pattern, _replace, yaml_content)
    
    async def create_outline_key(self, name: str, api_id: str = None, preferred_port: int = None) -> dict:
        """Outline sunucusunda anahtar oluştur - Dinamik port (Config veya istenen port)"""
        # API seç
        if api_id:
            api_info = self.get_api_by_id(api_id)
        else:
            api_info = self.config['outline_apis'][0]  # Varsayılan ilk API
        
        if not api_info:
            raise Exception("❌ API bulunamadı! Config dosyasını kontrol edin.")
        
        # API URL'i al
        api_url = api_info['api']['apiUrl']
        original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
        
        # Port seçimi: tercih edilen port varsa onu kullan, yoksa havuzdan seç (rezervasyon kilidiyle)
        reserved_port = await self._reserve_port(preferred_port)
        port = reserved_port
        
        logger.info(f"Creating Outline key: name={name}, port={port} (POST body'de gönderilecek), api_id={api_info['id']}, original_ip={original_ip}")
        
        # API URL'nin geçerli olup olmadığını kontrol et
        if not api_url or not api_url.startswith('https://'):
            raise Exception(f"❌ Geçersiz API URL: {api_url}\n\nIP güncelleme sonrası API URL bozulmuş olabilir. Lütfen API ayarlarını kontrol edin!")
        
        async with ClientSession() as session:
            # SSL sertifikasını doğrula
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            try:
                # Anahtar oluştur - Port'u doğrudan POST body'de gönder (race condition'ı önler)
                request_body = {
                    "method": "chacha20-ietf-poly1305",
                    "port": port  # ← Her anahtar için benzersiz port gönderiliyor
                }
                
                logger.info(f"🔑 Creating Outline key with port {port} (name will be: {name})")
                
                async with session.post(
                    f"{api_url}/access-keys",
                    json=request_body,  # ← Port body'de gönderiliyor
                    ssl=ssl_context,
                    timeout=ClientTimeout(total=15)
                ) as response:
                    logger.info(f"Outline API response status: {response.status}")
                    
                    if response.status == 201:
                        result = await response.json()
                        key_id = result['id']
                        created_port = result.get('port', port)
                        created_port = self._to_int_port(created_port) or port
                        
                        # PORT ÇAKIŞMA KONTROL - Outline farklı port atadıysa kritik hata!
                        if created_port != port:
                            logger.error(f"🚨 OUTLINE PORT HATASI! İstenen: {port}, Atanan: {created_port}")
                            logger.error(f"   Anahtar: {name}, Outline Key ID: {key_id}")
                            logger.error(f"   Bu durum Outline API'de port parametre desteği yoksa oluşabilir!")
                            # Yine de işleme devam et, port çakışma kontrolü sonra düzeltecek
                        
                        # İsim güncelle
                        async with session.put(
                            f"{api_url}/access-keys/{key_id}/name",
                            json={"name": name},
                            ssl=ssl_context,
                            timeout=ClientTimeout(total=15)
                        ) as name_response:
                            if name_response.status != 204:
                                logger.warning(f"⚠️ İsim güncellenemedi: {name_response.status}")
                        
                        # Port bilgisini kaydet
                        result['port'] = created_port
                        logger.info(f"✅ Outline key created: ID={key_id}, Port={created_port}, Name={name}")
                        
                        # KRITIK: Port çakışması kontrolü - başka anahtarda kullanılıyorsa UYAR
                        if created_port in self.used_ports:
                            logger.error(f"🚨 ÇAKIŞMA TESPİT EDİLDİ! Port {created_port} zaten başka bir anahtarda kullanılıyor!")
                            logger.error(f"   Anahtar: {name}, Outline Key ID: {key_id}")
                            logger.error(f"   Bu port çakışması manuel düzeltme gerektirebilir!")
                        
                        # Port'u kullanıldı olarak işaretle
                        self.mark_port_used(created_port)

                        # Eğer API farklı port atadıysa (olmaması gereken durum) eski rezervi bırak
                        if created_port != port:
                            logger.warning(f"⚠️ Outline farklı port atadı ({created_port}), rezerve port ({port}) serbest bırakılıyor")
                            self._release_reserved_port(port)
                        
                        return result
                    else:
                        error_text = await response.text()
                        logger.error(f"Outline API error: status={response.status}, response={error_text}")
                        # Port rezervasyonunu serbest bırak
                        self._release_reserved_port(port)
                        raise Exception(f"❌ Outline API hatası!\n\nURL: {api_url}\nDurum: {response.status}\nHata: {error_text[:200]}")
            except asyncio.TimeoutError:
                # Rezerv portu serbest bırak
                self._release_reserved_port(port)
                logger.error(f"Outline API timeout: {api_url}")
                raise Exception(f"❌ API bağlantı zaman aşımı!\n\nURL: {api_url}\n\nYeni IP'de Outline API çalışmıyor olabilir.\nLütfen kontrol edin:\n1. Sunucu açık mı?\n2. Firewall kuralları doğru mu?\n3. IP yönlendirmesi çalışıyor mu?")
            except aiohttp.ClientConnectorError as e:
                self._release_reserved_port(port)
                logger.error(f"Outline API connection error: {e}")
                raise Exception(f"❌ API'ye bağlanılamadı!\n\nURL: {api_url}\nHata: {str(e)[:200]}\n\nLütfen kontrol edin:\n1. IP adresi doğru mu?\n2. Port açık mı?\n3. Firewall kuralları doğru mu?")
            except Exception as e:
                self._release_reserved_port(port)
                logger.error(f"Outline key creation exception: {e}")
                # Eğer zaten detaylı hata mesajıysa olduğu gibi fırlat
                if str(e).startswith('❌'):
                    raise
                # Değilse detaylı hata ekle
                raise Exception(f"❌ Anahtar oluşturulamadı!\n\nAPI: {api_url}\nHata: {str(e)[:200]}")
    
    async def delete_outline_key(self, outline_key_id: str, api_id: str = None, port: int = None) -> bool:
        """Outline sunucusundan anahtar sil ve port'u serbest bırak"""
        # API seç
        if api_id:
            api_info = self.get_api_by_id(api_id)
        else:
            # İlk API'yi dene
            api_info = self.config['outline_apis'][0] if self.config['outline_apis'] else None
        
        if not api_info:
            return False
        
        api_url = api_info['api']['apiUrl']
        
        async with ClientSession() as session:
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            try:
                async with session.delete(
                    f"{api_url}/access-keys/{outline_key_id}",
                    ssl=ssl_context
                ) as response:
                    success = response.status == 204
                    
                    # Silme başarılıysa ve port bilgisi varsa, port'u serbest bırak
                    if success and port:
                        self.mark_port_available(port)
                        logger.info(f"🔓 Port {port} serbest bırakıldı (Anahtar ID: {outline_key_id})")
                    
                    return success
            except Exception as e:
                logger.error(f"Outline key deletion error: {e}")
                return False
    
    async def update_keys_with_new_api(self) -> dict:
        """
        API yenilendiğinde/değiştirildiğinde:
        1. API'deki mevcut 'vip-user-' anahtarlarını PARALEL sil
        2. Veritabanındaki tüm anahtarları PARALEL yeniden oluştur
        """
        import time
        start_time = time.time()
        
        updated_count = 0
        created_count = 0
        cleaned_count = 0
        
        # İlk API'yi al
        if not self.config['outline_apis']:
            logger.error("No Outline APIs configured!")
            return {'updated': 0, 'created': 0, 'cleaned': 0}
        
        api_info = self.config['outline_apis'][0]
        api_url = api_info['api']['apiUrl']
        api_id = api_info['id']
        
        logger.info("🔄 Starting API update: Clean existing keys and recreate all from database...")
        
        # ADIM 0: Port havuzunu temizle (anahtarlar yeniden oluşturulurken yeni portlar atanacak)
        logger.info("🔄 Port havuzu temizleniyor (YENİ port atama için)...")
        old_port_count = len(self.used_ports)
        self.used_ports.clear()
        self.reserved_ports.clear()
        self.config['port_range']['used_ports'] = []
        self.save_config()
        logger.info(f"✅ Port havuzu temizlendi: {old_port_count} port serbest bırakıldı - Her anahtara YENİ benzersiz port atanacak")
        
        # ADIM 1: API'deki mevcut 'vip-user-' anahtarlarını PARALEL temizle
        async with ClientSession() as session:
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            try:
                # Mevcut anahtarları listele
                async with session.get(f"{api_url}/access-keys", ssl=ssl_context) as response:
                    if response.status == 200:
                        data = await response.json()
                        outline_keys = data.get('accessKeys', [])
                        
                        # vip-user- ile başlayan anahtarları PARALEL sil
                        logger.info(f"🧹 Cleaning {len(outline_keys)} keys from API (parallel)...")
                        
                        delete_tasks = []
                        for key in outline_keys:
                            key_name = key.get('name', '')
                            if key_name.startswith('vip-user-'):
                                key_id = key.get('id')
                                delete_tasks.append(self._delete_key_async(session, api_url, key_id, key_name, ssl_context))
                        
                        # Tüm silme işlemlerini paralel çalıştır
                        if delete_tasks:
                            delete_results = await asyncio.gather(*delete_tasks, return_exceptions=True)
                            cleaned_count = sum(1 for r in delete_results if r is True)
                            logger.info(f"✅ Cleaned {cleaned_count} keys from API (parallel)")
                    else:
                        logger.error(f"❌ Failed to fetch keys from API: {response.status}")
                        
            except Exception as e:
                logger.error(f"❌ Error during API cleanup: {e}")
        
        # Süre kontrolü - 1. bildirim
        elapsed = time.time() - start_time
        if elapsed > 60:
            logger.warning(f"⏱️ Temizlik 1 dakikayı aştı: {int(elapsed)}s - {cleaned_count} anahtar silindi")
        
        # ADIM 2: Veritabanındaki tüm anahtarları PARALEL yeniden oluştur
        logger.info("🔨 Recreating all keys from database (parallel) - Her anahtara BENZERSIZ port atanıyor...")
        
        create_tasks = []
        keys_to_create = []
        
        for key_id, key_data in list(self.database['keys'].items()):
            # UDID yoksa ekle
            if 'udid' not in key_data:
                udid = self.ensure_unique_udid()
                self.database['keys'][key_id]['udid'] = udid
                updated_count += 1
            
            custom_id = self.get_custom_id(key_id)
            name = f"vip-user-{custom_id}"
            keys_to_create.append((key_id, name))
            create_tasks.append(self._create_key_for_update(key_id, name, api_id, api_info))
        
        # Tüm oluşturma işlemlerini paralel çalıştır (batch'ler halinde)
        batch_size = 20  # Her seferinde 20 anahtar paralel oluştur
        total_keys = len(create_tasks)
        
        for i in range(0, total_keys, batch_size):
            batch = create_tasks[i:i+batch_size]
            batch_num = i//batch_size + 1
            total_batches = (total_keys + batch_size - 1)//batch_size
            logger.info(f"🔨 Batch {batch_num}/{total_batches} oluşturuluyor ({len(batch)} anahtar, her birine BENZERSIZ port)...")
            
            batch_results = await asyncio.gather(*batch, return_exceptions=True)
            
            for result in batch_results:
                if isinstance(result, dict) and result.get('success'):
                    created_count += 1
                elif isinstance(result, Exception):
                    logger.error(f"❌ Batch creation error: {result}")
            
            # Her batch sonrası süre kontrolü
            elapsed = time.time() - start_time
            if elapsed > 60 and i == 0:
                logger.warning(f"⏱️ İlk batch 1 dakikayı aştı: {int(elapsed)}s - {created_count}/{total_keys} anahtar oluşturuldu")
        
        # PORT ÇAKIŞMA KONTROLÜ - Tüm anahtarları kontrol et
        logger.info("🔍 Port çakışmaları kontrol ediliyor...")
        port_conflicts = {}
        for key_id, key_data in self.database['keys'].items():
            if key_data.get('from_master_key'):
                continue
            port = self._to_int_port(key_data.get('port'))
            if port:
                if port not in port_conflicts:
                    port_conflicts[port] = []
                port_conflicts[port].append(key_id)
        
        # Çakışan portları düzelt
        conflicts_fixed = 0
        for port, key_ids in port_conflicts.items():
            if len(key_ids) > 1:
                logger.warning(f"⚠️ Port {port} çakışması: {len(key_ids)} anahtar aynı portu kullanıyor: {', '.join([k[:12] for k in key_ids])}")
                # İlk anahtarı koru, diğerlerine yeni port ata
                for i, conflicting_key_id in enumerate(key_ids[1:], 1):
                    try:
                        new_port = self.get_available_port()
                        self.database['keys'][conflicting_key_id]['port'] = new_port
                        self.mark_port_used(new_port)
                        conflicts_fixed += 1
                        logger.info(f"✅ Çakışma düzeltildi: {conflicting_key_id[:12]}... → Port {new_port}")
                    except Exception as e:
                        logger.error(f"❌ Port düzeltilemedi ({conflicting_key_id[:12]}...): {e}")
        
        if conflicts_fixed > 0:
            logger.warning(f"⚠️ {conflicts_fixed} port çakışması otomatik düzeltildi!")
        else:
            logger.info("✅ Port çakışması bulunamadı")
        
        # Veritabanını kaydet
        if updated_count > 0 or created_count > 0 or conflicts_fixed > 0:
            self.save_database()
            logger.info(f"💾 Database saved: {created_count} keys recreated, {updated_count} keys updated, {conflicts_fixed} conflicts fixed")
        else:
            logger.info("ℹ️ No keys needed processing")
        
        # Toplam süre
        total_time = time.time() - start_time
        logger.info(f"⏱️ Total operation time: {int(total_time)}s")
        
        if total_time > 60:
            logger.warning(f"⏱️ İşlem 1 dakikayı aştı: {int(total_time)}s - Temizlenen: {cleaned_count}, Oluşturulan: {created_count}")
        
        logger.info(f"✅ API güncelleme tamamlandı: Her anahtara YENİ benzersiz port atandı (444-999 arası, POST body ile)")
        
        return {
            'updated': updated_count,
            'created': created_count,
            'cleaned': cleaned_count,
            'duration': int(total_time)
        }
    
    async def _delete_key_async(self, session, api_url, key_id, key_name, ssl_context):
        """Tek bir anahtarı asenkron sil"""
        try:
            async with session.delete(
                f"{api_url}/access-keys/{key_id}",
                ssl=ssl_context,
                timeout=ClientTimeout(total=10)
            ) as response:
                if response.status == 204:
                    logger.debug(f"🗑️ Deleted: {key_name}")
                    return True
                return False
        except Exception as e:
            logger.warning(f"⚠️ Could not delete {key_name}: {e}")
            return False
    
    async def _create_key_for_update(self, key_id, name, api_id, api_info):
        """Tek bir anahtarı yenileme için oluştur - Port POST body'de gönderilir"""
        try:
            logger.debug(f"🔑 Creating key: {name} (HER ZAMAN YENİ benzersiz port atanacak)")
            # API güncelleme sırasında HER ZAMAN yeni port ata (preferred_port=None)
            new_outline_key = await self.create_outline_key(name, api_id, preferred_port=None)
            
            # ss_url'deki IP'yi güncelle
            refresh_ss_url = new_outline_key['accessUrl']
            original_ip = api_info.get('original_ip')
            current_ip = self.get_ip_from_api_url(api_info['api']['apiUrl'])
            
            if original_ip and current_ip and original_ip != current_ip and original_ip in refresh_ss_url:
                refresh_ss_url = refresh_ss_url.replace(original_ip, current_ip)
            
            # Anahtarın gerçek port'unu kullan (create_outline_key zaten mark_port_used çağırdı)
            created_port = self._to_int_port(new_outline_key.get('port'))
            if created_port is None:
                # Bu durumda outline port dönmedi, havuzdan seç
                created_port = await self._reserve_port(preferred_port)
                self.mark_port_used(created_port)
                logger.warning(f"⚠️ Outline port dönmedi, havuzdan seçildi: {created_port} - Anahtar: {name}")
            else:
                # Port çakışması kontrolü - başka anahtarda kullanılıyorsa yeni port seç
                if created_port in [self._to_int_port(k.get('port')) for kid, k in self.database['keys'].items() if kid != key_id and not k.get('from_master_key')]:
                    logger.warning(f"⚠️ Port çakışması tespit edildi: {created_port} başka anahtarda kullanılıyor! Yeni port seçiliyor...")
                    # Çakışan portu serbest bırak ve yeni seç
                    self.mark_port_available(created_port)
                    new_port = await self._reserve_port(None)  # Rastgele seç
                    self.mark_port_used(new_port)
                    created_port = new_port
                    logger.info(f"✅ Yeni port atandı: {created_port} - Anahtar: {name}")
            
            logger.debug(f"🎲 Port: {created_port} - Anahtar: {name}")
            
            # Veritabanını güncelle
            self.database['keys'][key_id]['outline_key_id'] = new_outline_key['id']
            self.database['keys'][key_id]['ss_url'] = refresh_ss_url
            self.database['keys'][key_id]['api_id'] = api_id
            self.database['keys'][key_id]['port'] = created_port
            
            logger.debug(f"✅ Recreated: {key_id[:12]}...")
            return {'success': True, 'key_id': key_id}
            
        except Exception as e:
            logger.error(f"❌ Failed to recreate {key_id[:12]}...: {e}")
            return {'success': False, 'key_id': key_id, 'error': str(e)}
    
    async def _refresh_single_key(self, key_id, custom_id, api_id, api_url, original_ip, current_ip):
        """API refresh için tek bir anahtarı yeniden oluştur - HER ZAMAN YENİ port atar"""
        try:
            # Yeni API'de anahtar oluştur - HER ZAMAN YENİ benzersiz port ata
            new_outline_key = await self.create_outline_key(
                f"vip-user-{custom_id}",
                api_id=api_id,
                preferred_port=None  # ← HER ZAMAN YENİ port
            )
            
            # ss_url'deki IP'yi güncelle
            new_ss_url = new_outline_key['accessUrl']
            if original_ip and original_ip in new_ss_url:
                if current_ip and original_ip != current_ip:
                    new_ss_url = new_ss_url.replace(original_ip, current_ip)
                    logger.debug(f"Updated ss_url IP: {original_ip} → {current_ip}")
            
            # Anahtarın gerçek port'unu kullan (create_outline_key zaten mark_port_used çağırdı)
            current_port = self._to_int_port(new_outline_key.get('port'))
            if current_port is None:
                # Fallback: Outline port dönmediyse havuzdan seç
                current_port = await self._reserve_port(None)
                self.mark_port_used(current_port)
            logger.debug(f"🎲 YENİ port atandı: {current_port} - Anahtar: vip-user-{custom_id}")
            
            # Database'i güncelle
            self.database['keys'][key_id]['outline_key_id'] = new_outline_key['id']
            self.database['keys'][key_id]['ss_url'] = new_ss_url
            self.database['keys'][key_id]['api_id'] = api_id
            self.database['keys'][key_id]['port'] = current_port
            
            logger.debug(f"✅ Key {key_id[:12]}... refreshed")
            return {'success': True, 'key_id': key_id}
            
        except Exception as e:
            logger.error(f"❌ Error refreshing key {key_id}: {e}")
            return {'success': False, 'key_id': key_id, 'error': str(e)}

    # ...existing code...
    
    async def start_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Start komutu"""
        user_id = update.effective_user.id
        
        if not self.is_authorized(user_id):
            await update.message.reply_text(self.get_text("unauthorized"))
            return
        
        await self.show_main_menu(update, context)
    
    async def show_main_menu(self, update, context, edit_message=False):
        """Ana menüyü göster - /start benzeri davranış"""
        welcome_text = f"{self.get_text('welcome')}\n\n{self.get_text('info')}"
        
        # Sadece anahtar sayısını göster
        if self.database['keys']:
            total_keys = self.database['stats']['total_keys']  # Stats'tan al
            active_keys = len([k for k, v in self.database['keys'].items() if not self.is_key_expired(v['created_at'], v['duration'])])
            expired_keys = total_keys - active_keys
            
            welcome_text += f"\n📊 <b>Anahtar İstatistikleri:</b>\n"
            welcome_text += f"• Toplam: <code>{total_keys}</code> adet\n"
            welcome_text += f"• Aktif: <code>{active_keys}</code> adet\n"
            welcome_text += f"• Süresi Dolmuş: <code>{expired_keys}</code> adet"
        else:
            welcome_text += "\n📊 <b>Henüz anahtar oluşturulmamış</b>"
        
        reply_markup = self.get_main_menu_keyboard()
        
        if edit_message and hasattr(update, 'callback_query'):
            await update.callback_query.edit_message_text(welcome_text, parse_mode='HTML', reply_markup=reply_markup)
        else:
            await update.message.reply_text(welcome_text, parse_mode='HTML', reply_markup=reply_markup)

    async def button_handler(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Buton işleyici"""
        query = update.callback_query
        await query.answer()
        
        user_id = query.from_user.id
        data = query.data
        
        # DEBUG: Buton tıklama logları
        logger.info(f"🔘 Button clicked: '{data}' by user {user_id}")
        
        if not self.is_authorized(user_id):
            logger.warning(f"⚠️ Unauthorized button access: user {user_id} tried '{data}'")
            await query.edit_message_text(self.get_text("unauthorized"))
            return
        
        logger.info(f"✅ Processing button: '{data}' for authorized user {user_id}")
        
        try:
            if data == "main_menu":
                logger.info("🏠 Processing main_menu button")
                # Ana menüye dön - /start benzeri davranış
                await self.show_main_menu(update, context, edit_message=True)
                
            elif data == "refresh_menu":
                logger.info("🔄 Processing refresh_menu button")
                # Menüyü yenile - /start benzeri davranış
                await query.edit_message_text("🔄 Menü yenileniyor...")
                await self.show_main_menu(update, context, edit_message=True)
                
            elif data == "create_key":
                logger.info("🔑 Processing create_key button")
                
                # Çoklu API kontrolü - Hangi API'den oluşturulacağını sor
                api_count = len(self.config['outline_apis'])
                yaml_mode = self.is_yaml_mode_active()

                if yaml_mode:
                    context.user_data['selected_api_for_key'] = 'yaml'
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text("✏️ <b>Anahtar İsmi</b>\n\nLütfen oluşturulacak anahtarlar için bir isim girin:\n\n📝 <b>Örnekler:</b>\n• ELMA\n• AHMET\n• VIP_USER\n• OZEL_ANAHTAR\n\n💡 <b>Not:</b> Bu isim anahtar URL'inde görünecek", parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data['state'] = 'waiting_key_name'
                    return
                
                if api_count > 1:
                    # Çoklu API var - Kullanıcıya seçim sun
                    api_selection_text = "🔑 <b>Anahtar Oluşturma - API Seçimi</b>\n\n"
                    api_selection_text += f"📊 <b>Mevcut {api_count} API tespit edildi.</b>\n"
                    api_selection_text += "Hangi API'den anahtar oluşturmak istiyorsunuz?\n\n"
                    
                    # API'leri sırala: api1 önce, sonra diğerleri
                    sorted_apis = sorted(
                        self.config['outline_apis'],
                        key=lambda x: (x['id'] != 'api1', x['id'])
                    )
                    
                    for idx, api_info in enumerate(sorted_apis, 1):
                        api_id = api_info['id']
                        api_url = api_info['api']['apiUrl']
                        api_ip = self.get_ip_from_api_url(api_url)
                        original_ip = api_info.get('original_ip', api_ip)
                        key_count = len(api_info['keys'])
                        
                        # İsimlendirme: api1 = Ana API, diğerleri = Yedek API
                        if api_id == 'api1':
                            display_name = f"Ana API ({original_ip})"
                        else:
                            display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                        
                        api_selection_text += f"<b>{idx}. {display_name}</b>\n"
                        api_selection_text += f"   🆔 ID: <code>{api_id}</code>\n"
                        api_selection_text += f"   📍 IP: <code>{api_ip}</code>\n"
                        api_selection_text += f"   🔑 Mevcut: {key_count} anahtar\n\n"
                    
                    api_selection_text += "✏️ <b>API ID'sini yazın:</b>\n"
                    api_selection_text += "Örnek: <code>api1</code>, <code>api2</code>"
                    
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(api_selection_text, parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data['state'] = 'waiting_api_selection_for_key'
                elif api_count == 1:
                    # Tek API var - Direkt isim sor
                    context.user_data['selected_api_for_key'] = self.config['outline_apis'][0]['id']
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text("✏️ <b>Anahtar İsmi</b>\n\nLütfen oluşturulacak anahtarlar için bir isim girin:\n\n📝 <b>Örnekler:</b>\n• ELMA\n• AHMET\n• VIP_USER\n• OZEL_ANAHTAR\n\n💡 <b>Not:</b> Bu isim anahtar URL'inde görünecek", parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data['state'] = 'waiting_key_name'
                else:
                    # API yoksa yalnızca YAML modunda devam et
                    if yaml_mode or self.config.get('connection_mode') == 'yaml':
                        context.user_data['selected_api_for_key'] = 'yaml'
                        keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                        reply_markup = InlineKeyboardMarkup(keyboard)
                        await query.edit_message_text("✏️ <b>Anahtar İsmi</b>\n\nLütfen oluşturulacak anahtarlar için bir isim girin:\n\n📝 <b>Örnekler:</b>\n• ELMA\n• AHMET\n• VIP_USER\n• OZEL_ANAHTAR\n\n💡 <b>Not:</b> Bu isim anahtar URL'inde görünecek", parse_mode='HTML', reply_markup=reply_markup)
                        context.user_data['state'] = 'waiting_key_name'
                    else:
                        await query.edit_message_text(
                            "❌ <b>Anahtar oluşturulamıyor!</b>\n\n"
                            "API bulunamadı ve varsayılan YAML da yüklenmemiş.\n"
                            "Önce API ekleyin veya YAML yükleyin.",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                
            elif data == "delete_key":
                logger.info("🗑️ Processing delete_key button")
                if not self.database['keys']:
                    logger.info("⚠️ No keys available for deletion")
                    await query.edit_message_text("❌ Silinecek anahtar yok!", reply_markup=self.get_back_to_menu_keyboard())
                    return
                
                logger.info(f"📋 Showing {len(self.database['keys'])} keys for deletion")
                
                # TXT formatında numaralı anahtar listesi oluştur ve dosya olarak gönder
                from datetime import datetime
                import os
                
                # TXT içeriği hazırla (aynı format kullanıcı listesi ile)
                txt_content = f"OUTLINE VPN - ANAHTAR SILME LISTESI\n"
                txt_content += f"=" * 50 + "\n\n"
                txt_content += f"SILME TALIMATLARI:\n"
                txt_content += f"- Tek anahtar silmek icin: Anahtar ID'yi bota yazin\n"
                txt_content += f"  Ornek: ELMA1, GITHUB2, VIP_USER3\n"
                txt_content += f"- TUM anahtarlari silmek icin: ALL yazin\n"
                txt_content += f"- Toplam Anahtar: {len(self.database['keys'])}\n"
                txt_content += f"- Olusturulma: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
                txt_content += f"ANAHTAR LISTESI:\n"
                txt_content += f"=" * 50 + "\n\n"
                
                # Anahtarları numaralı liste olarak ekle
                counter = 1
                changed_ports = 0
                for key_id, key_data in self.database['keys'].items():
                    try:
                        custom_id = self.get_custom_id(key_id)
                        created_time = datetime.fromtimestamp(key_data['created_at']).strftime('%Y-%m-%d %H:%M')
                        created_at = key_data['created_at']
                        duration_val = key_data['duration']
                        remaining = self.get_remaining_time(created_at, duration_val)
                        expired_status = "SURESI DOLMUS" if self.is_key_expired(created_at, duration_val) else "AKTIF"
                        expire_ts = self._compute_expire_time(created_at, duration_val)
                        expire_str = datetime.fromtimestamp(expire_ts).strftime('%Y-%m-%d %H:%M')

                        # Port gösterimi: kayıtlı port öncelikli, yoksa ss_url'den çıkar; uyumsuzsa düzelt
                        stored_port = self._to_int_port(key_data.get('port'))
                        parsed_port = self._extract_port_from_ss_url(key_data.get('ss_url', ''))
                        display_port = stored_port if stored_port is not None else parsed_port
                        if parsed_port and (stored_port is None or parsed_port != stored_port):
                            key_data['port'] = parsed_port
                            display_port = parsed_port
                            changed_ports += 1
                        
                        txt_content += f"{counter}. {custom_id}\n"
                        txt_content += f"   - Olusturma: {created_time}\n"
                        txt_content += f"   - Sure: {key_data.get('duration', 'Bilinmiyor')}\n"
                        txt_content += f"   - Kalan Sure: {remaining}\n"
                        txt_content += f"   - Bitis: {expire_str}\n"
                        txt_content += f"   - Port: {display_port if display_port is not None else 'Bilinmiyor'}\n"
                        txt_content += f"   - UDID: {key_data.get('udid', 'Yok')}\n"
                        txt_content += f"   - Istekler: {key_data.get('requests', 0)}\n"
                        txt_content += f"   - Durum: {expired_status}\n\n"
                        
                        counter += 1
                    except Exception as key_error:
                        logger.error(f"❌ Error processing key {key_id}: {key_error}")
                        continue

                # Eğer portlar düzeltildiyse kaydet ve used_ports'u senkronize et
                if changed_ports > 0:
                    self.save_database()
                    self._sync_used_ports_from_database()
                    logger.info(f"✅ delete_key listesinde {changed_ports} port düzeltildi ve kaydedildi")
                
                txt_content += f"=" * 50 + "\n"
                txt_content += f"Toplam Kullanici: {counter - 1}\n"
                txt_content += f"Silme Talimat: Anahtar ID yazarak silebilirsiniz\n"
                txt_content += f"Rapor Tarihi: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                
                # Geçici TXT dosyası oluştur
                temp_dir = "/tmp"
                txt_filename = "User_List.txt"  # Aynı dosya adı
                txt_filepath = os.path.join(temp_dir, txt_filename)
                
                try:
                    # Detaylı kontroller
                    logger.info(f"📁 Creating TXT file at: {txt_filepath}")
                    logger.info(f"📁 Temp directory exists: {os.path.exists(temp_dir)}")
                    logger.info(f"📁 Temp directory writable: {os.access(temp_dir, os.W_OK)}")
                    logger.info(f"📊 TXT content length: {len(txt_content)} characters")
                    
                    # TXT dosyasını yaz
                    with open(txt_filepath, 'w', encoding='utf-8') as f:
                        f.write(txt_content)
                    
                    # Dosya kontrolü
                    if not os.path.exists(txt_filepath):
                        raise FileNotFoundError(f"TXT file was not created: {txt_filepath}")
                    
                    file_size = os.path.getsize(txt_filepath)
                    logger.info(f"📊 TXT file created successfully: {file_size} bytes")
                    
                    # İlk mesaj
                    key_list = f"🗑️ <b>Anahtar Silme Menüsü</b>\n\n"
                    key_list += f"📊 <b>Toplam:</b> {len(self.database['keys'])} anahtar\n\n"
                    key_list += f"📄 Kullanıcı listesi hazırlanıyor..."
                    await query.edit_message_text(key_list, parse_mode='HTML')
                    
                    # Dosyayı Telegram'a gönder
                    logger.info("📤 Sending TXT file to Telegram...")
                    with open(txt_filepath, 'rb') as document:
                        await context.bot.send_document(
                            chat_id=query.message.chat_id,
                            document=document,
                            filename=txt_filename,
                            caption=f"🗑️ <b>Anahtar Silme - User_List.txt</b>\n\n"
                                   f"📊 Toplam: {len(self.database['keys'])} anahtar\n\n"
                                   f"✏️ <b>Silmek için Anahtar ID'yi yazın:</b>\n"
                                   f"• Tek anahtar: <code>ELMA123</code>, <code>VIP_USER456</code>\n"
                                   f"• Tüm anahtarlar: <code>ALL</code>\n\n"
                                   f"📋 <b>Dosya İçeriği:</b>\n"
                                   f"• Numaralı anahtar listesi (1. 2. 3. ...)\n"
                                   f"• Her anahtar için detaylı bilgiler\n"
                                   f"• Anahtar ID ve port bilgileri",
                            parse_mode='HTML'
                        )
                    
                    logger.info("✅ TXT file sent to Telegram successfully")
                    
                    # Dosyayı sil
                    os.remove(txt_filepath)
                    logger.info(f"📄 TXT file sent and deleted: {txt_filename}")
                    
                    # Son mesaj
                    final_text = f"🗑️ <b>Anahtar Silme Menüsü</b>\n\n"
                    final_text += f"✅ <b>User_List.txt dosyası gönderildi!</b>\n\n"
                    final_text += f"✏️ <b>Silmek için Anahtar ID'yi yazın:</b>\n"
                    final_text += f"• Tek anahtar: <code>ELMA123</code>, <code>VIP_USER456</code>\n"
                    final_text += f"• Tüm anahtarlar: <code>ALL</code>\n\n"
                    final_text += f"💡 <b>Not:</b> TXT dosyasında numaralı liste mevcut."
                    
                    await query.edit_message_text(final_text, parse_mode='HTML')
                    
                except Exception as e:
                    logger.error(f"❌ Error creating/sending TXT file: {e}")
                    logger.error(f"❌ Error type: {type(e).__name__}")
                    logger.error(f"❌ Error details: {str(e)}")
                    logger.error(f"❌ Traceback: {traceback.format_exc()}")
                    
                    key_list = f"🗑️ <b>Anahtar Silme Menüsü</b>\n\n"
                    key_list += f"❌ <b>TXT dosyası oluşturulurken hata:</b> {str(e)}\n"
                    key_list += f"🔍 <b>Hata tipi:</b> {type(e).__name__}\n\n"
                    
                    # Fallback: Basit Anahtar ID listesi
                    custom_list = []
                    for key_id, key_data in self.database['keys'].items():
                        try:
                            custom_id = self.get_custom_id(key_id)
                            custom_list.append(custom_id)
                        except:
                            continue
                    
                    key_list += f"📊 <b>Toplam:</b> {len(custom_list)} anahtar\n\n"
                    key_list += f"🔑 <b>Mevcut Anahtar ID'ler:</b>\n"
                    
                    # 20'şer gruplar halinde göster
                    for i in range(0, len(custom_list), 20):
                        chunk = custom_list[i:i+20]
                        key_list += f"<code>{', '.join(chunk)}</code>\n"
                    
                    key_list += f"\n✏️ <b>Silmek için Anahtar ID'yi yazın:</b>\n"
                    key_list += f"Örnek: <code>ELMA123</code>, <code>VIP_USER456</code>"
                    
                    await query.edit_message_text(key_list, parse_mode='HTML')
                
                context.user_data['state'] = 'waiting_key_delete'
            
            elif data == "important_info":
                # Önemli Bilgiler menüsü
                keyboard = [
                    [InlineKeyboardButton("📋 Kullanıcı Listesi", callback_data="user_list")],
                    [InlineKeyboardButton("🖥️ API Bilgileri", callback_data="api_info")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text("📊 <b>Önemli Bilgiler</b>\n\nSeçim yapın:", parse_mode='HTML', reply_markup=reply_markup)
            
            elif data == "api_info":
                # API Bilgileri
                try:
                    api_info_text = "🖥️ <b>API Bilgileri</b>\n\n"
                    
                    if not self.config['outline_apis']:
                        api_info_text += "❌ Hiç API bulunamadı!"
                    else:
                        # API'leri sırala: api1 önce, sonra diğerleri
                        sorted_apis = sorted(
                            self.config['outline_apis'],
                            key=lambda x: (x['id'] != 'api1', x['id'])
                        )
                        
                        for idx, api in enumerate(sorted_apis, 1):
                            api_id = api['id']
                            api_name = api['name']
                            api_url = api['api']['apiUrl']
                            original_ip = api.get('original_ip', self.get_ip_from_api_url(api_url))
                            key_count = len(api['keys'])
                            
                            # Güncel IP'yi tespit et (backup IP'den veya mevcut anahtarlardan)
                            current_ip = None
                            
                            # 1. Backup IP varsa onu kullan (en son eklenen)
                            backup_ips_for_api = [
                                (bid, binfo) for bid, binfo in self.database.get('backup_ips', {}).items() 
                                if binfo.get('api_id') == api_id
                            ]
                            
                            if backup_ips_for_api:
                                # En son eklenen backup IP'yi al
                                latest_backup = max(backup_ips_for_api, key=lambda x: x[1].get('created_at', 0))
                                current_ip = latest_backup[1]['ip']
                            
                            # 2. Backup IP yoksa, mevcut anahtarlardan IP çıkar
                            if not current_ip and api['keys']:
                                for existing_key_id in api['keys']:
                                    if existing_key_id in self.database['keys']:
                                        existing_ss_url = self.database['keys'][existing_key_id].get('ss_url', '')
                                        import re
                                        ipv4_match = re.search(r'@([\d\.]+):', existing_ss_url)
                                        if ipv4_match:
                                            current_ip = ipv4_match.group(1)
                                            break
                            
                            # 3. Hiçbir şey yoksa original IP kullan
                            if not current_ip:
                                current_ip = original_ip
                            
                            # İsimlendirme: api1 = Ana API, diğerleri = Yedek API
                            if api_id == 'api1':
                                display_name = f"Ana API"
                            else:
                                display_name = f"Yedek API - {api_id.upper()}"
                            
                            api_info_text += f"{'='*30}\n"
                            api_info_text += f"<b>{idx}. {display_name}</b>\n"
                            api_info_text += f"🆔 <b>ID:</b> <code>{api_id}</code>\n"
                            api_info_text += f"🔑 <b>Anahtar Sayısı:</b> {key_count}\n"
                            api_info_text += f"🔵 <b>Orijinal IP:</b> <code>{original_ip}</code> (Outline API)\n"
                            
                            # IP değişikliği kontrolü
                            if original_ip != current_ip:
                                api_info_text += f"🟢 <b>Mevcut IP:</b> <code>{current_ip}</code> (Client bağlantı)\n"
                                api_info_text += f"🔄 <b>Yönlendirme:</b> {current_ip} → {original_ip}\n"
                                api_info_text += f"📍 <i>Client'lar mevcut IP'den bağlanıyor, Outline API orijinal IP'de çalışıyor</i>\n"
                            else:
                                api_info_text += f"🟢 <b>Mevcut IP:</b> <code>{current_ip}</code>\n"
                                api_info_text += f"📍 <i>IP güncellemesi yapılmamış</i>\n"
                            
                            api_info_text += f"\n"
                    
                    api_info_text += f"{'='*30}\n"
                    api_info_text += f"📊 <b>Toplam API:</b> {len(self.config['outline_apis'])}"
                    
                    keyboard = [
                        [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    await query.edit_message_text(api_info_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                except Exception as e:
                    logger.error(f"❌ Error in api_info: {e}")
                    await query.edit_message_text(
                        "❌ API bilgileri yüklenirken hata oluştu!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "user_list":
                logger.info("📊 Processing user_list button")
                
                try:
                    # Güvenlik kontrolleri
                    if not hasattr(self, 'database') or not self.database:
                        await query.edit_message_text("❌ Veritabanı bulunamadı!", reply_markup=self.get_back_to_menu_keyboard())
                        return
                        
                    if 'stats' not in self.database:
                        self.database['stats'] = {"total_keys": 0, "requests": {}}
                        
                    if 'keys' not in self.database:
                        self.database['keys'] = {}
                    
                    stats = self.database['stats']
                    total_keys = stats.get('total_keys', 0)
                    active_keys = len([k for k, v in self.database['keys'].items() if not self.is_key_expired(v['created_at'], v['duration'])])
                    expired_keys = total_keys - active_keys
                    logger.info(f"📊 Stats: total={total_keys}, active={active_keys}, expired={expired_keys}")
                    
                    # Son 24 saat içinde aktif olan anahtarları say
                    recent_requests = 0
                    current_time = time.time()
                    for key_id, last_request in stats.get('requests', {}).items():
                        if current_time - last_request < 86400:  # 24 saat
                            recent_requests += 1
                    
                    text = f"📊 <b>Kullanıcı İstatistikleri</b>\n\n"
                    text += f"📈 <b>Genel Durum:</b>\n"
                    text += f"• Toplam Anahtar: <code>{total_keys}</code>\n"
                    text += f"• Aktif Anahtar: <code>{active_keys}</code>\n"
                    text += f"• Süresi Dolmuş: <code>{expired_keys}</code>\n"
                    text += f"• Son 24s Aktif: <code>{recent_requests}</code>\n\n"
                    
                    if self.database['keys']:
                        # TXT formatında numaralı anahtar listesi oluştur
                        from datetime import datetime
                        import os
                        
                        # TXT içeriği hazırla
                        txt_content = f"OUTLINE VPN - KULLANICI LISTESI\n"
                        txt_content += f"=" * 50 + "\n\n"
                        txt_content += f"ISTATISTIKLER:\n"
                        txt_content += f"- Toplam Anahtar: {total_keys}\n"
                        txt_content += f"- Aktif Anahtar: {active_keys}\n"
                        txt_content += f"- Suresi Dolmus: {expired_keys}\n"
                        txt_content += f"- Son 24s Aktif: {recent_requests}\n"
                        txt_content += f"- Olusturulma: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
                        txt_content += f"ANAHTAR LISTESI:\n"
                        txt_content += f"=" * 50 + "\n\n"
                        
                        # Anahtarları numaralı liste olarak ekle
                        counter = 1
                        changed_ports = 0
                        for key_id, key_data in self.database['keys'].items():
                            try:
                                custom_id = self.get_custom_id(key_id)
                                created_time = datetime.fromtimestamp(key_data['created_at']).strftime('%Y-%m-%d %H:%M')
                                created_at = key_data['created_at']
                                duration_val = key_data['duration']
                                remaining = self.get_remaining_time(created_at, duration_val)
                                expired_status = "SURESI DOLMUS" if self.is_key_expired(created_at, duration_val) else "AKTIF"
                                expire_ts = self._compute_expire_time(created_at, duration_val)
                                expire_str = datetime.fromtimestamp(expire_ts).strftime('%Y-%m-%d %H:%M')

                                # Port gösterimi: kayıtlı port öncelikli, yoksa ss_url'den çıkar; uyumsuzsa düzelt
                                stored_port = self._to_int_port(key_data.get('port'))
                                parsed_port = self._extract_port_from_ss_url(key_data.get('ss_url', ''))
                                display_port = stored_port if stored_port is not None else parsed_port
                                if parsed_port and (stored_port is None or parsed_port != stored_port):
                                    key_data['port'] = parsed_port
                                    display_port = parsed_port
                                    changed_ports += 1
                                
                                # API bilgisini al
                                api_id = key_data.get('api_id', 'Bilinmiyor')
                                api_name = 'Bilinmiyor'
                                if api_id != 'Bilinmiyor':
                                    api_info = self.get_api_by_id(api_id)
                                    if api_info:
                                        api_name = api_info['name']
                                
                                txt_content += f"{counter}. {custom_id}\n"
                                txt_content += f"   - API: {api_name} ({api_id})\n"
                                txt_content += f"   - Olusturma: {created_time}\n"
                                txt_content += f"   - Sure: {key_data.get('duration', 'Bilinmiyor')}\n"
                                txt_content += f"   - Kalan Sure: {remaining}\n"
                                txt_content += f"   - Bitis: {expire_str}\n"
                                txt_content += f"   - Port: {display_port if display_port is not None else 'Bilinmiyor'}\n"
                                txt_content += f"   - Istekler: {key_data.get('requests', 0)}\n"
                                txt_content += f"   - Durum: {expired_status}\n\n"
                                
                                counter += 1
                            except Exception as key_error:
                                logger.error(f"❌ Error processing key {key_id}: {key_error}")
                                continue

                        # Port düzeltmeleri yapıldıysa kaydet ve used_ports'u senkronize et
                        if changed_ports > 0:
                            self.save_database()
                            self._sync_used_ports_from_database()
                            logger.info(f"✅ user_list raporunda {changed_ports} port düzeltildi ve kaydedildi")
                        
                        txt_content += f"=" * 50 + "\n"
                        txt_content += f"Toplam Kullanici: {counter - 1}\n"
                        txt_content += f"Rapor Tarihi: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                        
                        # Geçici TXT dosyası oluştur
                        temp_dir = "/tmp"
                        txt_filename = "User_List.txt"
                        txt_filepath = os.path.join(temp_dir, txt_filename)
                        
                        try:
                            # Detaylı kontroller
                            logger.info(f"📁 Creating TXT file at: {txt_filepath}")
                            logger.info(f"📁 Temp directory exists: {os.path.exists(temp_dir)}")
                            logger.info(f"📁 Temp directory writable: {os.access(temp_dir, os.W_OK)}")
                            logger.info(f"📊 TXT content length: {len(txt_content)} characters")
                            
                            # TXT dosyasını yaz
                            with open(txt_filepath, 'w', encoding='utf-8') as f:
                                f.write(txt_content)
                            
                            # Dosya kontrolü
                            if not os.path.exists(txt_filepath):
                                raise FileNotFoundError(f"TXT file was not created: {txt_filepath}")
                            
                            file_size = os.path.getsize(txt_filepath)
                            logger.info(f"📊 TXT file created successfully: {file_size} bytes")
                            
                            # Dosyayı Telegram'a gönder
                            await query.edit_message_text(text + "📄 Kullanıcı listesi hazırlanıyor...")
                            
                            logger.info("📤 Sending TXT file to Telegram...")
                            with open(txt_filepath, 'rb') as document:
                                await context.bot.send_document(
                                    chat_id=query.message.chat_id,
                                    document=document,
                                    filename=txt_filename,
                                    caption=f"📊 <b>Kullanıcı Listesi TXT Dosyası</b>\n\n"
                                           f"• Toplam: {total_keys} anahtar\n"
                                           f"• Aktif: {active_keys} anahtar\n" 
                                           f"• Süresi Dolmuş: {expired_keys} anahtar\n"
                                           f"• Oluşturulma: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
                                    parse_mode='HTML'
                                )
                            
                            logger.info("✅ TXT file sent to Telegram successfully")
                            
                            # Dosyayı sil
                            os.remove(txt_filepath)
                            logger.info(f"📄 TXT file sent and deleted: {txt_filename}")
                            
                            # Başarı mesajı
                            text += f"\n✅ <b>User_List.txt dosyası başarıyla gönderildi!</b>\n"
                            text += f"📋 <b>İçerik:</b>\n"
                            text += f"• Numaralı anahtar listesi (1. 2. 3. ...)\n"
                            text += f"• Her anahtar için detaylı bilgiler\n"
                            text += f"• İstatistik özeti\n"
                            text += f"• Anahtar ID ve port bilgileri"
                            
                        except Exception as e:
                            logger.error(f"❌ Error creating/sending TXT file: {e}")
                            logger.error(f"❌ Error type: {type(e).__name__}")
                            logger.error(f"❌ Error details: {str(e)}")
                            logger.error(f"❌ Traceback: {traceback.format_exc()}")
                            
                            # Hata durumunda basit liste göster
                            text += f"\n❌ <b>TXT dosyası oluşturulamadı:</b> {str(e)}\n"
                            text += f"🔍 <b>Hata tipi:</b> {type(e).__name__}\n\n"
                            
                            # Fallback: Anahtar ID listesi
                            custom_list = []
                            for key_id, key_data in self.database['keys'].items():
                                try:
                                    custom_id = self.get_custom_id(key_id)
                                    custom_list.append(custom_id)
                                except:
                                    continue
                            
                            if custom_list:
                                text += f"🔑 <b>Anahtar ID Listesi:</b>\n"
                                # 15'er gruplar halinde göster
                                for i in range(0, len(custom_list), 15):
                                    chunk = custom_list[i:i+15]
                                    text += f"<code>{', '.join(chunk)}</code>\n"
                                
                                text += f"\n💡 <b>Not:</b> Detaylı bilgi için tekrar deneyin."
                            else:
                                text += f"❌ <b>Anahtar ID listesi oluşturulamadı</b>"
                    else:
                        text += "❌ Henüz anahtar bulunmuyor."
                    
                    reply_markup = self.get_back_to_menu_keyboard()
                    await query.edit_message_text(text, parse_mode='HTML', reply_markup=reply_markup)
                    
                except Exception as e:
                    logger.error(f"❌ Error in user_list handler: {e}")
                    error_text = f"❌ <b>Kullanıcı listesi yüklenirken hata oluştu:</b>\n\n"
                    error_text += f"<code>{str(e)}</code>\n\n"
                    error_text += f"🔄 Lütfen tekrar deneyin veya geliştirici ile iletişime geçin."
                    reply_markup = self.get_back_to_menu_keyboard()
                    await query.edit_message_text(error_text, parse_mode='HTML', reply_markup=reply_markup)
                
            elif data == "advanced":
                keyboard = [
                    [InlineKeyboardButton(self.get_text("refresh_api"), callback_data="refresh_api")],
                    [InlineKeyboardButton("🔄 IP Adresi Güncelle", callback_data="update_ip")],
                    [InlineKeyboardButton("🔑 Master Key ile Güncelle", callback_data="update_with_key")],
                    [InlineKeyboardButton("📄 Yaml Ekle", callback_data="add_yaml")],
                    [InlineKeyboardButton("✏️ Yaml Düzenle", callback_data="edit_yaml_endpoint")],
                    [InlineKeyboardButton("📦 Yedek API", callback_data="backup_api_menu")],
                    [InlineKeyboardButton("🌐 Yedek IP", callback_data="backup_ip_menu")],
                    [InlineKeyboardButton("🔀 Anahtar Taşı", callback_data="move_keys")],
                    [InlineKeyboardButton("👥 Adminleri Düzenle", callback_data="manage_admins")],
                    [InlineKeyboardButton("🔧 Anahtarları Onar", callback_data="fix_keys")],
                    [InlineKeyboardButton(self.get_text("contact"), callback_data="contact")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text("⚙️ Gelişmiş Seçenekler", reply_markup=reply_markup)

            elif data == "add_yaml":
                yaml_text = (
                    "📄 <b>Yaml Ekle</b>\n\n"
                    "📝 <b>Lütfen .yaml veya .yml dosyasını gönderin.</b>\n\n"
                    "✅ Bu dosya:\n"
                    "• Mevcut tüm anahtarlara eklenecek\n"
                    "• Bundan sonra oluşturulacak tüm yeni anahtarlara otomatik uygulanacak\n\n"
                    "⚠️ Not: Yaml dosyası metin olarak saklanır ve abonelik linkinden döndürülür."
                )
                keyboard = [[InlineKeyboardButton("❌ İptal", callback_data="yaml_upload_cancel")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(yaml_text, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data['state'] = 'waiting_yaml_upload'

            elif data == "edit_yaml_endpoint":
                default_yaml = (self.config.get('default_yaml_content') or '').strip()
                if not default_yaml:
                    for key_data in self.database.get('keys', {}).values():
                        key_yaml = (key_data.get('yaml_content') or '').strip()
                        if key_yaml:
                            default_yaml = key_yaml
                            break

                if not default_yaml:
                    await query.edit_message_text(
                        "❌ <b>Düzenlenecek YAML bulunamadı!</b>\n\n"
                        "Önce <b>Yaml Ekle</b> ile bir YAML dosyası yükleyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return

                endpoint_hosts = self.extract_yaml_endpoint_hosts(default_yaml)
                current_endpoint_ip = self.extract_yaml_endpoint_host(default_yaml)
                if not current_endpoint_ip:
                    await query.edit_message_text(
                        "❌ <b>YAML endpoint adresi okunamadı!</b>\n\n"
                        "Muhtemel nedenler:\n"
                        "• endpoint satırı yok\n"
                        "• endpoint değeri placeholder (örn: <code>$type</code>)\n"
                        "• endpoint gerçek host/IP içermiyor\n\n"
                        "Geçerli örnek:\n"
                        "<code>endpoint: 1.2.3.4:443</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return

                context.user_data['state'] = 'waiting_yaml_endpoint_ip'
                context.user_data['old_yaml_endpoint_ip'] = current_endpoint_ip

                endpoint_info_text = f"🔵 <b>Mevcut Endpoint IP:</b> <code>{current_endpoint_ip}</code>\n"
                if len(endpoint_hosts) > 1:
                    endpoint_info_text += "\n📋 <b>YAML içinde bulunan endpointler:</b>\n"
                    for host in endpoint_hosts:
                        endpoint_info_text += f"• <code>{host}</code>\n"

                await query.edit_message_text(
                    "✏️ <b>YAML Endpoint Düzenle</b>\n\n"
                    f"{endpoint_info_text}\n"
                    "📝 <b>Yeni endpoint IP adresini girin:</b>\n"
                    "• IPv4: <code>123.45.67.89</code>\n"
                    "• IPv6: <code>2001:db8::1</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )

            elif data == "yaml_upload_cancel":
                context.user_data.clear()
                keyboard = [
                    [InlineKeyboardButton(self.get_text("refresh_api"), callback_data="refresh_api")],
                    [InlineKeyboardButton("🔄 IP Adresi Güncelle", callback_data="update_ip")],
                    [InlineKeyboardButton("🔑 Master Key ile Güncelle", callback_data="update_with_key")],
                    [InlineKeyboardButton("📄 Yaml Ekle", callback_data="add_yaml")],
                    [InlineKeyboardButton("✏️ Yaml Düzenle", callback_data="edit_yaml_endpoint")],
                    [InlineKeyboardButton("📦 Yedek API", callback_data="backup_api_menu")],
                    [InlineKeyboardButton("🌐 Yedek IP", callback_data="backup_ip_menu")],
                    [InlineKeyboardButton("🔀 Anahtar Taşı", callback_data="move_keys")],
                    [InlineKeyboardButton("👥 Adminleri Düzenle", callback_data="manage_admins")],
                    [InlineKeyboardButton("🔧 Anahtarları Onar", callback_data="fix_keys")],
                    [InlineKeyboardButton(self.get_text("contact"), callback_data="contact")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text("⚙️ Gelişmiş Seçenekler", reply_markup=reply_markup)
                
            elif data == "backup_api_menu":
                keyboard = [
                    [InlineKeyboardButton("➕ Yeni API Ekle", callback_data="add_new_api")],
                    [InlineKeyboardButton("🗑️ API Sil", callback_data="delete_api")],
                    [InlineKeyboardButton("⚙️ Gelişmiş Seçenekler", callback_data="advanced")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text("📦 <b>Yedek API Yönetimi</b>\n\nYedek API ekleyebilir veya mevcut API'leri silebilirsiniz.", parse_mode='HTML', reply_markup=reply_markup)
                
            elif data == "backup_ip_menu":
                keyboard = [
                    [InlineKeyboardButton("➕ IP Ekle", callback_data="add_backup_ip")],
                    [InlineKeyboardButton("🗑️ IP Sil", callback_data="delete_backup_ip")],
                    [InlineKeyboardButton("📋 IP Listesi", callback_data="list_backup_ips")],
                    [InlineKeyboardButton("⚙️ Gelişmiş Seçenekler", callback_data="advanced")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text("🌐 <b>Yedek IP Yönetimi</b>\n\nYedek IP adresleri ekleyebilir, silebilir ve listeleyebilirsiniz.", parse_mode='HTML', reply_markup=reply_markup)
                
            elif data == "backup_menu":
                keyboard = [
                    [InlineKeyboardButton("💾 Yedek Oluştur", callback_data="create_full_backup")],
                    [InlineKeyboardButton("♻️ Yedek Dosyası Gönder", callback_data="send_backup_file")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                backup_text = (
                    f"💾 <b>Yedekleme Sistemi</b>\n\n"
                    f"💡 <b>Özellikler:</b>\n"
                    f"• Manuel yedek oluşturma\n"
                    f"• Otomatik yedekleme (6 saatte bir)\n"
                    f"• Telegram'a otomatik gönderim\n"
                    f"• Sunucudan otomatik temizlik\n\n"
                    f"🔄 <b>Geri Yükleme:</b>\n"
                    f"• Telegram'dan yedek dosyasını bota gönderin\n"
                    f"• Bot otomatik olarak geri yükleyecek\n\n"
                    f"✅ Tüm verileriniz güvende!"
                )
                
                await query.edit_message_text(backup_text, parse_mode='HTML', reply_markup=reply_markup)
                
            elif data == "send_backup_file":
                # Yedek dosyası gönderme talimatı
                instruction_text = (
                    f"♻️ <b>Yedek Geri Yükleme</b>\n\n"
                    f"📝 <b>Nasıl Çalışır:</b>\n"
                    f"1️⃣ Telegram'daki yedek dosyanızı bulun\n"
                    f"2️⃣ Dosyayı bu sohbete gönderin\n"
                    f"3️⃣ Bot otomatik olarak geri yükleyecek\n\n"
                    f"⚠️ <b>Uyarı:</b>\n"
                    f"• Sadece <code>backup_*.json</code> dosyaları kabul edilir\n"
                    f"• Mevcut veriler yedeğe alınacak\n"
                    f"• Geri yükleme işlemi geri alınamaz\n\n"
                    f"📄 Şimdi yedek dosyanızı gönderin:"
                )
                await query.edit_message_text(instruction_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
            
            elif data == "restore_with_backup_api":
                # Backup'daki API'leri kullanarak geri yükle
                try:
                    import os
                    import shutil
                    
                    backup_path = context.user_data.get('backup_path')
                    backup_data = context.user_data.get('backup_data')
                    filename = context.user_data.get('backup_filename')
                    
                    if not backup_path or not backup_data:
                        await query.edit_message_text(
                            "❌ <b>Yedek bilgisi bulunamadı!</b>\n\nLütfen tekrar yedek dosyasını gönderin.",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    await query.edit_message_text("⏳ <b>Yedek geri yükleniyor...</b>", parse_mode='HTML')
                    
                    # Mevcut veritabanını yedekle (güvenlik için, varsa)
                    current_backup_path = f"{self.config['database']['path']}.before_restore.{int(time.time())}"
                    if os.path.exists(self.config['database']['path']):
                        shutil.copy(self.config['database']['path'], current_backup_path)
                    
                    # Veritabanını geri yükle
                    self.database = backup_data['database']
                    self.save_database()
                    self._sync_used_ports_from_database()
                    
                    # Config'i geri yükle (API'ler)
                    if 'outline_apis' in backup_data['config']:
                        self.config['outline_apis'] = backup_data['config']['outline_apis']
                        self.set_connection_mode('api')
                    
                    # ÖNEMLİ: API'deki mevcut anahtarları temizle ve yeniden oluştur
                    await query.edit_message_text("🧹 <b>API temizleniyor ve anahtarlar yeniden oluşturuluyor...</b>", parse_mode='HTML')
                    update_result = await self.update_keys_with_new_api()

                    # API moduna geçişte tüm anahtarların YAML override'ını temizle
                    for key_id in self.database.get('keys', {}):
                        self.database['keys'][key_id]['yaml_content'] = None
                    self.save_database()
                    
                    # İndirilen dosyayı sil
                    os.remove(backup_path)
                    
                    # Context'i temizle
                    context.user_data.clear()
                    
                    # İstatistikler
                    restored_keys = len(backup_data['database']['keys'])
                    restored_apis = len(backup_data['config']['outline_apis'])
                    restored_backup_ips = len(backup_data['database'].get('backup_ips', {}))
                    
                    # Süre bilgisi
                    duration_info = ""
                    if 'duration' in update_result and update_result['duration'] > 60:
                        duration_info = f"\n⏱️ <b>İşlem Süresi:</b> {update_result['duration']} saniye"
                    
                    current_port = self.config.get('outline_port', 444)
                    result_text = (
                        f"✅ <b>Yedek Başarıyla Geri Yüklendi!</b>\n\n"
                        f"📁 <b>Dosya:</b> <code>{filename}</code>\n"
                        f"🕐 <b>Yedek Tarihi:</b> {backup_data.get('created_at', 'Bilinmeyen')}\n\n"
                        f"♻️ <b>Geri Yüklenen Veriler:</b>\n"
                        f"• Anahtarlar: <code>{restored_keys}</code> adet\n"
                        f"• API'ler: <code>{restored_apis}</code> adet\n"
                        f"• Yedek IP'ler: <code>{restored_backup_ips}</code> adet\n\n"
                        f"🔨 <b>API Yenileme:</b>\n"
                        f"• Temizlenen: <code>{update_result.get('cleaned', 0)}</code> anahtar\n"
                        f"• Yeniden oluşturulan: <code>{update_result.get('created', 0)}</code> anahtar"
                        f"{duration_info}\n\n"
                        f"🔒 <b>Güvenlik:</b>\n"
                        + (f"Eski veritabanı yedeklendi:\n<code>{current_backup_path}</code>\n\n" if os.path.exists(current_backup_path) else "Temiz kurulum — önceki veritabanı yok.\n\n")
                        + f"✅ Tüm anahtarlara YENİ benzersiz portlar atandı (<code>444-999</code> arası)!"
                    )
                    
                    logger.info(f"✅ Backup restored with backup APIs: {filename} ({restored_keys} keys, {restored_apis} APIs, {update_result.get('created', 0)} recreated)")
                    await query.edit_message_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    
                except Exception as e:
                    logger.error(f"❌ Error restoring with backup API: {e}")
                    import traceback
                    logger.error(traceback.format_exc())
                    await query.edit_message_text(
                        f"❌ <b>Yedek geri yüklenirken hata!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
            
            elif data == "restore_with_new_api":
                # Yeni API ekle sonra geri yükle
                await query.edit_message_text(
                    "➕ <b>Yeni API Ekle</b>\n\n"
                    "📝 <b>API bilgisini girin:</b>\n\n"
                    "✅ <b>2 Format Desteklenir:</b>\n\n"
                    "<b>1. JSON Format (Önerilen):</b>\n"
                    "<code>{\"apiUrl\":\"https://11.22.33.44:12345/abc\",\"certSha256\":\"ABC123...\"}</code>\n\n"
                    "<b>2. Sadece URL:</b>\n"
                    "<code>https://11.22.33.44:12345/abc123def456</code>\n\n"
                    "💡 JSON formatında certSha256 otomatik kullanılır.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data['state'] = 'waiting_new_api_for_restore'

            elif data == "restore_with_yaml_file":
                # YAML ile geri yükleme: backup yüklendi, şimdi YAML dosyası bekle
                context.user_data['state'] = 'waiting_restore_yaml_upload'
                await query.edit_message_text(
                    "📄 <b>YAML ile Yedek Geri Yükleme</b>\n\n"
                    "📝 <b>Adım 2/2:</b> Lütfen <code>.yaml</code> veya <code>.yml</code> dosyasını gönderin.\n\n"
                    "Bu işlem:\n"
                    "• Yedek veritabanını geri yükler\n"
                    "• Tüm anahtarlara aynı YAML içeriğini uygular\n"
                    "• Botu YAML moduna alır (API zorunlu olmaz)",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            elif data == "cancel_restore":
                # Geri yüklemeyi iptal et
                try:
                    import os
                    backup_path = context.user_data.get('backup_path')
                    if backup_path and os.path.exists(backup_path):
                        os.remove(backup_path)
                    context.user_data.clear()
                    await query.edit_message_text(
                        "❌ <b>Yedek geri yükleme iptal edildi.</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                except Exception as e:
                    logger.error(f"Error canceling restore: {e}")
                    await query.edit_message_text(
                        "❌ İptal edildi.",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "create_full_backup":
                # Manuel yedek oluştur ve Telegram'a gönder
                try:
                    import os
                    import json
                    from datetime import datetime
                    
                    await query.edit_message_text("💾 <b>Yedek oluşturuluyor...</b>", parse_mode='HTML')
                    
                    # Yedek dizini oluştur
                    backup_dir = "/opt/outline-telegram-bot/backups"
                    os.makedirs(backup_dir, exist_ok=True)
                    
                    # Yedek dosya adı (timestamp ile)
                    timestamp = int(time.time())
                    backup_filename = f"backup_{timestamp}.json"
                    backup_path = os.path.join(backup_dir, backup_filename)
                    
                    # Tam veritabanını yedekle
                    backup_data = {
                        'timestamp': timestamp,
                        'created_at': datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S'),
                        'database': self.database,
                        'config': {
                            'outline_apis': self.config['outline_apis'],
                            'language': self.config.get('language', 'TR')
                        }
                    }
                    
                    # JSON olarak kaydet
                    with open(backup_path, 'w') as f:
                        json.dump(backup_data, f, indent=2)
                    
                    # Dosya boyutu
                    file_size = os.path.getsize(backup_path) / 1024  # KB
                    
                    # Telegram'a dosyayı gönder
                    caption = (
                        f"💾 <b>Manuel Yedek</b>\n\n"
                        f"🕐 <b>Tarih:</b> {datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')}\n"
                        f"📊 <b>Boyut:</b> {file_size:.2f} KB\n\n"
                        f"💾 <b>İçerik:</b>\n"
                        f"• Anahtarlar: {len(self.database['keys'])} adet\n"
                        f"• API'ler: {len(self.config['outline_apis'])} adet\n"
                        f"• Yedek IP'ler: {len(self.database.get('backup_ips', {}))} adet"
                    )
                    
                    # Developer'a gönder
                    developer_id = int(self.config['developer_id'])
                    
                    with open(backup_path, 'rb') as f:
                        await query.message.reply_document(
                            document=f,
                            filename=backup_filename,
                            caption=caption,
                            parse_mode='HTML'
                        )
                    
                    # Sunucudan sil
                    os.remove(backup_path)
                    
                    # Başarı mesajı
                    result_text = (
                        f"✅ <b>Yedek Oluşturuldu ve Gönderildi!</b>\n\n"
                        f"📁 <b>Dosya:</b> <code>{backup_filename}</code>\n"
                        f"📊 <b>Boyut:</b> <code>{file_size:.2f} KB</code>\n"
                        f"🕐 <b>Tarih:</b> {datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')}\n\n"
                        f"💾 <b>Yedeklenen Veriler:</b>\n"
                        f"• Anahtarlar: <code>{len(self.database['keys'])}</code> adet\n"
                        f"• API'ler: <code>{len(self.config['outline_apis'])}</code> adet\n"
                        f"• Yedek IP'ler: <code>{len(self.database.get('backup_ips', {}))}</code> adet\n\n"
                        f"📤 Yedek Telegram'a gönderildi\n"
                        f"🗑️ Sunucudan silindi"
                    )
                    
                    logger.info(f"✅ Manual backup created and sent: {backup_filename}")
                    await query.edit_message_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    
                except Exception as e:
                    logger.error(f"❌ Manual backup error: {e}")
                    await query.edit_message_text(
                        f"❌ <b>Yedek oluşturulurken hata!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "update_with_key":
                # Master key ile güncelleme - bilgilendirme mesajı
                info_text = (
                    "🔑 <b>Master Key ile Güncelle</b>\n\n"
                    "⚠️ <b>Önemli Bilgilendirme:</b>\n\n"
                    "Desteklenen <b>3 tane anahtar formatı</b> geliştiriciden sorun ve "
                    "o anahtar ile güncelleme yapın, aksi takdirde anahtarlar çalışmayabilir.\n\n"
                    "📋 <b>Desteklenen Formatlar:</b>\n\n"
                    "<b>1. Tam URL Formatı:</b>\n"
                    "<code>ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNToxZVZmZVhuSXJHZHQ2bWtKcHVqbjh0QDIxNy4yOC4xMzcuMjEwOjM3NTgz</code>\n\n"
                    "<b>2. Outline Formatı:</b>\n"
                    "<code>ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpzOVRoaVdaOG4wZ3VqeXpYZTdIWnIx@0.0.0.0:port/?outline=1</code>\n\n"
                    "<b>3. Standart Format:</b>\n"
                    "<code>ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpTejExTUREMm9UT3ZOR1IwOEhRa204@0.0.0.0:port</code>\n\n"
                    "🔐 <b>Şifreleme:</b> chacha20-ietf-poly1305\n\n"
                    "💡 <b>Not:</b> Girilen master key, bottaki <b>TÜM ABONELİK LİNKLERİNDEKİ</b> "
                    "ss:// anahtarların <b>TAMAMINI</b> (IP, port, şifre dahil her şeyi) değiştirecektir.\n\n"
                    "❓ <b>Devam etmek istiyor musunuz?</b>"
                )
                
                keyboard = [
                    [InlineKeyboardButton("✅ Devam", callback_data="update_key_continue")],
                    [InlineKeyboardButton("❌ İptal", callback_data="update_key_cancel")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(info_text, parse_mode='HTML', reply_markup=reply_markup)
            
            elif data == "update_key_continue":
                # Devam - anahtar iste
                request_text = (
                    "🔑 <b>Yeni Anahtar Girin</b>\n\n"
                    "📝 <b>Lütfen yeni ss:// anahtarını gönderin:</b>\n\n"
                    "✅ <b>Kabul Edilen Formatlar:</b>\n\n"
                    "• <code>ss://Y2hhY2hhMjA...@IP:PORT</code>\n"
                    "• <code>ss://Y2hhY2hhMjA...@IP:PORT/?outline=1</code>\n\n"
                    "🔐 Şifreleme: <code>chacha20-ietf-poly1305</code>\n\n"
                    "💬 Anahtarı mesaj olarak yazın:"
                )
                
                keyboard = [[InlineKeyboardButton("❌ İptal", callback_data="update_key_cancel")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(request_text, parse_mode='HTML', reply_markup=reply_markup)
                
                # State'i kaydet
                context.user_data['state'] = 'waiting_new_key_input'
            
            elif data == "update_key_cancel":
                # İptal - ana menüye dön
                context.user_data.clear()
                await self.show_main_menu_callback(update, context)
            
            elif data == "confirm_key_update":
                # Anahtar güncellemeyi onayla ve uygula
                try:
                    new_ss_key = context.user_data.get('new_ss_key')
                    
                    if not new_ss_key:
                        await query.edit_message_text(
                            "❌ <b>Anahtar bilgisi bulunamadı!</b>\n\nLütfen tekrar deneyin.",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        context.user_data.clear()
                        return
                    
                    await query.edit_message_text(
                        "🔄 <b>Tüm anahtarlar güncelleniyor...</b>\n\n"
                        "⏳ Bu işlem biraz zaman alabilir.",
                        parse_mode='HTML'
                    )
                    
                    # Tüm anahtarları yeni ss:// anahtarıyla TAMAMEN değiştir
                    updated_count = 0
                    failed_count = 0
                    
                    for key_id, key_data in self.database['keys'].items():
                        try:
                            # Yeni ss:// anahtarını AYNEN kullan (hiç değiştirmeden)
                            self.database['keys'][key_id]['ss_url'] = new_ss_key
                            updated_count += 1
                            
                            if updated_count % 50 == 0:
                                logger.info(f"✅ Progress: {updated_count}/{len(self.database['keys'])} keys updated")
                        
                        except Exception as e:
                            logger.error(f"❌ Error updating key {key_id}: {e}")
                            failed_count += 1
                            continue
                    
                    # Database'i kaydet
                    self.save_database()
                    
                    # Master anahtarı config'e kaydet
                    self.config['master_ss_key'] = new_ss_key
                    
                    # Master key'in ORIGINAL IP:PORT'unu kaydet (ilk eklendiğinde)
                    if 'master_original_ip_port' not in self.config:
                        # İlk kez master key ekleniyor - orjinal IP:PORT'u parse et
                        import re, base64
                        original_ip = None
                        original_port = None
                        
                        if '@' in new_ss_key:
                            # Format: ss://BASE64@IP:PORT
                            match = re.search(r'@([\d\.]+):(\d+)', new_ss_key)
                            if match:
                                original_ip = match.group(1)
                                original_port = int(match.group(2))
                        else:
                            # Format: ss://BASE64 (IP Base64 içinde)
                            try:
                                key_part = new_ss_key[5:]
                                decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
                                match = re.search(r'@([\d\.]+):(\d+)', decoded)
                                if match:
                                    original_ip = match.group(1)
                                    original_port = int(match.group(2))
                            except:
                                pass
                        
                        if original_ip and original_port:
                            self.config['master_original_ip_port'] = {
                                'ip': original_ip,
                                'port': original_port
                            }
                            logger.info(f"✅ Master key ORIGINAL IP:PORT saved: {original_ip}:{original_port}")
                        else:
                            logger.warning(f"⚠️ Could not parse ORIGINAL IP:PORT from master key")
                    
                    self.save_config()
                    logger.info(f"✅ Master ss:// key saved to config: {new_ss_key[:50]}...")
                    
                    # Sonuç mesajı
                    preview_key = new_ss_key[:60] + '...' if len(new_ss_key) > 60 else new_ss_key
                    result_text = (
                        f"✅ <b>Anahtar Güncelleme Tamamlandı!</b>\n\n"
                        f"📊 <b>İstatistikler:</b>\n"
                        f"• ✅ Güncellenen: <code>{updated_count}</code> anahtar\n"
                        f"• ❌ Başarısız: <code>{failed_count}</code> anahtar\n"
                        f"• 📦 Toplam: <code>{len(self.database['keys'])}</code> anahtar\n\n"
                        f"🔑 <b>Yeni Anahtar:</b>\n"
                        f"<code>{preview_key}</code>\n\n"
                        f"✨ <b>Tüm abonelik linklerindeki ss:// anahtarlar TAMAMEN yeni anahtar ile değiştirildi!</b>\n"
                        f"📍 <b>Not:</b> Tüm anahtarlar artık aynı ss:// anahtarını kullanıyor.\n\n"
                        f"🔮 <b>Master Anahtar Modu:</b>\n"
                        f"✅ Bundan sonra oluşturulacak TÜM yeni anahtarlar bu ss:// anahtarını kullanacak!\n"
                        f"💡 Outline API'den yeni anahtar alınmayacak."
                    )
                    
                    logger.info(f"✅ Key update completed: {updated_count} keys updated with new ss:// key, {failed_count} failed")
                    await query.edit_message_text(
                        result_text,
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    
                    context.user_data.clear()
                    
                except Exception as e:
                    logger.error(f"❌ Error in confirm_key_update: {e}")
                    import traceback
                    logger.error(traceback.format_exc())
                    await query.edit_message_text(
                        f"❌ <b>Anahtar güncelleme hatası!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
            
            elif data == "contact":
                reply_markup = self.get_back_to_menu_keyboard()
                await query.edit_message_text("📞 İletişim: https://t.me/prime_mumia", reply_markup=reply_markup)
                
            elif data == "add_backup_ip":
                # Yedek IP ekleme - önce API seç
                api_list_text = "➕ <b>Yedek IP Ekle</b>\n\n"
                api_list_text += "📋 <b>Hangi API'ye yedek IP eklemek istiyorsunuz?</b>\n\n"
                
                if not self.config['outline_apis']:
                    await query.edit_message_text(
                        "❌ <b>API bulunamadı!</b>\n\n"
                        "Önce en az bir API eklemelisiniz.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # API'leri listele
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                for idx, api_info in enumerate(sorted_apis, 1):
                    api_id = api_info['id']
                    api_name = api_info.get('name', f'API {api_id}')
                    original_ip = api_info.get('original_ip', 'Bilinmiyor')
                    
                    api_list_text += f"<b>{idx}. {api_name}</b>\n"
                    api_list_text += f"   • ID: <code>{api_id}</code>\n"
                    api_list_text += f"   • IP: <code>{original_ip}</code>\n\n"
                
                api_list_text += "✏️ <b>API ID'sini yazın:</b>\n"
                api_list_text += "Örnek: <code>api1</code>, <code>api2</code>"
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await query.edit_message_text(api_list_text, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data['state'] = 'waiting_api_for_backup_ip'
                
            elif data == "restore_backup":
                # Geri yükleme için yedek seç
                try:
                    import os
                    
                    backup_dir = "/opt/outline-telegram-bot/backups"
                    
                    if not os.path.exists(backup_dir):
                        await query.edit_message_text(
                            "♻️ <b>Yedek Geri Yükle</b>\n\n"
                            "❌ Yedek bulunamadı!",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    backups = [f for f in os.listdir(backup_dir) if f.startswith('backup_') and f.endswith('.json')]
                    
                    if not backups:
                        await query.edit_message_text(
                            "♻️ <b>Yedek Geri Yükle</b>\n\n"
                            "❌ Yedek bulunamadı!",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    # En yeni yedekler önce
                    backups.sort(reverse=True)
                    
                    restore_text = "♻️ <b>Yedek Geri Yükle</b>\n\n"
                    restore_text += "📋 <b>Mevcut Yedekler:</b>\n\n"
                    
                    for backup_file in backups[:10]:
                        timestamp_str = backup_file.replace('backup_', '').replace('.json', '')
                        try:
                            timestamp = int(timestamp_str)
                            date_str = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')
                        except:
                            date_str = "Bilinmeyen"
                        
                        restore_text += f"💾 <code>{backup_file}</code>\n"
                        restore_text += f"   Tarih: {date_str}\n\n"
                    
                    restore_text += (
                        f"⚠️ <b>Uyarı:</b> Geri yükleme mevcut verilerin üzerine yazacak!\n\n"
                        f"✏️ Geri yüklemek istediğiniz yedek dosya adını yazın:"
                    )
                    
                    context.user_data['state'] = 'waiting_restore_backup'
                    
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    await query.edit_message_text(restore_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                except Exception as e:
                    logger.error(f"❌ Restore backup selection error: {e}")
                    await query.edit_message_text(
                        f"❌ <b>Yedek seçiminde hata!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "delete_backup":
                # Yedek silme için dosya seç
                try:
                    import os
                    
                    backup_dir = "/opt/outline-telegram-bot/backups"
                    
                    if not os.path.exists(backup_dir):
                        await query.edit_message_text(
                            "🗑️ <b>Yedek Sil</b>\n\n"
                            "❌ Yedek bulunamadı!",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    backups = [f for f in os.listdir(backup_dir) if f.startswith('backup_') and f.endswith('.json')]
                    
                    if not backups:
                        await query.edit_message_text(
                            "🗑️ <b>Yedek Sil</b>\n\n"
                            "❌ Yedek bulunamadı!",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    backups.sort(reverse=True)
                    
                    delete_text = "🗑️ <b>Yedek Sil</b>\n\n"
                    delete_text += "📋 <b>Mevcut Yedekler:</b>\n\n"
                    
                    for backup_file in backups:
                        timestamp_str = backup_file.replace('backup_', '').replace('.json', '')
                        try:
                            timestamp = int(timestamp_str)
                            date_str = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')
                        except:
                            date_str = "Bilinmeyen"
                        
                        delete_text += f"💾 <code>{backup_file}</code> - {date_str}\n"
                    
                    delete_text += "\n✏️ Silmek istediğiniz yedek dosya adını yazın:"
                    
                    context.user_data['state'] = 'waiting_delete_backup'
                    
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    await query.edit_message_text(delete_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                except Exception as e:
                    logger.error(f"❌ Delete backup selection error: {e}")
                    await query.edit_message_text(
                        f"❌ <b>Yedek silme seçiminde hata!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "add_backup_ip":
                # Yedek IP ekleme - önce API seç
                api_list_text = "➕ <b>Yedek IP Ekle</b>\n\n"
                api_list_text += "📋 <b>Hangi API'ye yedek IP eklemek istiyorsunuz?</b>\n\n"
                
                # API'leri sırala: api1 önce, sonra diğerleri
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                for api_info in sorted_apis:
                    api_id = api_info['id']
                    api_url = api_info['api']['apiUrl']
                    original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                    
                    # İsimlendirme
                    if api_id == 'api1':
                        display_name = f"Ana API ({original_ip})"
                    else:
                        display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                    
                    api_list_text += f"🔹 <b>{display_name}</b>\n"
                    api_list_text += f"   • ID: <code>{api_id}</code>\n\n"
                
                api_list_text += "✏️ API ID yazın (örnek: <code>api1</code>):"
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(api_list_text, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data['state'] = 'waiting_backup_ip_api_selection'
                
            elif data == "list_backup_ips":
                # Yedek IP listesi
                try:
                    if not self.database.get('backup_ips'):
                        await query.edit_message_text(
                            "📋 <b>Yedek IP Listesi</b>\n\n"
                            "❌ Henüz yedek IP eklenmemiş.",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    from datetime import datetime
                    list_text = "📋 <b>Yedek IP Listesi</b>\n\n"
                    
                    for backup_id, backup_info in self.database['backup_ips'].items():
                        ip = backup_info.get('ip', 'N/A')
                        api_id = backup_info.get('api_id', 'N/A')
                        original_ip = backup_info.get('original_ip', 'N/A')
                        created_at = backup_info.get('created_at')
                        
                        if created_at:
                            created = datetime.fromtimestamp(created_at).strftime('%Y-%m-%d %H:%M')
                        else:
                            created = 'N/A'
                        
                        port_info = backup_info.get('port', self.config.get('outline_port', 444))
                        list_text += f"🌐 <b>Yedek IP:</b> <code>{ip}</code> → <code>{original_ip}</code>\n"
                        list_text += f"   • API: <code>{api_id}</code>\n"
                        list_text += f"   • Port: <code>{port_info}</code> (TCP + UDP)\n"
                        list_text += f"   • Oluşturulma: {created}\n"
                        list_text += f"   • ID: <code>{backup_id}</code>\n"
                        list_text += f"   • Deployment: <code>iptables</code>\n"
                        list_text += f"   • Port Aralığı: <code>444-999</code>\n\n"
                    
                    keyboard = [[InlineKeyboardButton("🔙 Geri", callback_data="backup_ip_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(list_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                except Exception as e:
                    logger.error(f"❌ Error listing backup IPs: {e}")
                    await query.edit_message_text(
                        f"❌ <b>Yedek IP listesi gösterilirken hata oluştu!</b>\n\n"
                        f"🔍 Hata: <code>{str(e)}</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                
            elif data == "delete_backup_ip":
                # Yedek IP silme
                if not self.database.get('backup_ips'):
                    await query.edit_message_text(
                        "❌ <b>Silinecek yedek IP bulunamadı!</b>\n\n"
                        "💡 Önce yedek IP ekleyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                delete_text = "🗑️ <b>Yedek IP Sil</b>\n\n"
                delete_text += "📋 <b>Mevcut Yedek IP'ler:</b>\n\n"
                
                for backup_id, backup_info in self.database['backup_ips'].items():
                    ip = backup_info['ip']
                    api_id = backup_info['api_id']
                    
                    delete_text += f"🌐 <code>{ip}</code> → API: {api_id}\n"
                    delete_text += f"   • ID: <code>{backup_id}</code>\n\n"
                
                delete_text += "✏️ Silmek istediğiniz yedek IP'nin ID'sini yazın:"
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(delete_text, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data['state'] = 'waiting_delete_backup_ip'
                
            elif data == "add_new_api":
                # Yeni API ekleme
                current_api_count = len(self.config['outline_apis'])
                
                add_api_text = (
                    f"➕ <b>Yeni API Ekle</b>\n\n"
                    f"📊 <b>Mevcut API Sayısı:</b> {current_api_count}\n\n"
                    f"💡 <b>Yeni API Rolü:</b>\n"
                    f"• Yedek/alternatif API olarak eklenecek\n"
                    f"• Mevcut anahtarlar etkilenmez\n"
                    f"• Yeni anahtar oluştururken seçebilirsiniz\n\n"
                    f"📋 <b>API Formatları:</b>\n\n"
                    f"1️⃣ <b>JSON:</b>\n"
                    f"<code>{{\"apiUrl\":\"https://IP:PORT/PATH\",\"certSha256\":\"HASH\"}}</code>\n\n"
                    f"2️⃣ <b>URL:</b>\n"
                    f"<code>https://IP:PORT/PATH</code>\n\n"
                    f"✏️ Yeni API bilgisini girin:"
                )
                
                await query.edit_message_text(add_api_text, parse_mode='HTML')
                context.user_data['state'] = 'waiting_add_new_api'
            
            elif data == "delete_api":
                # API silme (api1 hariç)
                deletable_apis = [api for api in self.config['outline_apis'] if api['id'] != 'api1']
                
                if not deletable_apis:
                    await query.edit_message_text(
                        "❌ <b>Silinebilir API Bulunamadı!</b>\n\n"
                        "💡 Sadece api1 var ve bu silinemez.\n"
                        "Ana API (api1) sistem tarafından korunmaktadır.\n\n"
                        "🔹 Önce 'Yeni API Ekle' ile yeni API ekleyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                api_list = "🗑️ <b>API Silme</b>\n\n"
                api_list += "⚠️ <b>Dikkat:</b> API silindiğinde içindeki tüm anahtarlar da silinecek!\n\n"
                api_list += "📋 <b>Silinebilir API'ler:</b>\n\n"
                
                for api_info in deletable_apis:
                    api_id = api_info['id']
                    api_name = api_info['name']
                    key_count = len(api_info['keys'])
                    
                    api_list += f"🔹 <b>{api_name}</b>\n"
                    api_list += f"   • ID: <code>{api_id}</code>\n"
                    api_list += f"   • Anahtar Sayısı: {key_count}\n\n"
                
                api_list += "❓ <b>Hangi API'yi silmek istiyorsunuz?</b>\n\n"
                api_list += f"✏️ API ID yazın (örnek: <code>{deletable_apis[0]['id']}</code>)\n\n"
                api_list += "⛔ <b>Not:</b> api1 silinemez (ana API)"
                
                context.user_data['state'] = 'waiting_delete_api'
                await query.edit_message_text(
                    api_list,
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            elif data == "move_keys":
                # Anahtar taşıma
                total_apis = len(self.config['outline_apis'])
                
                if total_apis < 2:
                    await query.edit_message_text(
                        "❌ <b>Anahtar taşımak için en az 2 API gerekli!</b>\n\n"
                        "💡 Önce 'Yeni API Ekle' ile ikinci API ekleyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # API listesi oluştur
                api_list = "🔀 <b>Anahtar Taşıma</b>\n\n"
                api_list += f"📊 <b>Mevcut API'ler:</b>\n\n"
                
                # API'leri sırala: api1 önce, sonra diğerleri
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                source_apis = []
                for idx, api_info in enumerate(sorted_apis, 1):
                    api_id = api_info['id']
                    api_url = api_info['api']['apiUrl']
                    original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                    key_count = len(api_info['keys'])
                    
                    # Sadece anahtarı olan API'leri kaynak olarak göster
                    if key_count > 0:
                        # İsimlendirme
                        if api_id == 'api1':
                            display_name = f"Ana API ({original_ip})"
                        else:
                            display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                        
                        api_list += f"<b>{idx}. {display_name}</b>\n"
                        api_list += f"   🆔 ID: <code>{api_id}</code>\n"
                        api_list += f"   🔑 Anahtarlar: {key_count}\n\n"
                        source_apis.append(api_id)
                
                if not source_apis:
                    await query.edit_message_text(
                        "❌ <b>Taşınacak anahtar yok!</b>\n\n"
                        "💡 Hiçbir API'de anahtar bulunmuyor.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                api_list += f"❓ <b>Hangi API'den anahtar taşımak istiyorsunuz?</b>\n\n"
                api_list += f"✏️ API ID yazın (örnek: <code>{source_apis[0]}</code>)"
                
                context.user_data['source_apis'] = source_apis
                context.user_data['state'] = 'waiting_move_source_api'
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(api_list, parse_mode='HTML', reply_markup=reply_markup)
            
            elif data == "update_ip":
                # Mevcut API'lerden IP'leri çıkar
                api_ips = {}
                for api_info in self.config['outline_apis']:
                    api_url = api_info['api']['apiUrl']
                    # Config'den original_ip'yi al, yoksa API URL'den çıkar
                    original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                    key_count = len(api_info['keys'])
                    
                    # Mevcut kullanılan IP'yi tespit et (ilk anahtardan)
                    current_ip = original_ip
                    if api_info['keys']:
                        first_key = api_info['keys'][0]
                        if first_key in self.database['keys']:
                            ss_url = self.database['keys'][first_key].get('ss_url', '')
                            import re
                            ipv4_match = re.search(r'@([\d\.]+):', ss_url)
                            if ipv4_match:
                                current_ip = ipv4_match.group(1)
                    
                    api_ips[api_info['id']] = {
                        'name': api_info['name'],
                        'original_ip': original_ip,
                        'current_ip': current_ip,
                        'keys': key_count
                    }
                
                if len(api_ips) == 1:
                    # Tek API varsa direkt IP güncelleme
                    api_id = list(api_ips.keys())[0]
                    original_ip = api_ips[api_id]['original_ip']
                    current_ip = api_ips[api_id]['current_ip']
                    
                    ip_help_text = f"🔄 <b>IP Adresi Güncelleme</b>\n\n"
                    ip_help_text += f"📊 <b>Mevcut API:</b> {api_ips[api_id]['name']}\n"
                    ip_help_text += f"🆔 <b>ID:</b> <code>{api_id}</code>\n"
                    
                    if current_ip == original_ip:
                        ip_help_text += f"🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                    else:
                        ip_help_text += f"🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                        ip_help_text += f"📍 <b>Güncel IP:</b> <code>{current_ip}</code> ✅\n"
                    
                    ip_help_text += f"🔑 <b>Anahtarlar:</b> {api_ips[api_id]['keys']}\n"
                    
                    # Bu API için yedek IP'leri göster
                    backup_ips_for_api = [
                        (bid, binfo) for bid, binfo in self.database.get('backup_ips', {}).items() 
                        if binfo['api_id'] == api_id
                    ]
                    
                    current_port = self.config.get('outline_port', 444)
                    if backup_ips_for_api:
                        ip_help_text += f"\n🌐 <b>Yedek IP'ler (Port <code>444-999</code> - iptables):</b>\n"
                        for backup_id, backup_info in backup_ips_for_api:
                            backup_ip = backup_info['ip']
                            ip_help_text += f"   • <code>{backup_ip}</code> → <code>{original_ip}</code> (Port-to-Port)\n"
                    
                    ip_help_text += "\n📝 <b>Yeni IP adresini girin:</b>\n"
                    ip_help_text += "(IPv4: 123.45.67.89 veya IPv6: 2001:db8::1)"
                    
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(ip_help_text, parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data['state'] = 'waiting_new_ip'
                    context.user_data['single_api_id'] = api_id
                else:
                    # Çoklu API - Hangisini güncelleyeceğini sor
                    ip_list = "🔄 <b>IP Adresi Güncelleme</b>\n\n"
                    ip_list += "📊 <b>Mevcut API'ler ve IP'ler:</b>\n\n"
                    
                    # API'leri sırala: api1 önce, sonra diğerleri
                    sorted_api_ids = sorted(api_ips.keys(), key=lambda x: (x != 'api1', x))
                    
                    for api_id in sorted_api_ids:
                        info = api_ips[api_id]
                        
                        # İsimlendirme: api1 = Ana API, diğerleri = Yedek API
                        if api_id == 'api1':
                            display_name = f"Ana API ({info['original_ip']})"
                        else:
                            display_name = f"Yedek API - {api_id.upper()} ({info['original_ip']})"
                        
                        ip_list += f"<b>{display_name}</b>\n"
                        ip_list += f"🆔 ID: <code>{api_id}</code>\n"
                        
                        if info['current_ip'] == info['original_ip']:
                            ip_list += f"🔵 <b>Ana IP:</b> <code>{info['original_ip']}</code>\n"
                        else:
                            ip_list += f"🔵 <b>Ana IP:</b> <code>{info['original_ip']}</code>\n"
                            ip_list += f"📍 <b>Güncel IP:</b> <code>{info['current_ip']}</code> ✅\n"
                        
                        ip_list += f"🔑 <b>Anahtarlar:</b> {info['keys']}\n"
                        
                        # Bu API için yedek IP'leri göster
                        backup_ips_for_api = [
                            (bid, binfo) for bid, binfo in self.database.get('backup_ips', {}).items() 
                            if binfo['api_id'] == api_id
                        ]
                        
                        current_port = self.config.get('outline_port', 444)
                        if backup_ips_for_api:
                            ip_list += f"🌐 <b>Yedek IP'ler (iptables - Port Range 444-999):</b>\n"
                            for backup_id, backup_info in backup_ips_for_api:
                                backup_ip = backup_info['ip']
                                ip_list += f"   • <code>{backup_ip}</code> → <code>{info['original_ip']}</code> (TCP+UDP)\n"
                        
                        ip_list += "\n"
                    
                    ip_list += (
                        f"💡 <b>Yönlendirme Bilgisi:</b>\n"
                        f"Her API için ayrı IP güncelleyebilirsiniz.\n"
                        f"Yeni IP → Eski IP yönlendirmesi yapın.\n\n"
                        f"✏️ <b>Hangi API'nin IP'sini güncellemek istiyorsunuz?</b>\n"
                        f"API ID'sini yazın (örn: <code>api1</code>, <code>api2</code>):"
                    )
                    
                    keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(ip_list, parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data['state'] = 'waiting_select_api_for_ip'
                    context.user_data['api_ips'] = api_ips
                
            elif data == "refresh_api":
                # API sayısını göster
                api_count = len(self.config['outline_apis'])
                total_keys = len(self.database['keys'])

                # YAML modunda API yoksa → YAML güncelleme seçenekleri sun
                if api_count == 0:
                    has_yaml = bool(self.config.get('default_yaml_content'))
                    yaml_menu_text = (
                        f"🔄 <b>Bağlantı Güncelleme</b>\n\n"
                        f"ℹ️ Şu an <b>YAML modundasinız</b> (Outline Management API yok).\n\n"
                        f"📊 <b>Mevcut Durum:</b>\n"
                        f"• Toplam Anahtar: {total_keys}\n"
                        f"• YAML İçeriği: {'Yüklendi ✅' if has_yaml else 'Yok ❌'}\n\n"
                        f"💡 <b>Ne yapmak istiyorsunuz?</b>\n"
                        f"• <b>Yeni YAML Yükle:</b> ss.sh'dan yeni access.yaml yükle\n"
                        f"• <b>Endpoint IP Düzenle:</b> YAML içindeki IP adresini güncelle\n"
                        f"• <b>Outline API Ekle:</b> Geleneksel Outline sunucusu ekle"
                    )
                    keyboard = [
                        [InlineKeyboardButton("📄 Yeni YAML Yükle", callback_data="add_yaml")],
                        [InlineKeyboardButton("✏️ Endpoint IP Düzenle", callback_data="edit_yaml_endpoint")],
                        [InlineKeyboardButton("➕ Outline API Ekle", callback_data="add_new_api")],
                        [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(yaml_menu_text, parse_mode='HTML', reply_markup=reply_markup)
                    return

                keyboard = [
                    [InlineKeyboardButton("🔄 Hepsini Güncelle", callback_data="update_all_apis")],
                    [InlineKeyboardButton("🎯 Özel Güncelleme", callback_data="update_custom_range")],
                    [InlineKeyboardButton("📋 API Listesi", callback_data="list_apis")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                api_text = (
                    f"🔄 <b>API Güncelleme</b>\n\n"
                    f"📊 <b>Mevcut Durum:</b>\n"
                    f"• Toplam API: {api_count}\n"
                    f"• Toplam Anahtar: {total_keys}\n\n"
                    f"💡 <b>Seçenekler:</b>\n"
                    f"• <b>Hepsini Güncelle:</b> Tüm anahtarları tek API'ye taşı\n"
                    f"• <b>Özel Güncelleme:</b> Belirli aralıkları farklı API'lere taşı\n"
                    f"• <b>API Listesi:</b> Mevcut API'leri görüntüle"
                )
                
                await query.edit_message_text(api_text, parse_mode='HTML', reply_markup=reply_markup)
            
            elif data == "update_all_apis":
                # YAML modunda API yoksa → refresh_api menüsüne yönlendir
                if not self.config['outline_apis']:
                    has_yaml = bool(self.config.get('default_yaml_content'))
                    yaml_menu_text = (
                        f"🔄 <b>Bağlantı Güncelleme</b>\n\n"
                        f"ℹ️ Hiç API bulunamadı — <b>YAML modundasinız</b>.\n\n"
                        f"📊 <b>Mevcut YAML:</b> {'Yüklendi ✅' if has_yaml else 'Yok ❌'}\n\n"
                        f"💡 <b>Ne yapmak istiyorsunuz?</b>"
                    )
                    keyboard = [
                        [InlineKeyboardButton("📄 Yeni YAML Yükle", callback_data="add_yaml")],
                        [InlineKeyboardButton("✏️ Endpoint IP Düzenle", callback_data="edit_yaml_endpoint")],
                        [InlineKeyboardButton("➕ Outline API Ekle", callback_data="add_new_api")],
                        [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await query.edit_message_text(yaml_menu_text, parse_mode='HTML', reply_markup=reply_markup)
                    return

                # Hangi API'yi yenileyeceğini sor
                api_list = "🔄 <b>Hepsini Güncelle - API Seç</b>\n\n"
                api_list += "⚠️ <b>Uyarı:</b> Seçilen API'deki tüm anahtarlar yeniden oluşturulacak!\n\n"
                api_list += "📋 <b>Mevcut API'ler:</b>\n\n"
                
                # API'leri sırala: api1 önce, sonra diğerleri
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                for idx, api_info in enumerate(sorted_apis, 1):
                    api_id = api_info['id']
                    api_url = api_info['api']['apiUrl']
                    original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                    key_count = len(api_info['keys'])
                    
                    # Mevcut IP'yi tespit et
                    current_ip = original_ip
                    if api_info['keys']:
                        first_key = api_info['keys'][0]
                        if first_key in self.database['keys']:
                            ss_url = self.database['keys'][first_key].get('ss_url', '')
                            import re
                            ipv4_match = re.search(r'@([\d\.]+):', ss_url)
                            if ipv4_match:
                                current_ip = ipv4_match.group(1)
                    
                    # İsimlendirme: api1 = Ana API, diğerleri = Yedek API
                    if api_id == 'api1':
                        display_name = f"Ana API ({original_ip})"
                    else:
                        display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                    
                    api_list += f"<b>{idx}. {display_name}</b>\n"
                    api_list += f"   🆔 ID: <code>{api_id}</code>\n"
                    
                    # IP gösterimi
                    if current_ip == original_ip:
                        api_list += f"   🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                    else:
                        api_list += f"   🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                        api_list += f"   📍 <b>Güncel IP:</b> <code>{current_ip}</code> ✅\n"
                    
                    api_list += f"   🔑 <b>Anahtarlar:</b> {key_count}\n\n"
                
                api_list += "❓ <b>Hangi API'yi yenilemek istiyorsunuz?</b>\n\n"
                api_list += "✏️ API ID yazın (örnek: <code>api1</code>)\n\n"
                api_list += "💡 <b>Not:</b> Sadece api1 yenilendiğinde ana API güncellenir!"
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(api_list, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data['state'] = 'waiting_select_api_to_refresh'
            
            elif data == "update_custom_range":
                total_keys = len(self.database['keys'])
                
                range_text = (
                    f"🎯 <b>Özel Güncelleme - Aralık Seç</b>\n\n"
                    f"📊 <b>Toplam Anahtar:</b> {total_keys}\n\n"
                    f"📝 <b>Format:</b> BAŞLANGIÇ-BİTİŞ\n\n"
                    f"⏱️ <b>Sıralama:</b> Oluşturulma zamanına göre (en eski → en yeni)\n\n"
                    f"💡 <b>Örnekler:</b>\n"
                    f"• <code>1-250</code> → İlk oluşturulan 250 anahtar\n"
                    f"• <code>251-500</code> → 251. ile 500. anahtar arası\n"
                    f"• <code>501-son</code> → 501. anahtardan sona kadar\n"
                    f"• <code>1-son</code> → Tüm anahtarlar\n\n"
                    f"✏️ Aralığı girin:"
                )
                await query.edit_message_text(range_text, parse_mode='HTML')
                context.user_data['state'] = 'waiting_custom_range'
            
            elif data == "list_apis":
                api_list = "📋 <b>API Listesi</b>\n\n"
                
                # API'leri sırala: api1 önce, sonra diğerleri
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                for idx, api_info in enumerate(sorted_apis, 1):
                    api_url = api_info['api']['apiUrl']
                    api_id = api_info['id']
                    # Config'den original_ip'yi al, yoksa API URL'den çıkar
                    original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                    key_count = len(api_info['keys'])
                    
                    # Mevcut kullanılan IP'yi tespit et (ilk anahtardan)
                    current_ip = original_ip
                    if api_info['keys']:
                        first_key = api_info['keys'][0]
                        if first_key in self.database['keys']:
                            ss_url = self.database['keys'][first_key].get('ss_url', '')
                            # ss:// URL'den IP çıkar
                            import re
                            ipv4_match = re.search(r'@([\d\.]+):', ss_url)
                            if ipv4_match:
                                current_ip = ipv4_match.group(1)
                    
                    # İsimlendirme: api1 = Ana API, diğerleri = Yedek API
                    if api_id == 'api1':
                        display_name = f"Ana API ({original_ip})"
                    else:
                        display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                    
                    api_list += f"<b>{idx}. {display_name}</b>\n"
                    api_list += f"   🆔 ID: <code>{api_id}</code>\n"
                    
                    # IP gösterimi: Ana IP ve Güncel IP
                    if current_ip == original_ip:
                        api_list += f"   🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                    else:
                        api_list += f"   🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n"
                        api_list += f"   📍 <b>Güncel IP:</b> <code>{current_ip}</code> ✅\n"
                    
                    api_list += f"   🔑 <b>Anahtarlar:</b> {key_count}\n\n"
                
                if not self.config['outline_apis']:
                    api_list += "❌ Henüz API eklenmemiş!"
                
                reply_markup = self.get_back_to_menu_keyboard()
                await query.edit_message_text(api_list, parse_mode='HTML', reply_markup=reply_markup)
                
            elif data == "confirm_delete_all":
                # Tüm anahtarları sil
                try:
                    total_keys = len(self.database['keys'])
                    deleted_count = 0
                    failed_count = 0
                    master_key_count = 0
                    
                    await query.edit_message_text(
                        f"🔄 <b>Tüm anahtarlar siliniyor...</b>\n\n"
                        f"📊 Toplam: {total_keys} anahtar",
                        parse_mode='HTML'
                    )
                    
                    # Tüm anahtarları sil
                    for key_id, key_data in list(self.database['keys'].items()):
                        try:
                            from_master_key = key_data.get('from_master_key', False)
                            outline_key_id = key_data.get('outline_key_id')
                            api_id = key_data.get('api_id')
                            key_port = key_data.get('port')  # Port bilgisini al
                            
                            # Master key'den oluşturulmadıysa Outline API'den sil
                            if outline_key_id and not from_master_key:
                                await self.delete_outline_key(outline_key_id, api_id=api_id, port=key_port)
                            elif from_master_key:
                                master_key_count += 1
                            
                            # Veritabanından sil
                            del self.database['keys'][key_id]
                            deleted_count += 1
                            
                        except Exception as e:
                            failed_count += 1
                            logger.error(f"Error deleting key {key_id}: {e}")
                    
                    # İstatistikleri güncelle
                    self.database['stats']['total_keys'] = 0
                    
                    # API key listelerini temizle
                    for api in self.config['outline_apis']:
                        api['keys'] = []
                    
                    self.save_database()
                    self.save_config()
                    
                    result_text = f"✅ <b>Toplu Silme Tamamlandı!</b>\n\n"
                    result_text += f"📊 <b>Sonuçlar:</b>\n"
                    result_text += f"• ✅ Silinen: <code>{deleted_count}</code> anahtar\n"
                    result_text += f"• ❌ Başarısız: <code>{failed_count}</code> anahtar\n"
                    result_text += f"• 📝 Toplam: <code>{total_keys}</code> anahtar\n"
                    if master_key_count > 0:
                        result_text += f"• 🔑 Master key anahtarları: <code>{master_key_count}</code> (sadece veritabanından silindi)\n"
                    result_text += f"\n🗑️ Tüm anahtarlar ve kullanıcı verileri temizlendi!"
                    
                    await query.edit_message_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    logger.info(f"✅ All keys deleted: {deleted_count} successful, {failed_count} failed, {master_key_count} from master key")
                    
                except Exception as e:
                    logger.error(f"❌ Error deleting all keys: {e}")
                    await query.edit_message_text(
                        "❌ <b>Toplu silme sırasında hata oluştu!</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
            
            elif data.startswith("confirm_delete_"):
                key_id = data.replace("confirm_delete_", "")
                
                if key_id in self.database['keys']:
                    key_data = self.database['keys'][key_id]
                    
                    # Outline sunucusundan sil (sadece master key'den oluşturulmadıysa)
                    try:
                        from_master_key = key_data.get('from_master_key', False)
                        outline_key_id = key_data.get('outline_key_id')
                        key_port = key_data.get('port')  # Port bilgisini al
                        
                        if outline_key_id and not from_master_key:
                            # Normal anahtar - Outline API'den sil
                            await self.delete_outline_key(outline_key_id, port=key_port)
                            logger.info(f"🗑️ Deleted from Outline API: {outline_key_id}")
                        elif from_master_key:
                            # Master key'den oluşturulmuş - sadece veritabanından sil
                            logger.info(f"🔑 Master key anahtar - sadece veritabanından siliniyor: {key_id}")
                        
                        # Veritabanından sil
                        port = key_data['port']
                        custom_id = self.get_custom_id(key_id)
                        
                        del self.database['keys'][key_id]
                        self.database['stats']['total_keys'] -= 1
                        self.save_database()
                        
                        # Port'u tekrar kullanılabilir yap (veritabanından kaldırılınca otomatik)
                        delete_msg = f"✅ Anahtar başarıyla silindi!\n🔑 Anahtar ID: <code>{custom_id}</code>\n🔓 Port {port} tekrar kullanılabilir."
                        if from_master_key:
                            delete_msg += "\n\n💡 <b>Not:</b> Master key anahtarı - sadece veritabanından silindi."
                        
                        await query.edit_message_text(delete_msg, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                        
                    except Exception as e:
                        logger.error(f"Key deletion error: {e}")
                        await query.edit_message_text("❌ Anahtar silinirken hata oluştu!", reply_markup=self.get_back_to_menu_keyboard())
                else:
                    await query.edit_message_text("❌ Anahtar bulunamadı!", reply_markup=self.get_back_to_menu_keyboard())
                    
            elif data == "cancel_delete":
                logger.info("❌ Processing cancel_delete button")
                await query.edit_message_text("❌ Silme işlemi iptal edildi.", reply_markup=self.get_back_to_menu_keyboard())
                
            elif data.startswith("confirm_ip_update_"):
                # IP güncelleme onayı - Butondan (Çoklu API destekli)
                try:
                    # callback_data: confirm_ip_update_NEW_IP|OLD_IP|API_ID
                    encoded_data = data.replace("confirm_ip_update_", "")
                    
                    # | ayırıcı ile parse et
                    if "|" in encoded_data:
                        parts = encoded_data.split("|")
                        new_ip = parts[0]
                        old_ip = parts[1]
                        api_id = parts[2] if len(parts) > 2 else 'all'
                    else:
                        # Eski format desteği
                        ip_parts = encoded_data.split("_")
                        if len(ip_parts) >= 8:
                            new_ip = ".".join(ip_parts[:4])
                            old_ip = ".".join(ip_parts[4:8])
                        else:
                            split_point = len(ip_parts) // 2
                            new_ip = ".".join(ip_parts[:split_point])
                            old_ip = ".".join(ip_parts[split_point:])
                        api_id = 'all'
                    
                    logger.info(f"IP update confirmed: {old_ip} → {new_ip} for API: {api_id}")
                    
                    # Hangi anahtarlar güncellenecek?
                    if api_id != 'all':
                        api_info = self.get_api_by_id(api_id)
                        api_name = api_info['name'] if api_info else "Bilinmeyen"
                        
                        # Database'den bu API'ye ait anahtarları bul
                        keys_to_update = []
                        keys_without_api_id = 0
                        
                        for key_id, key_data in self.database['keys'].items():
                            # Anahtar bu API'ye ait mi kontrol et
                            if key_data.get('api_id') == api_id:
                                keys_to_update.append(key_id)
                            # api_id yoksa VE tek API varsa, o API'ye ata
                            elif 'api_id' not in key_data:
                                keys_without_api_id += 1
                                # Tek API varsa veya ss_url'deki IP bu API'ye aitse
                                if len(self.config['outline_apis']) == 1:
                                    # Tek API var, tüm anahtarlar ona ait
                                    keys_to_update.append(key_id)
                                    # api_id'yi otomatik ekle
                                    self.database['keys'][key_id]['api_id'] = api_id
                                    logger.info(f"Auto-assigned api_id={api_id} to key {key_id}")
                                else:
                                    # Çoklu API var, ss_url'den IP'ye bakarak eşleştir
                                    ss_url = key_data.get('ss_url', '')
                                    api_url = api_info['api']['apiUrl']
                                    api_ip = self.get_ip_from_api_url(api_url)
                                    
                                    if api_ip and api_ip in ss_url:
                                        keys_to_update.append(key_id)
                                        # api_id'yi otomatik ekle
                                        self.database['keys'][key_id]['api_id'] = api_id
                                        logger.info(f"Matched and assigned api_id={api_id} to key {key_id} by IP {api_ip}")
                        
                        # Değişiklikleri kaydet
                        if keys_without_api_id > 0:
                            self.save_database()
                        
                        logger.info(f"Found {len(keys_to_update)} keys for API {api_id} (auto-fixed {keys_without_api_id} keys without api_id)")
                    else:
                        keys_to_update = list(self.database['keys'].keys())
                        api_name = "Tüm API'ler"
                    
                    # Master key kontrolü
                    master_ss_key = self.config.get('master_ss_key')
                    
                    if master_ss_key:
                        # Master key varsa, master key'deki IP'yi güncelle
                        await query.edit_message_text(
                            f"🔑 <b>Master Key Modu</b>\n\n"
                            f"🔄 Master key'deki IP güncelleniyor: {old_ip} → {new_ip}\n\n"
                            f"📊 Etkilenecek: {len(keys_to_update)} anahtar"
                        )
                        
                        import re
                        import base64
                        
                        # Master key'deki IP'yi değiştir
                        new_master_key = master_ss_key
                        ip_replaced = False
                        
                        # 1. @IP:PORT formatı varsa direkt değiştir
                        if '@' in master_ss_key:
                            # ss://BASE64@1.1.1.1:8388 formatı
                            ip_port_match = re.search(r'@([\d\.]+):(\d+)', master_ss_key)
                            if ip_port_match:
                                current_ip = ip_port_match.group(1)
                                current_port = ip_port_match.group(2)
                                new_master_key = master_ss_key.replace(f"@{current_ip}:{current_port}", f"@{new_ip}:{current_port}")
                                if new_master_key != master_ss_key:
                                    ip_replaced = True
                                    logger.info(f"✅ Direct IP replacement in master key: {current_ip} → {new_ip} (port {current_port} sabit)")
                        
                        # 2. Base64 içinde IP varsa decode/encode yap
                        else:
                            try:
                                # ss://BASE64 formatı (içinde METHOD:PASSWORD@IP:PORT)
                                key_part = master_ss_key[5:]  # ss:// kaldır
                                
                                # Cache kontrolü
                                if key_part in self.base64_decode_cache:
                                    decoded = self.base64_decode_cache[key_part]
                                    logger.debug(f"✨ Cache hit for master key Base64 decode")
                                else:
                                    decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
                                    # Cache'e ekle
                                    if len(self.base64_decode_cache) < 1000:
                                        self.base64_decode_cache[key_part] = decoded
                                
                                # METHOD:PASSWORD@IP:PORT formatını bul
                                ip_match = re.search(r'@([\d\.]+):(\d+)$', decoded)
                                if ip_match:
                                    current_ip = ip_match.group(1)
                                    current_port = ip_match.group(2)
                                    
                                    # IP'yi değiştir, port sabit
                                    new_decoded = decoded.replace(f"@{current_ip}:{current_port}", f"@{new_ip}:{current_port}")
                                    
                                    # Yeniden encode et
                                    new_encoded = base64.b64encode(new_decoded.encode()).decode().rstrip('=')
                                    new_master_key = f"ss://{new_encoded}"
                                    
                                    ip_replaced = True
                                    logger.info(f"✅ Base64 IP replacement in master key: {current_ip} → {new_ip} (port {current_port} sabit)")
                            except Exception as e:
                                logger.error(f"❌ Master key Base64 decode/encode error: {e}")
                        
                        if ip_replaced and new_master_key != master_ss_key:
                            # Master key'i güncelle
                            self.config['master_ss_key'] = new_master_key
                            self.save_config()
                            
                            # Tüm anahtarların ss_url'ini güncelle - Batch processing ile
                            updated_count = 0
                            total_keys = len(keys_to_update)
                            batch_size = 10
                            
                            for batch_start in range(0, total_keys, batch_size):
                                batch_end = min(batch_start + batch_size, total_keys)
                                batch_keys = keys_to_update[batch_start:batch_end]
                                
                                # Progress bar göster (100+ anahtar için)
                                if total_keys >= 100 and batch_start % 50 == 0:
                                    progress = int((batch_start / total_keys) * 100)
                                    progress_bar = "█" * (progress // 5) + "░" * (20 - progress // 5)
                                    await query.edit_message_text(
                                        f"🔑 <b>Master Key Güncelleme</b>\n\n"
                                        f"📊 İlerleme: [{progress_bar}] {progress}%\n"
                                        f"🔄 Güncellenen: {updated_count}/{total_keys}\n\n"
                                        f"⏳ Lütfen bekleyin...",
                                        parse_mode='HTML'
                                    )
                                
                                # Batch içindeki anahtarları güncelle
                                for key_id in batch_keys:
                                    if key_id in self.database['keys']:
                                        self.database['keys'][key_id]['ss_url'] = new_master_key
                                        updated_count += 1
                                
                                # Her batch'ten sonra kısa gecikme (API rate limit)
                                if batch_end < total_keys:
                                    await asyncio.sleep(0.1)
                            
                            self.save_database()
                            
                            # Cache'i temizle (master key güncellemesinde)
                            cache_size = len(self.base64_decode_cache)
                            self.base64_decode_cache.clear()
                            logger.info(f"🗑️ Base64 decode cache cleared after master key update ({cache_size} entries)")
                            
                            # Master key'in ORJİNAL IP:PORT'unu kullan (config'den)
                            # Bu, master key ilk eklendiğinde kaydedilmiştir
                            master_original = self.config.get('master_original_ip_port')
                            
                            if master_original and 'ip' in master_original and 'port' in master_original:
                                # Config'den ORIGINAL IP:PORT al (GERÇEK Outline sunucusu)
                                master_key_ip = master_original['ip']
                                master_key_port = master_original['port']
                                logger.info(f"✅ Using ORIGINAL master key IP:PORT from config: {master_key_ip}:{master_key_port}")
                            else:
                                # Fallback: Master key'den parse et (eski davranış)
                                logger.warning("⚠️ Master original IP:PORT not found in config, parsing from current master key...")
                                master_key_ip = None
                                master_key_port = None
                                
                                # Master key'den IP ve PORT'u çıkar
                                if '@' in master_ss_key:
                                    # Format: ss://BASE64@IP:PORT
                                    import re
                                    ip_port_match = re.search(r'@([\d\.]+):(\d+)', master_ss_key)
                                    if ip_port_match:
                                        master_key_ip = ip_port_match.group(1)
                                        master_key_port = int(ip_port_match.group(2))
                                        logger.info(f"✅ Master key IP:PORT parsed from @format: {master_key_ip}:{master_key_port}")
                                else:
                                    # Format: ss://BASE64 (IP Base64 içinde)
                                    try:
                                        import base64, re
                                        key_part = master_ss_key[5:]
                                        decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
                                        ip_port_match = re.search(r'@([\d\.]+):(\d+)', decoded)
                                        if ip_port_match:
                                            master_key_ip = ip_port_match.group(1)
                                            master_key_port = int(ip_port_match.group(2))
                                            logger.info(f"✅ Master key IP:PORT parsed from base64: {master_key_ip}:{master_key_port}")
                                    except Exception as e:
                                        logger.error(f"❌ Master key base64 parse error: {e}")
                            
                            # IP:PORT bulunamadıysa hata
                            if not master_key_ip or not master_key_port:
                                await query.edit_message_text(
                                    "\u274C <b>Master Key Parse Hatası!</b>\n\n"
                                    "Master key'den IP ve PORT çıkarılamadı.\n\n"
                                    "\U0001F4A1 Master key formatını kontrol edin:\n"
                                    f"<code>{master_ss_key[:80]}...</code>",
                                    parse_mode='HTML',
                                    reply_markup=self.get_back_to_menu_keyboard()
                                )
                                logger.error(f"❌ Master key IP/PORT parse failed: {master_ss_key[:50]}...")
                                return
                            
                            # Master key için iptables yönlendirme komutları
                            # SABIT IP ve PORT (master key'den alınan değerler)
                            iptables_commands = (
                                f"sudo sysctl -w net.ipv4.ip_forward=1\n"
                                f"sudo iptables -t nat -A PREROUTING -p tcp -d {new_ip} --dport {master_key_port} -j DNAT --to-destination {master_key_ip}:{master_key_port}\n"
                                f"sudo iptables -t nat -A POSTROUTING -p tcp -d {master_key_ip} --dport {master_key_port} -j MASQUERADE\n"
                                f"sudo iptables -t nat -A PREROUTING -p udp -d {new_ip} --dport {master_key_port} -j DNAT --to-destination {master_key_ip}:{master_key_port}\n"
                                f"sudo iptables -t nat -A POSTROUTING -p udp -d {master_key_ip} --dport {master_key_port} -j MASQUERADE"
                            )
                            
                            logger.info(f"✅ Master key iptables: {new_ip}:{master_key_port} → {master_key_ip}:{master_key_port}")
                            
                            # Sonuç mesajı
                            from html import escape
                            preview_key = new_master_key[:60] + '...' if len(new_master_key) > 60 else new_master_key
                            iptables_commands_html = escape(iptables_commands)
                            
                            result_text = (
                                "\u2705 <b>Master Key IP Güncellendi!</b>\n\n"
                                "\U0001F4CA <b>İstatistikler:</b>\n"
                                f"\u2022 \u2705 Güncellenen: <code>{updated_count}</code> anahtar\n"
                                f"\u2022 \U0001F504 IP Değişimi: <code>{old_ip}</code> \u2192 <code>{new_ip}</code>\n\n"
                                "\U0001F511 <b>Yeni Master Key:</b>\n"
                                f"<code>{preview_key}</code>\n\n"
                                "\U0001F4CB <b>iptables Yönlendirme Komutları:</b>\n\n"
                                "<b>Bu komutları YENİ sunucuda çalıştırın (her satırı sırayla):</b>\n\n"
                                f"<code>{iptables_commands_html}</code>\n\n"
                                "\u26A0\uFE0F <b>Önemli:</b>\n"
                                f"\U0001F535 <b>Kaynak (ORJİNAL Outline):</b> <code>{master_key_ip}:{master_key_port}</code>\n"
                                f"\U0001F7E2 <b>Hedef (Yeni IP):</b> <code>{new_ip}:{master_key_port}</code>\n"
                                f"\U0001F50C <b>Port:</b> <code>{master_key_port}</code> (TCP + UDP)\n\n"
                                "\U0001F4CC <b>Not:</b>\n"
                                f"\u2022 Yönlendirme ORJİNAL master key IP'sine yapılır\n"
                                f"\u2022 Master key eklendiğindeki IP: <code>{master_key_ip}</code>\n"
                                f"\u2022 Her güncellemede aynı IP kullanılır (SABIT)\n\n"
                                "\u2705 Komutları çalıştırdıktan sonra client'lar hemen bağlanabilir."
                            )
                            
                            await query.edit_message_text(
                                result_text,
                                parse_mode='HTML',
                                reply_markup=self.get_back_to_menu_keyboard()
                            )
                            logger.info(f"✅ Master key IP updated: {old_ip} → {new_ip} (master: {master_key_ip}:{master_key_port}), {updated_count} keys updated")
                            return
                        else:
                            await query.edit_message_text(
                                f"❌ <b>Master Key IP Güncellenemedi!</b>\n\n"
                                f"🔍 Master key'de <code>{old_ip}</code> bulunamadı.\n\n"
                                f"💡 Master key formatını kontrol edin.",
                                parse_mode='HTML',
                                reply_markup=self.get_back_to_menu_keyboard()
                            )
                            return
                    
                    # Normal mod (master key yok)
                    total_keys = len(keys_to_update)
                    await query.edit_message_text(
                        f"🔄 {api_name} için {total_keys} anahtar güncelleniyor..."
                    )
                    
                    updated_count = 0
                    failed_count = 0
                    sample_before = None
                    sample_after = None
                    batch_size = 10
                    
                    # Batch processing ile anahtarları güncelle
                    for batch_start in range(0, total_keys, batch_size):
                        batch_end = min(batch_start + batch_size, total_keys)
                        batch_keys = keys_to_update[batch_start:batch_end]
                        
                        # Progress bar göster (100+ anahtar için)
                        if total_keys >= 100 and batch_start % 50 == 0:
                            progress = int((batch_start / total_keys) * 100)
                            progress_bar = "█" * (progress // 5) + "░" * (20 - progress // 5)
                            await query.edit_message_text(
                                f"🔄 <b>IP Güncelleme - {api_name}</b>\n\n"
                                f"📊 İlerleme: [{progress_bar}] {progress}%\n"
                                f"✅ Başarılı: {updated_count}\n"
                                f"❌ Başarısız: {failed_count}\n"
                                f"📦 Toplam: {total_keys}\n\n"
                                f"⏳ Lütfen bekleyin...",
                                parse_mode='HTML'
                            )
                        
                        # Batch içindeki anahtarları işle
                        for key_id in batch_keys:
                            if key_id not in self.database['keys']:
                                continue
                                
                            try:
                                key_data = self.database['keys'][key_id]
                                old_ss_url = key_data.get('ss_url', '')
                                
                                # İlk anahtarı örnek olarak kaydet
                                if not sample_before:
                                    sample_before = old_ss_url[:80] + "..." if len(old_ss_url) > 80 else old_ss_url
                                
                                # IP'yi değiştir - @IP:PORT varsa direkt, yoksa Base64 decode/encode
                                import re
                                new_ss_url = old_ss_url
                                ip_replaced = False
                                
                                # 1. @IP:PORT formatı varsa direkt değiştir
                                if '@' in old_ss_url and re.search(r'@\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+', old_ss_url):
                                    # ss://BASE64@1.1.1.1:8388 → ss://BASE64@2.2.2.2:8388
                                    ip_port_match = re.search(r'@([\d\.]+):(\d+)', old_ss_url)
                                    if ip_port_match:
                                        current_ip = ip_port_match.group(1)
                                        current_port = ip_port_match.group(2)
                                        new_ss_url = old_ss_url.replace(f"@{current_ip}:{current_port}", f"@{new_ip}:{current_port}")
                                        if new_ss_url != old_ss_url:
                                            ip_replaced = True
                                            logger.debug(f"✅ Direct IP replacement for key {key_id[:12]}... (port {current_port} sabit)")
                                
                                # 2. Base64 içinde IP varsa decode/encode yap
                                else:
                                    try:
                                        # ss://BASE64 formatı (içinde METHOD:PASSWORD@IP:PORT)
                                        import base64
                                        key_part = old_ss_url[5:]  # ss:// kaldır
                                        
                                        # Cache kontrolü (aynı Base64'ü tekrar decode etme)
                                        if key_part in self.base64_decode_cache:
                                            decoded = self.base64_decode_cache[key_part]
                                            logger.debug(f"✨ Cache hit for Base64 decode: {key_id[:12]}...")
                                        else:
                                            decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
                                            # Cache'e ekle (max 1000 entry)
                                            if len(self.base64_decode_cache) < 1000:
                                                self.base64_decode_cache[key_part] = decoded
                                        
                                        # METHOD:PASSWORD@IP:PORT formatını bul
                                        ip_match = re.search(r'@([\d\.]+):(\d+)$', decoded)
                                        if ip_match:
                                            current_ip = ip_match.group(1)
                                            current_port = ip_match.group(2)
                                            
                                            # IP'yi değiştir, port sabit
                                            new_decoded = decoded.replace(f"@{current_ip}:{current_port}", f"@{new_ip}:{current_port}")
                                            
                                            # Yeniden encode et
                                            new_encoded = base64.b64encode(new_decoded.encode()).decode().rstrip('=')
                                            new_ss_url = f"ss://{new_encoded}"
                                            
                                            ip_replaced = True
                                            logger.debug(f"✅ Base64 IP replacement for key {key_id[:12]}... (port {current_port} sabit)")
                                    except Exception as e:
                                        logger.error(f"⚠️ Base64 decode/encode error for key {key_id[:12]}: {e}")
                                
                                if ip_replaced and new_ss_url != old_ss_url:
                                    self.database['keys'][key_id]['ss_url'] = new_ss_url
                                    updated_count += 1
                                    
                                    # İlk güncellemeyi örnek olarak kaydet
                                    if not sample_after:
                                        sample_after = new_ss_url[:80] + "..." if len(new_ss_url) > 80 else new_ss_url
                                    
                                    logger.info(f"✅ Updated IP for key {key_id[:12]}... ({api_name}): {old_ip} → {new_ip}")
                                else:
                                    failed_count += 1
                                    logger.warning(f"⚠️ Could not update IP for key {key_id[:12]}... (old_ip not found in ss_url)")
                                    
                            except Exception as e:
                                failed_count += 1
                                logger.error(f"❌ Error updating key {key_id}: {e}")
                        
                        # Her batch sonunda kısa gecikme
                        if batch_end < total_keys:
                            await asyncio.sleep(0.1)
                    
                    # Son progress göster (100+ anahtar için)
                    if total_keys >= 100:
                        progress_bar = "█" * 20
                        await query.edit_message_text(
                            f"🔄 <b>IP Güncelleme - {api_name}</b>\n\n"
                            f"📊 İlerleme: [{progress_bar}] 100%\n"
                            f"✅ Başarılı: {updated_count}\n"
                            f"❌ Başarısız: {failed_count}\n"
                            f"📦 Toplam: {total_keys}\n\n"
                            f"💾 Veritabanı kaydediliyor...",
                            parse_mode='HTML'
                        )
                    
                    # Veritabanını kaydet
                    self.save_database()
                    
                    # Cache'i temizle (yeni IP güncellemesinde)
                    cache_size = len(self.base64_decode_cache)
                    self.base64_decode_cache.clear()
                    logger.info(f"🗑️ Base64 decode cache cleared ({cache_size} entries)")
                    
                    # ⚠️ ÖNEMLİ: API URL'i GÜNCELLENMEMEL!
                    # API URL'deki IP original_ip olmalı, sadece client'lara verilen ss_url'de new_ip kullanılır
                    # Firewall yönlendirmesi: new_ip → original_ip
                    # Bu sayede Outline API hala original_ip üzerinden çalışır
                    
                    # API'nin original_ip'sini kontrol et ve sakla
                    if api_id != 'all':
                        api_info = self.get_api_by_id(api_id)
                        if api_info:
                            existing_original_ip = api_info.get('original_ip')
                            if not existing_original_ip:
                                # İlk kez IP güncellenmişse:
                                # Eğer old_ip bir backup IP değilse, onu original_ip olarak kaydet
                                backup_ips_db = self.database.get('backup_ips', {})
                                is_backup_ip = any(
                                    binfo.get('ip') == old_ip and binfo.get('api_id') == api_id
                                    for binfo in backup_ips_db.values()
                                )
                                
                                if is_backup_ip:
                                    # old_ip bir backup IP, original_ip'yi backup_ips'ten al
                                    for backup_id, backup_data in backup_ips_db.items():
                                        if backup_data.get('ip') == old_ip and backup_data.get('api_id') == api_id:
                                            api_info['original_ip'] = backup_data.get('original_ip', old_ip)
                                            logger.info(f"✅ Saved original_ip={api_info['original_ip']} from backup for API {api_id}")
                                            break
                                else:
                                    # old_ip gerçek IP, onu original_ip olarak kaydet
                                    api_info['original_ip'] = old_ip
                                    logger.info(f"✅ Saved original_ip={old_ip} for API {api_id}")
                                
                                self.save_config()
                    else:
                        # Tüm API'lerin original_ip'sini kontrol et
                        for api in self.config['outline_apis']:
                            if not api.get('original_ip'):
                                api_url = api['api']['apiUrl']
                                detected_ip = self.get_ip_from_api_url(api_url)
                                if detected_ip:
                                    api['original_ip'] = detected_ip
                                    logger.info(f"✅ Saved original_ip={detected_ip} for API {api['id']}")
                        self.save_config()
                    
                    # NOT: API URL'i değiştirilmemeli! Outline API hala original_ip'de çalışıyor.
                    
                    # Eksik anahtar kontrolü devre dışı (performans için)
                    missing_count = 0
                    # Eksik anahtar kontrolü kaldırıldı (performans optimizasyonu)
                    
                    # Sonuç mesajı
                    result_text = (
                        f"✅ <b>IP Güncelleme Tamamlandı!</b>\n\n"
                        f"📊 <b>Hedef:</b> {api_name}\n"
                        f"📊 <b>Sonuçlar:</b>\n"
                        f"• ✅ Güncellenen: <code>{updated_count}</code> anahtar\n"
                        f"• ❌ Başarısız: <code>{failed_count}</code> anahtar\n"
                    )
                    
                    if missing_count > 0:
                        result_text += f"• 🆕 Yeniden Oluşturulan: <code>{missing_count}</code> anahtar\n"
                    
                    result_text += (
                        f"\n🔴 <b>Eski IP:</b> <code>{old_ip}</code>\n"
                        f"🟢 <b>Yeni IP:</b> <code>{new_ip}</code>\n\n"
                    )
                    
                    # Örnek URL'leri göster
                    if sample_before and sample_after and updated_count > 0:
                        result_text += (
                            f"📝 <b>Örnek Değişim:</b>\n"
                            f"<b>Önce:</b> <code>{sample_before}</code>\n"
                            f"<b>Sonra:</b> <code>{sample_after}</code>\n\n"
                        )
                    
                    # Original IP'yi al - BACKUP IP KONTROLÜ
                    original_ip_display = old_ip
                    if api_id != 'all':
                        api_info = self.get_api_by_id(api_id)
                        if api_info:
                            original_ip_display = api_info.get('original_ip', old_ip)
                            
                            # BACKUP IP KONTROLÜ: Eğer old_ip bir backup IP ise, orijinal IP'yi bul
                            backup_ips_db = self.database.get('backup_ips', {})
                            for backup_id, backup_data in backup_ips_db.items():
                                if backup_data.get('api_id') == api_id and backup_data.get('ip') == old_ip:
                                    # Bu bir backup IP! Orijinal IP'yi kullan
                                    original_ip_display = backup_data.get('original_ip', original_ip_display)
                                    logger.info(f"✅ Using original IP from backup: {old_ip} → {original_ip_display}")
                                    break
                    
                    # iptables yönlendirme komutları
                    iptables_commands = (
                        f"sudo sysctl -w net.ipv4.ip_forward=1\n"
                        f"sudo iptables -t nat -A PREROUTING -p tcp -d {new_ip} --dport 444:999 -j DNAT --to-destination {original_ip_display}\n"
                        f"sudo iptables -t nat -A POSTROUTING -p tcp -d {original_ip_display} --dport 444:999 -j MASQUERADE\n"
                        f"sudo iptables -A FORWARD -p tcp -d {original_ip_display} --dport 444:999 -j ACCEPT\n"
                        f"sudo iptables -t nat -A PREROUTING -p udp -d {new_ip} --dport 444:999 -j DNAT --to-destination {original_ip_display}\n"
                        f"sudo iptables -t nat -A POSTROUTING -p udp -d {original_ip_display} --dport 444:999 -j MASQUERADE\n"
                        f"sudo iptables -A FORWARD -p udp -d {original_ip_display} --dport 444:999 -j ACCEPT"
                    )

                    # Database'e IP update kaydı ekle
                    ip_update_id = f"ip_update_{int(time.time())}"
                    if 'ip_updates' not in self.database:
                        self.database['ip_updates'] = {}

                    self.database['ip_updates'][ip_update_id] = {
                        'old_ip': old_ip,
                        'new_ip': new_ip,
                        'source_ip': original_ip_display,
                        'api_id': api_id,
                        'api_name': api_name,
                        'port_range': '444-999',
                        'deployment_method': 'iptables',
                        'updated_keys': updated_count,
                        'created_at': int(time.time())
                    }
                    self.save_database()

                    result_text += (
                        f"\n✅ <b>iptables Kurulum Hazır!</b>\n\n"
                        f"🟢 <b>Yeni Proxy Sunucu:</b> <code>{new_ip}</code>\n"
                        f"🔵 <b>Hedef (Ana API):</b> <code>{original_ip_display}</code>\n"
                        f"🔌 <b>Port Aralığı:</b> <code>444-999</code> (556 port)\n\n"
                        f"📋 <b>Yeni proxy sunucuda bu komutları çalıştırın (her satırı sırayla):</b>\n\n"
                        f"<code>{iptables_commands}</code>\n\n"
                        f"⚠️ <b>Önemli:</b>\n"
                        f"• Tüm portlar (444-999) {new_ip} → {original_ip_display} yönlendirilecek\n"
                        f"• TCP ve UDP kuralları birlikte uygulanmalı\n"
                        f"✅ Kurulum sonrası anahtarlar hemen çalışır"
                    )

                    logger.info(f"✅ iptables deployment ready for IP update: {old_ip} → {new_ip}")
                    
                    reply_markup = self.get_back_to_menu_keyboard()
                    await query.edit_message_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                    logger.info(f"🎉 IP update completed: {updated_count} keys updated, {failed_count} failed")
                    
                except Exception as e:
                    import traceback as tb
                    logger.error(f"❌ IP update button error: {e}")
                    logger.error(f"Exception details: {tb.format_exc()}")
                    reply_markup = self.get_back_to_menu_keyboard()
                    await query.edit_message_text(
                        "❌ IP güncellenirken hata oluştu!\n"
                        "Lütfen tekrar deneyin.",
                        reply_markup=reply_markup
                    )
            
            elif data == "cancel_ip_update":
                logger.info("❌ IP update cancelled by user")
                await query.edit_message_text(
                    "❌ IP güncelleme iptal edildi.",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            elif data == "update_port":
                # Port güncelleme - uyarı mesajı
                current_port = self.config.get('outline_port', 444)
                
                warning_text = (
                    f"🔌 <b>Port Güncelleme</b>\n\n"
                    f"📊 <b>Mevcut Port:</b> <code>{current_port}</code>\n\n"
                    f"⚠️ <b>UYARI:</b>\n"
                    f"• Port değişikliği zaman alabilir\n"
                    f"• Tüm client'ların yeniden bağlanması gerekir\n"
                    f"• Outline API güncellenmesi gerekir\n"
                    f"• IP yönlendirmesi varsa güncellenmeli\n\n"
                    f"📝 <b>Yapılacak İşlemler:</b>\n"
                    f"1️⃣ Outline sunucusunda port değiştirme\n"
                    f"2️⃣ API bağlantısını güncelleme\n"
                    f"3️⃣ iptables yönlendirmesini güncelleme (varsa)\n"
                    f"4️⃣ Tüm anahtarları yenileme\n\n"
                    f"❓ <b>Devam etmek istiyor musunuz?</b>"
                )
                
                keyboard = [
                    [InlineKeyboardButton("✅ Devam", callback_data="confirm_port_update")],
                    [InlineKeyboardButton("❌ İptal", callback_data="cancel_port_update")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(warning_text, parse_mode='HTML', reply_markup=reply_markup)
            
            elif data == "confirm_port_update":
                # Port güncelleme onaylandı - yeni port iste
                current_port = self.config.get('outline_port', 444)
                
                port_text = (
                    f"🔌 <b>Yeni Port Girin</b>\n\n"
                    f"📊 <b>Mevcut Port:</b> <code>{current_port}</code>\n\n"
                    f"📝 <b>Yeni port numarsını girin:</b>\n"
                    f"• Geçerli aralık: 1-65535\n"
                    f"• Öner: 1024-65535 arası\n"
                    f"• Örnek: 1234, 8080, 9999\n\n"
                    f"💡 <b>Varsayılan:</b> 444"
                )
                
                await query.edit_message_text(port_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                context.user_data['state'] = 'waiting_new_port'
            
            elif data == "cancel_port_update":
                logger.info("❌ Port update cancelled by user")
                await query.edit_message_text(
                    "❌ Port güncelleme iptal edildi.",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            elif data == "fix_keys":
                # Eski anahtarları onar - api_id ekle
                try:
                    await query.edit_message_text("🔧 Anahtarlar onarılıyor...")
                    
                    fixed_count = 0
                    total_keys = len(self.database['keys'])
                    
                    # Varsayılan API'yi al
                    default_api_id = self.config['outline_apis'][0]['id'] if self.config['outline_apis'] else None
                    
                    if not default_api_id:
                        await query.edit_message_text(
                            "❌ Hiç API bulunamadı!",
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        return
                    
                    # Her anahtarı kontrol et
                    for key_id, key_data in self.database['keys'].items():
                        # api_id yoksa ekle
                        if 'api_id' not in key_data:
                            # ss_url'den IP'yi çıkar ve hangi API'ye ait olduğunu bul
                            ss_url = key_data.get('ss_url', '')
                            
                            # API eşleştirmesi yap
                            matched_api_id = None
                            for api_info in self.config['outline_apis']:
                                api_url = api_info['api']['apiUrl']
                                api_ip = self.get_ip_from_api_url(api_url)
                                
                                # ss_url içinde bu IP var mı?
                                if api_ip in ss_url:
                                    matched_api_id = api_info['id']
                                    break
                            
                            # Eğer eşleşen API bulunamazsa varsayılan API kullan
                            if not matched_api_id:
                                matched_api_id = default_api_id
                            
                            # api_id ekle
                            self.database['keys'][key_id]['api_id'] = matched_api_id
                            
                            # API'nin key listesine ekle (eğer yoksa)
                            api_info = self.get_api_by_id(matched_api_id)
                            if api_info and key_id not in api_info.get('keys', []):
                                if 'keys' not in api_info:
                                    api_info['keys'] = []
                                api_info['keys'].append(key_id)
                            
                            fixed_count += 1
                            logger.info(f"✅ Fixed key {key_id}: added api_id={matched_api_id}")
                    
                    # Değişiklikleri kaydet
                    if fixed_count > 0:
                        self.save_database()
                        self.save_config()
                    
                    result_text = (
                        f"✅ <b>Anahtar Onarma Tamamlandı!</b>\n\n"
                        f"📊 <b>Sonuçlar:</b>\n"
                        f"• Toplam Anahtar: <code>{total_keys}</code>\n"
                        f"• Onarılan: <code>{fixed_count}</code>\n"
                        f"• Zaten Onarılmış: <code>{total_keys - fixed_count}</code>\n\n"
                        f"💡 <b>Not:</b> Tüm anahtarlara API bilgisi eklendi.\n"
                        f"Şimdi IP güncellemede anahtarlar görünecek."
                    )
                    
                    reply_markup = self.get_back_to_menu_keyboard()
                    await query.edit_message_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                    
                    logger.info(f"🔧 Fixed {fixed_count} keys, total: {total_keys}")
                    
                except Exception as e:
                    logger.error(f"❌ Error fixing keys: {e}")
                    await query.edit_message_text(
                        "❌ Anahtarlar onarılırken hata oluştu!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
            
            elif data == "manage_admins":
                # Sadece geliştirici erişebilir
                if not self.is_developer(user_id):
                    await query.edit_message_text(
                        "🚫 <b>Erişim Reddedildi!</b>\n\n"
                        "Bu özellik sadece geliştirici tarafından kullanılabilir.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                keyboard = [
                    [InlineKeyboardButton("➕ Admin Ekle", callback_data="add_admin")],
                    [InlineKeyboardButton("➖ Admin Sil", callback_data="remove_admin")],
                    [InlineKeyboardButton("📋 Admin Listesi", callback_data="list_admins")],
                    [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await query.edit_message_text(
                    "👥 <b>Admin Yönetimi</b>\n\n"
                    "Admin ekle, sil veya listele",
                    parse_mode='HTML',
                    reply_markup=reply_markup
                )
            
            elif data == "add_admin":
                # Sadece geliştirici erişebilir
                if not self.is_developer(user_id):
                    await query.edit_message_text(
                        "🚫 Erişim reddedildi!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                await query.edit_message_text(
                    "➕ <b>Admin Ekle</b>\n\n"
                    "Yeni admin eklemek için Telegram ID'sini girin:\n\n"
                    "📝 <b>Not:</b> Admin, tüm bot özelliklerini kullanabilir ancak "
                    "admin yönetimi yapamaz.",
                    parse_mode='HTML'
                )
                context.user_data['state'] = 'waiting_admin_add'
            
            elif data == "remove_admin":
                # Sadece geliştirici erişebilir
                if not self.is_developer(user_id):
                    await query.edit_message_text(
                        "🚫 Erişim reddedildi!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                if not self.config['admin_ids']:
                    await query.edit_message_text(
                        "❌ Silinecek admin yok!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                admin_list = "➖ <b>Admin Sil</b>\n\n"
                admin_list += f"👑 <b>Geliştirici (Silinemez):</b>\n"
                admin_list += f"• <code>{self.config['developer_id']}</code>\n\n"
                admin_list += f"👥 <b>Adminler:</b>\n"
                
                for admin_id in self.config['admin_ids']:
                    admin_list += f"• <code>{admin_id}</code>\n"
                
                admin_list += f"\n✏️ Silmek için Admin ID'sini yazın:"
                
                await query.edit_message_text(admin_list, parse_mode='HTML')
                context.user_data['state'] = 'waiting_admin_remove'
            
            elif data == "list_admins":
                # Sadece geliştirici erişebilir
                if not self.is_developer(user_id):
                    await query.edit_message_text(
                        "🚫 Erişim reddedildi!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                admin_list = "📋 <b>Admin Listesi</b>\n\n"
                admin_list += f"👑 <b>Geliştirici (Developer):</b>\n"
                admin_list += f"• <code>{self.config['developer_id']}</code>\n"
                admin_list += f"  └─ Tüm yetkiler, silinemez\n\n"
                
                if self.config['admin_ids']:
                    admin_list += f"👥 <b>Adminler ({len(self.config['admin_ids'])}):</b>\n"
                    for idx, admin_id in enumerate(self.config['admin_ids'], 1):
                        admin_list += f"{idx}. <code>{admin_id}</code>\n"
                        admin_list += f"   └─ Bot yönetimi, admin düzenleme yok\n"
                else:
                    admin_list += "👥 <b>Adminler:</b>\n"
                    admin_list += "• Henüz admin eklenmemiş\n"
                
                admin_list += f"\n📊 <b>Toplam Yetkili:</b> {1 + len(self.config['admin_ids'])}"
                
                reply_markup = self.get_back_to_menu_keyboard()
                await query.edit_message_text(admin_list, parse_mode='HTML', reply_markup=reply_markup)
                
            else:
                logger.warning(f"❓ Unknown button data received: '{data}'")
                await query.edit_message_text("❌ Bilinmeyen komut!", reply_markup=self.get_back_to_menu_keyboard())
                
        except Exception as e:
            logger.error(f"💥 Button handler error for '{data}': {str(e)}")
            logger.error(f"Exception type: {type(e).__name__}")
            import traceback
            logger.error(f"Traceback: {traceback.format_exc()}")
            
            try:
                await query.edit_message_text("❌ Bir hata oluştu! Lütfen tekrar deneyin.", reply_markup=self.get_back_to_menu_keyboard())
            except:
                pass  # Eğer mesaj düzenlenemezse görmezden gel
    
    async def message_handler(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Mesaj işleyici"""
        user_id = update.effective_user.id
        if not self.is_authorized(user_id):
            return
        
        state = context.user_data.get('state')
        text = update.message.text

        if state == 'waiting_yaml_upload':
            await update.message.reply_text(
                "📄 <b>Yaml dosyasını belge olarak gönderin.</b>\n\n"
                "Lütfen <code>.yaml</code> veya <code>.yml</code> dosyasını yükleyin.",
                parse_mode='HTML',
                reply_markup=self.get_back_to_menu_keyboard()
            )
            return

        if state == 'waiting_yaml_endpoint_ip':
            try:
                import ipaddress
                from urllib.parse import urlparse

                raw_input = (text or '').strip()
                candidate = raw_input

                # URL girildiyse host kısmını al (örn: wss://1.2.3.4:443/path)
                if '://' in candidate:
                    try:
                        parsed = urlparse(candidate)
                        if parsed.hostname:
                            candidate = parsed.hostname
                    except Exception:
                        pass

                candidate = candidate.strip().strip('[]')

                # IPv4:PORT veya [IPv6]:PORT formatlarını kabul et
                if candidate.count(':') == 1 and '.' in candidate:
                    host_part, port_part = candidate.split(':', 1)
                    if port_part.isdigit():
                        candidate = host_part.strip()
                elif raw_input.startswith('[') and ']' in raw_input and ':' in raw_input.split(']', 1)[-1]:
                    candidate = raw_input[1:raw_input.index(']')].strip()

                # Bracketsiz IPv6:PORT için son :PORT kısmını düşür
                if ':' in candidate and candidate.count(':') > 1:
                    maybe_host, maybe_port = candidate.rsplit(':', 1)
                    if maybe_port.isdigit():
                        try:
                            ipaddress.ip_address(maybe_host)
                            candidate = maybe_host
                        except ValueError:
                            pass

                try:
                    ipaddress.ip_address(candidate)
                    new_endpoint_ip = candidate
                except ValueError:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz IP adresi!</b>\n\n"
                        "✅ <b>Geçerli formatlar:</b>\n"
                        "• IPv4: <code>123.45.67.89</code>\n"
                        "• IPv6: <code>2001:db8::1</code>\n"
                        "• IPv4:PORT: <code>123.45.67.89:443</code>\n"
                        "• URL: <code>wss://123.45.67.89:443/ws</code>\n\n"
                        "✏️ Lütfen yeni endpoint IP adresini tekrar girin:",
                        parse_mode='HTML'
                    )
                    return

                old_endpoint_ip = context.user_data.get('old_yaml_endpoint_ip', 'Bilinmiyor')

                base_yaml = (self.config.get('default_yaml_content') or '').strip()
                if not base_yaml:
                    for key_data in self.database.get('keys', {}).values():
                        key_yaml = (key_data.get('yaml_content') or '').strip()
                        if key_yaml:
                            base_yaml = key_yaml
                            break

                if not base_yaml:
                    await update.message.reply_text(
                        "❌ <b>Güncellenecek YAML bulunamadı!</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return

                updated_default_yaml, changed_lines = self.update_yaml_endpoint_host(base_yaml, new_endpoint_ip)
                if changed_lines == 0:
                    await update.message.reply_text(
                        "❌ <b>YAML içinde endpoint satırı bulunamadı!</b>\n\n"
                        "YAML dosyasında şu formatta bir satır olduğundan emin olun:\n"
                        "<code>endpoint: 1.2.3.4:443</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return

                # Varsayılan YAML'i güncelle (yeni oluşturulacak anahtarlar için)
                self.config['default_yaml_content'] = updated_default_yaml
                self.set_connection_mode('yaml')

                # Mevcut abonelik linklerinde dönen YAML içeriklerini güncelle
                updated_key_count = 0
                assigned_key_count = 0
                for key_id, key_data in self.database.get('keys', {}).items():
                    key_yaml = (key_data.get('yaml_content') or '').strip()
                    if key_yaml:
                        new_key_yaml, key_changes = self.update_yaml_endpoint_host(key_yaml, new_endpoint_ip)
                        if key_changes > 0:
                            self.database['keys'][key_id]['yaml_content'] = new_key_yaml
                            updated_key_count += 1
                    else:
                        # YAML'siz anahtarlar da abonelikte yeni endpoint kullansın
                        self.database['keys'][key_id]['yaml_content'] = updated_default_yaml
                        assigned_key_count += 1

                self.save_database()

                await update.message.reply_text(
                    "✅ <b>YAML endpoint IP güncellendi!</b>\n\n"
                    f"🔵 <b>Eski Endpoint IP:</b> <code>{old_endpoint_ip}</code>\n"
                    f"🟢 <b>Yeni Endpoint IP:</b> <code>{new_endpoint_ip}</code>\n\n"
                    f"📦 <b>Endpoint güncellenen anahtar:</b> <code>{updated_key_count}</code>\n"
                    f"📄 <b>YAML atanan anahtar:</b> <code>{assigned_key_count}</code>\n\n"
                    "🔗 <b>Sonuç:</b> Abonelik linkleri artık yeni endpoint IP ile YAML döndürecek.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return

            except Exception as e:
                logger.error(f"❌ Error updating YAML endpoint: {e}")
                logger.error(traceback.format_exc())
                await update.message.reply_text(
                    f"❌ <b>YAML endpoint güncelleme hatası!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return
        
        if state == 'waiting_api_selection_for_key':
            # Çoklu API'den birini seç
            try:
                selected_api_id = text.strip().lower()
                
                # API'nin var olup olmadığını kontrol et
                api_info = self.get_api_by_id(selected_api_id)
                if not api_info:
                    await update.message.reply_text(
                        f"❌ <b>Geçersiz API ID!</b>\n\n"
                        f"Mevcut API'ler: {', '.join([api['id'] for api in self.config['outline_apis']])}\n\n"
                        f"Lütfen geçerli bir API ID girin:",
                        parse_mode='HTML'
                    )
                    return
                
                # API seçimini kaydet
                context.user_data['selected_api_for_key'] = selected_api_id
                
                # Bilgilendirme mesajı
                api_ip = self.get_ip_from_api_url(api_info['api']['apiUrl'])
                await update.message.reply_text(
                    f"✅ <b>API Seçildi:</b> {api_info['name']}\n"
                    f"📍 <b>IP:</b> <code>{api_ip}</code>\n\n"
                    f"Yeni anahtarlar bu API'den oluşturulacak.",
                    parse_mode='HTML'
                )
                
                # Anahtar ismi sor
                await update.message.reply_text(
                    "✏️ <b>Anahtar İsmi</b>\n\n"
                    "Lütfen oluşturulacak anahtarlar için bir isim girin:\n\n"
                    "📝 <b>Örnekler:</b>\n"
                    "• ELMA\n"
                    "• AHMET\n"
                    "• VIP_USER\n"
                    "• OZEL_ANAHTAR\n\n"
                    "💡 <b>Not:</b> Bu isim anahtar URL'inde görünecek",
                    parse_mode='HTML'
                )
                context.user_data['state'] = 'waiting_key_name'
                
            except Exception as e:
                logger.error(f"Error in API selection: {e}")
                await update.message.reply_text("❌ Hata oluştu! Lütfen tekrar deneyin.")
                context.user_data.clear()
        
        elif state == 'waiting_key_name':
            try:
                # İsim formatını kontrol et
                key_name = text.strip().upper()
                
                # Geçersiz karakterleri kontrol et
                import re
                if not re.match(r'^[A-Z0-9_-]+$', key_name):
                    await update.message.reply_text("❌ <b>Geçersiz isim!</b>\n\n✅ <b>Geçerli karakterler:</b>\n• Büyük harfler (A-Z)\n• Rakamlar (0-9)\n• Alt çizgi (_)\n• Tire (-)\n\n📝 <b>Örnekler:</b> ELMA, VIP_USER, OZEL-ANAHTAR", parse_mode='HTML')
                    return
                
                if len(key_name) < 2 or len(key_name) > 15:
                    await update.message.reply_text("❌ <b>İsim çok kısa veya uzun!</b>\n\n📏 <b>Uzunluk:</b> 2-15 karakter arası\n\n📝 <b>Örnekler:</b>\n• ELMA ✅\n• VIP_USER ✅\n• X ❌ (çok kısa)\n• COKUZUNBIRANAHTAR ❌ (çok uzun)", parse_mode='HTML')
                    return
                
                # İsmi kaydet ve sayı sor
                context.user_data['key_name'] = key_name
                context.user_data['state'] = 'waiting_key_count'
                await update.message.reply_text(f"✅ <b>İsim kaydedildi:</b> {key_name}\n\n🔢 <b>Kaç adet anahtar oluşturulsun?</b>\n\n📝 1-100 arası bir sayı girin:", parse_mode='HTML')
                
            except Exception as e:
                logger.error(f"Error in waiting_key_name: {e}")
                await update.message.reply_text("❌ Hata oluştu! Lütfen tekrar deneyin.")
                context.user_data.clear()
        
        elif state == 'waiting_key_count':
            try:
                count = int(text)
                if count <= 0 or count > 100:
                    await update.message.reply_text("Geçersiz sayı! (1-100 arası)")
                    return
                
                context.user_data['key_count'] = count
                context.user_data['state'] = 'waiting_key_duration'
                await update.message.reply_text(self.get_text("key_duration"), parse_mode='HTML')
                
            except ValueError:
                await update.message.reply_text("Lütfen geçerli bir sayı girin!")
                
        elif state == 'waiting_key_delete':
            try:
                # Özel ID formatını kontrol et (ELMA1, GITHUB2, VIP_USER3 gibi)
                custom_input = text.strip().upper()
                
                # "ALL" komutu kontrolü
                if custom_input == "ALL":
                    # Tüm anahtarları silme onayı
                    total_keys = len(self.database['keys'])
                    
                    if total_keys == 0:
                        await update.message.reply_text(
                            "❌ <b>Silinecek anahtar yok!</b>",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        context.user_data.clear()
                        return
                    
                    confirm_text = f"⚠️ <b>TÜM ANAHTARLARI SİLME ONAYI</b>\n\n"
                    confirm_text += f"🔑 <b>Toplam Anahtar:</b> <code>{total_keys}</code>\n"
                    confirm_text += f"⚠️ <b>UYARI:</b> Bu işlem geri alınamaz!\n"
                    confirm_text += f"🗑️ Tüm anahtarlar ve kullanıcı verileri silinecek!\n\n"
                    confirm_text += "❓ <b>Gerçekten TÜM anahtarları silmek istiyor musunuz?</b>"
                    
                    keyboard = [
                        [InlineKeyboardButton("✅ Evet, HEPSİNİ Sil", callback_data="confirm_delete_all")],
                        [InlineKeyboardButton("❌ İptal Et", callback_data="cancel_delete")]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    await update.message.reply_text(confirm_text, parse_mode='HTML', reply_markup=reply_markup)
                    context.user_data.clear()
                    return
                
                # En az 3 karakter olmalı ve sadece harfler, rakamlar, tire, alt çizgi içermeli
                import re
                if not re.match(r'^[A-Z0-9_-]{3,}$', custom_input):
                    await update.message.reply_text("❌ <b>Geçersiz ID formatı!</b>\n\n✅ <b>Geçerli format örnekleri:</b>\n• ELMA1\n• GITHUB2\n• VIP_USER3\n• OZEL_ANAHTAR4\n• <code>ALL</code> (Tüm anahtarları sil)\n\n💡 En az 3 karakter, büyük harf/rakam/tire/alt çizgi", parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    context.user_data.clear()
                    return
                
                # Özel ID'den key_id'yi bul - Akıllı arama sistemi
                target_key_id = None
                matching_keys = []
                
                # 1. Tam eşleme ara (ELMA1, GITHUB2 vs.)
                for key_id, key_data in self.database['keys'].items():
                    if self.get_custom_id(key_id) == custom_input:
                        target_key_id = key_id
                        matching_keys = [key_id]  # Tam eşleme varsa sadece onu al
                        break
                
                # 2. Tam eşleme yoksa, isim ile başlayanları ara (ELMA → ELMA1, ELMA2, ELMA3)
                if not target_key_id:
                    for key_id, key_data in self.database['keys'].items():
                        custom_id = self.get_custom_id(key_id)
                        if custom_id.startswith(custom_input):
                            matching_keys.append(key_id)
                
                # 3. Sonuçları değerlendir
                if not matching_keys:
                    await update.message.reply_text(f"❌ <b>'{custom_input}' ile eşleşen anahtar bulunamadı!</b>\n\n💡 Mevcut anahtarları görmek için 'Anahtar Silme' menüsünden TXT dosyasını indirin.", parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    context.user_data.clear()
                    return
                elif len(matching_keys) == 1:
                    # Tek anahtar bulundu, onu seç
                    target_key_id = matching_keys[0]
                else:
                    # Birden fazla anahtar bulundu, kullanıcıdan tam ID istemek
                    matching_ids = [self.get_custom_id(key_id) for key_id in matching_keys]
                    matching_text = "\n".join([f"• <code>{custom_id}</code>" for custom_id in matching_ids])
                    
                    await update.message.reply_text(
                        f"🔍 <b>'{custom_input}' ile {len(matching_keys)} anahtar bulundu!</b>\n\n"
                        f"📋 <b>Eşleşen anahtarlar:</b>\n{matching_text}\n\n"
                        f"✏️ <b>Silmek için tam ID yazın:</b>\n"
                        f"Örnek: <code>{matching_ids[0]}</code>", 
                        parse_mode='HTML', 
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Anahtar bilgilerini al
                key_data = self.database['keys'][target_key_id]
                created_at = key_data['created_at']
                duration = key_data['duration']
                port = key_data['port']
                
                # Kalan süreyi hesapla
                remaining = self.get_remaining_time(created_at, duration)
                
                # Onay mesajı
                confirm_text = f"🗑️ <b>Anahtar Silme Onayı</b>\n\n"
                confirm_text += f"🔑 <b>Anahtar ID:</b> <code>{custom_input}</code>\n"
                confirm_text += f"🔌 <b>Port:</b> <code>{port}</code>\n"
                confirm_text += f"⏰ <b>Kalan Süre:</b> <code>{remaining}</code>\n"
                confirm_text += f"📅 <b>Oluşturma:</b> <code>{datetime.fromtimestamp(created_at).strftime('%Y-%m-%d %H:%M')}</code>\n"
                confirm_text += f"📋 <b>Süre:</b> <code>{duration}</code>\n\n"
                confirm_text += "❓ <b>Gerçekten silmek istiyor musunuz?</b>"
                
                keyboard = [
                    [InlineKeyboardButton("✅ Evet, Sil", callback_data=f"confirm_delete_{target_key_id}")],
                    [InlineKeyboardButton("❌ İptal Et", callback_data="cancel_delete")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await update.message.reply_text(confirm_text, parse_mode='HTML', reply_markup=reply_markup)
                context.user_data.clear()
                
            except Exception as e:
                logger.error(f"Error in waiting_key_delete: {e}")
                await update.message.reply_text("❌ Hata oluştu! Lütfen geçerli bir Anahtar ID girin! (örnek: ELMA123, VIP_USER456)", reply_markup=self.get_back_to_menu_keyboard())
                context.user_data.clear()
                
        elif state == 'waiting_add_new_api':
            # Yeni API ekleme
            try:
                new_api = text.strip()
                logger.info(f"Adding new API: {new_api[:50]}...")
                
                # API formatını parse et
                import json
                api_data = None
                
                if new_api.startswith('{') and new_api.endswith('}'):
                    api_data = json.loads(new_api)
                elif new_api.startswith('https://') or new_api.startswith('http://'):
                    api_data = {'apiUrl': new_api}
                else:
                    await update.message.reply_text(
                        "❌ Geçersiz API formatı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # IP extraction
                from urllib.parse import urlparse
                import re
                api_url = api_data.get('apiUrl', '')
                ip = self.get_ip_from_api_url(api_url)
                original_ip = 'Unknown'
                try:
                    parsed = urlparse(api_url)
                    hostname = parsed.hostname
                    if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
                        original_ip = hostname
                    elif ':' in hostname:
                        original_ip = hostname
                    else:
                        original_ip = hostname
                except:
                    pass
                
                # Yeni API ID oluştur
                new_api_id = f"api{len(self.config['outline_apis']) + 1}"
                
                # API'yi test et
                await update.message.reply_text("🔄 API test ediliyor...")
                
                try:
                    # API bağlantısını test et
                    import ssl
                    from aiohttp import ClientSession
                    
                    ssl_context = ssl.create_default_context()
                    ssl_context.check_hostname = False
                    ssl_context.verify_mode = ssl.CERT_NONE
                    
                    async with ClientSession() as session:
                        async with session.get(
                            f"{api_url}/access-keys",
                            ssl=ssl_context,
                            timeout=10
                        ) as response:
                            if response.status == 200:
                                # API çalışıyor
                                logger.info(f"✅ New API test successful: {api_url}")
                            else:
                                raise Exception(f"API responded with status {response.status}")
                    
                except Exception as e:
                    logger.error(f"❌ API test failed: {e}")
                    await update.message.reply_text(
                        f"❌ <b>API testi başarısız!</b>\n\n"
                        f"🔍 <b>Hata:</b> <code>{str(e)}</code>\n\n"
                        f"💡 API'nin çalıştığından emin olun ve tekrar deneyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # YAML modundan mı geçiliyor? (API eklenmeden önce kontrol et)
                was_yaml_mode = self.is_yaml_mode_active()
                key_count = len(self.database.get('keys', {}))

                # Config'e ekle
                new_api_config = {
                    'id': new_api_id,
                    'name': f'API {new_api_id.upper()} ({ip})',
                    'api': api_data,
                    'original_ip': original_ip,
                    'keys': []
                }

                self.config['outline_apis'].append(new_api_config)
                self.set_connection_mode('api')
                # YAML temizle
                if 'default_yaml_content' in self.config:
                    del self.config['default_yaml_content']
                self.save_config()
                # Tüm anahtarların per-key yaml_content'ini temizle
                for key_id in self.database.get('keys', {}):
                    self.database['keys'][key_id]['yaml_content'] = None
                self.save_database()

                # YAML modundan geçiliyorsa: tüm anahtarları yeni API'de yeniden oluştur
                if was_yaml_mode and key_count > 0:
                    await update.message.reply_text(
                        f"⏳ <b>YAML modundan API moduna geçiliyor...</b>\n\n"
                        f"🔄 {key_count} anahtar yeni API üzerinde oluşturuluyor.\n"
                        f"Bu işlem biraz sürebilir.",
                        parse_mode='HTML'
                    )
                    update_result = await self.update_keys_with_new_api()
                    result_text = (
                        f"✅ <b>API Eklendi &amp; Anahtarlar Yeniden Oluşturuldu!</b>\n\n"
                        f"🆔 <b>API ID:</b> <code>{new_api_id}</code>\n"
                        f"📍 <b>IP:</b> <code>{ip}</code>\n\n"
                        f"♻️ <b>Sonuç:</b>\n"
                        f"• Temizlenen eski anahtar: <code>{update_result.get('cleaned', 0)}</code>\n"
                        f"• Yeniden oluşturulan: <code>{update_result.get('created', 0)}</code>\n\n"
                        f"🔒 <b>YAML tamamen temizlendi</b>, tüm abonelikler artık ss:// döndürüyor."
                    )
                else:
                    result_text = (
                        f"✅ <b>Yeni API Eklendi!</b>\n\n"
                        f"🆔 <b>API ID:</b> <code>{new_api_id}</code>\n"
                        f"📍 <b>IP:</b> <code>{ip}</code>\n"
                        f"🔵 <b>Orijinal IP:</b> <code>{original_ip}</code>\n\n"
                        f"📊 <b>Toplam API:</b> {len(self.config['outline_apis'])}\n\n"
                        f"ℹ️ <b>Not:</b> Mevcut anahtarlar korundu, yeni API boş eklendi"
                    )

                logger.info(f"✅ New API added: {new_api_id} ({ip}), was_yaml_mode={was_yaml_mode}")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error adding new API: {e}")
                await update.message.reply_text(
                    "❌ API eklenirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_new_key_input':
            # Yeni anahtar girişi - doğrulama ve onay
            try:
                new_key = text.strip()
                
                # ss:// format kontrolü
                if not new_key.startswith('ss://'):
                    await update.message.reply_text(
                        "❌ <b>Geçersiz format!</b>\n\n"
                        "🔍 Anahtar <code>ss://</code> ile başlamalıdır.\n\n"
                        "💡 Örnek:\n"
                        "<code>ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNToxZVZmZVhuSXJHZHQ2bWtKcHVqbjh0QDIxNy4yOC4xMzcuMjEwOjM3NTgz</code>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # Base64 decode ile method doğrulama (opsiyonel kontrol)
                import base64
                import re
                
                key_without_prefix = new_key[5:]  # ss:// kaldır
                
                try:
                    # @ işaretinden önceki kısmı al
                    if '@' in key_without_prefix:
                        encoded_part = key_without_prefix.split('@')[0]
                        
                        # Cache kontrolü
                        if encoded_part in self.base64_decode_cache:
                            decoded = self.base64_decode_cache[encoded_part]
                            logger.debug(f"✨ Cache hit for key validation")
                        else:
                            # Base64 decode
                            decoded = base64.b64decode(encoded_part + '==').decode('utf-8')
                            # Cache'e ekle
                            if len(self.base64_decode_cache) < 1000:
                                self.base64_decode_cache[encoded_part] = decoded
                        
                        # method:password formatını kontrol et
                        if ':' in decoded:
                            method, password = decoded.split(':', 1)
                            
                            # Method kontrolü
                            if method != 'chacha20-ietf-poly1305':
                                await update.message.reply_text(
                                    f"❌ <b>Geçersiz şifreleme metodu!</b>\n\n"
                                    f"🔍 Tespit edilen: <code>{method}</code>\n"
                                    f"✅ Gerekli: <code>chacha20-ietf-poly1305</code>\n\n"
                                    f"💡 Lütfen doğru şifreleme metoduyla bir anahtar girin.",
                                    parse_mode='HTML',
                                    reply_markup=self.get_back_to_menu_keyboard()
                                )
                                context.user_data.clear()
                                return
                            
                            logger.info(f"✅ Valid key received - Method: {method}, Password length: {len(password)}")
                    
                except Exception as e:
                    logger.warning(f"⚠️ Key validation warning: {e} - Continuing anyway...")
                    # Doğrulama hatası olsa bile devam et (esneklik için)
                
                # Anahtarı kaydet
                context.user_data['new_ss_key'] = new_key
                
                # Onay mesajı
                preview_key = new_key[:60] + '...' if len(new_key) > 60 else new_key
                confirmation_text = (
                    f"🔑 <b>Anahtar Güncelleme Onayı</b>\n\n"
                    f"📝 <b>Girilen Anahtar:</b>\n"
                    f"<code>{preview_key}</code>\n\n"
                    f"⚠️ <b>DİKKAT:</b>\n"
                    f"Bu işlem <b>TÜM ABONELİK LİNKLERİNDEKİ</b> ss:// anahtarları "
                    f"<b>TAMAMEN</b> bu yeni anahtar ile değiştirecektir!\n\n"
                    f"📊 <b>Etkilenecek:</b> <code>{len(self.database['keys'])}</code> anahtar\n\n"
                    f"✅ Tüm anahtarlar <b>AYNI</b> ss:// anahtarını kullanacak.\n\n"
                    f"❓ <b>Devam etmek istiyor musunuz?</b>"
                )
                
                keyboard = [
                    [InlineKeyboardButton("✅ Evet, Güncelle", callback_data="confirm_key_update")],
                    [InlineKeyboardButton("❌ İptal", callback_data="update_key_cancel")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await update.message.reply_text(
                    confirmation_text,
                    parse_mode='HTML',
                    reply_markup=reply_markup
                )
                
            except Exception as e:
                logger.error(f"❌ Error in waiting_new_key_input: {e}")
                await update.message.reply_text(
                    f"❌ <b>Anahtar işleme hatası!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_backup_ip_api_selection':
            # Yedek IP için API seçimi
            try:
                selected_api_id = text.strip().lower()
                
                # API kontrolü
                api_found = None
                for api_info in self.config['outline_apis']:
                    if api_info['id'].lower() == selected_api_id:
                        api_found = api_info
                        break
                
                if not api_found:
                    await update.message.reply_text(
                        f"❌ <b>API bulunamadı!</b>\n\n"
                        f"Girdiğiniz ID: <code>{selected_api_id}</code>\n\n"
                        f"💡 Lütfen geçerli bir API ID girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # API bilgilerini kaydet ve IP iste
                context.user_data['backup_ip_api_id'] = api_found['id']
                context.user_data['state'] = 'waiting_backup_ip_address'
                
                api_url = api_found['api']['apiUrl']
                original_ip = api_found.get('original_ip', self.get_ip_from_api_url(api_url))
                
                ip_input_text = (
                    f"➕ <b>Yedek IP Ekle</b>\n\n"
                    f"📊 <b>Seçilen API:</b> {api_found['name']}\n"
                    f"🆔 <b>ID:</b> <code>{api_found['id']}</code>\n"
                    f"🔵 <b>Ana IP:</b> <code>{original_ip}</code>\n\n"
                    f"📝 <b>Yeni yedek IP adresini girin:</b>\n"
                    f"(IPv4: 123.45.67.89 veya IPv6: 2001:db8::1)"
                )
                
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                await update.message.reply_text(ip_input_text, parse_mode='HTML', reply_markup=reply_markup)
                
            except Exception as e:
                logger.error(f"❌ Error in backup IP API selection: {e}")
                await update.message.reply_text(
                    "❌ API seçiminde hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_backup_ip_address':
            # Yedek IP adresi girişi - Master Key veya Normal API modu
            try:
                target_ip = text.strip()  # Hedef IP (yedek sunucu)
                api_id = context.user_data.get('backup_ip_api_id')
                
                # IP formatı kontrolü
                import ipaddress
                try:
                    ipaddress.ip_address(target_ip)
                except ValueError:
                    await update.message.reply_text(
                        f"❌ <b>Geçersiz IP formatı!</b>\n\n"
                        f"Girdiğiniz: <code>{target_ip}</code>\n\n"
                        f"💡 Geçerli format:\n"
                        f"• IPv4: 123.45.67.89\n"
                        f"• IPv6: 2001:db8::1",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # API bilgilerini al
                api_info = None
                for api in self.config['outline_apis']:
                    if api['id'] == api_id:
                        api_info = api
                        break
                
                if not api_info:
                    await update.message.reply_text(
                        "❌ <b>API bulunamadı!</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                api_url = api_info['api']['apiUrl']
                source_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))  # Kaynak IP (Outline)
                
                # Master key kontrolü
                master_ss_key = self.config.get('master_ss_key')
                
                if master_ss_key:
                    # MASTER KEY MODU - iptables yönlendirme
                    
                    # Master key'den IP ve PORT bilgisini al
                    import re
                    import base64
                    
                    master_key_ip = source_ip  # Varsayılan
                    master_key_port = self.config.get('outline_port', 444)
                    
                    # Master key'i parse et
                    if '@' in master_ss_key:
                        # Format: ss://BASE64@IP:PORT
                        ip_port_match = re.search(r'@([\d\.]+):(\d+)', master_ss_key)
                        if ip_port_match:
                            master_key_ip = ip_port_match.group(1)
                            master_key_port = int(ip_port_match.group(2))
                    else:
                        # Format: ss://BASE64 (IP Base64 içinde)
                        try:
                            key_part = master_ss_key[5:]
                            decoded = base64.b64decode(key_part + '==').decode('utf-8', errors='ignore')
                            ip_port_match = re.search(r'@([\d\.]+):(\d+)', decoded)
                            if ip_port_match:
                                master_key_ip = ip_port_match.group(1)
                                master_key_port = int(ip_port_match.group(2))
                        except:
                            pass
                    
                    # iptables yönlendirme komutları oluştur
                    iptables_commands = (
                        f"sudo sysctl -w net.ipv4.ip_forward=1\n"
                        f"sudo iptables -t nat -A PREROUTING -p tcp -d {target_ip} --dport {master_key_port} -j DNAT --to-destination {master_key_ip}\n"
                        f"sudo iptables -t nat -A POSTROUTING -p tcp -d {master_key_ip} --dport {master_key_port} -j MASQUERADE\n"
                        f"sudo iptables -t nat -A PREROUTING -p udp -d {target_ip} --dport {master_key_port} -j DNAT --to-destination {master_key_ip}\n"
                        f"sudo iptables -t nat -A POSTROUTING -p udp -d {master_key_ip} --dport {master_key_port} -j MASQUERADE"
                    )
                    
                    # Backup ID oluştur
                    backup_id = f"backup_ip_{int(time.time())}"
                    
                    # Veritabanına kaydet
                    self.database['backup_ips'][backup_id] = {
                        'ip': target_ip,
                        'api_id': api_id,
                        'created_at': time.time(),
                        'source_ip': master_key_ip,
                        'port': master_key_port,
                        'deployment_method': 'iptables'
                    }
                    self.save_database()
                    
                    # Sonuç mesajı (iptables)
                    result_text = (
                        f"✅ <b>Yedek IP - iptables Kurulum (Master Key)</b>\n\n"
                        f"📊 <b>API:</b> {api_info['name']}\n"
                        f"🆔 <b>API ID:</b> <code>{api_id}</code>\n\n"
                        f"🔵 <b>Kaynak (Master Key):</b> <code>{master_key_ip}:{master_key_port}</code>\n"
                        f"🟢 <b>Hedef (Yedek IP):</b> <code>{target_ip}:{master_key_port}</code>\n"
                        f"🔌 <b>Port:</b> <code>{master_key_port}</code> (TCP + UDP)\n\n"
                        f"📋 <b>iptables Yönlendirme Komutları:</b>\n\n"
                        f"<b>Yedek sunucuda bu komutları çalıştırın (her satırı sırayla):</b>\n\n"
                        f"<code>{iptables_commands}</code>\n\n"
                        f"⚠️ <b>Önemli:</b>\n"
                        f"• Master key tek port kullanır\n"
                        f"• Komutlar yedek sunucuda çalıştırılmalı\n"
                        f"• TCP ve UDP trafiği yönlendirilecek\n"
                        f"✅ Kurulum sonrası client'lar yedek IP'den bağlanabilir"
                    )
                    
                    logger.info(f"✅ Master Key backup IP (iptables): {target_ip} → {master_key_ip}:{master_key_port} (API: {api_id})")
                    await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                    context.user_data.clear()
                    return
                
                # NORMAL MOD - iptables deployment
                iptables_commands = (
                    f"sudo sysctl -w net.ipv4.ip_forward=1\n"
                    f"sudo iptables -t nat -A PREROUTING -p tcp -d {target_ip} --dport 444:999 -j DNAT --to-destination {source_ip}\n"
                    f"sudo iptables -t nat -A POSTROUTING -p tcp -d {source_ip} --dport 444:999 -j MASQUERADE\n"
                    f"sudo iptables -A FORWARD -p tcp -d {source_ip} --dport 444:999 -j ACCEPT\n"
                    f"sudo iptables -t nat -A PREROUTING -p udp -d {target_ip} --dport 444:999 -j DNAT --to-destination {source_ip}\n"
                    f"sudo iptables -t nat -A POSTROUTING -p udp -d {source_ip} --dport 444:999 -j MASQUERADE\n"
                    f"sudo iptables -A FORWARD -p udp -d {source_ip} --dport 444:999 -j ACCEPT"
                )

                # Backup ID oluştur
                backup_id = f"backup_ip_{int(time.time())}"

                # Veritabanına kaydet
                self.database['backup_ips'][backup_id] = {
                    'ip': target_ip,
                    'api_id': api_id,
                    'created_at': time.time(),
                    'source_ip': source_ip,
                    'port_range': '444-999',
                    'deployment_method': 'iptables'
                }
                self.save_database()

                # Sonuç mesajı
                result_text = (
                    f"✅ <b>Yedek IP - iptables Kurulum Hazır!</b>\n\n"
                    f"📊 <b>API:</b> {api_info['name']}\n"
                    f"🆔 <b>API ID:</b> <code>{api_id}</code>\n\n"
                    f"🔵 <b>Kaynak (Outline):</b> <code>{source_ip}</code>\n"
                    f"🟢 <b>Hedef (Yedek):</b> <code>{target_ip}</code>\n"
                    f"🔌 <b>Port Aralığı:</b> <code>444-999</code> (556 port)\n\n"
                    f"📋 <b>Hedef sunucuda bu komutları çalıştırın (her satırı sırayla):</b>\n\n"
                    f"<code>{iptables_commands}</code>\n\n"
                    f"⚠️ <b>Önemli:</b>\n"
                    f"• Tüm portlar (444-999) yönlendirilecek\n"
                    f"• TCP ve UDP desteği aktif olacak"
                )

                logger.info(f"✅ Backup IP iptables deployment ready: {target_ip} → {source_ip} (API: {api_id})")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error adding backup IP: {e}")
                await update.message.reply_text(
                    f"❌ <b>Yedek IP eklenirken hata oluştu!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_delete_backup_ip':
            # Yedek IP silme
            try:
                backup_id = text.strip()
                
                if backup_id not in self.database.get('backup_ips', {}):
                    await update.message.reply_text(
                        f"❌ <b>Yedek IP bulunamadı!</b>\n\n"
                        f"Girdiğiniz ID: <code>{backup_id}</code>\n\n"
                        f"💡 Lütfen geçerli bir backup ID girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # Bilgileri al ve sil
                backup_info = self.database['backup_ips'][backup_id]
                ip = backup_info['ip']
                api_id = backup_info['api_id']
                
                del self.database['backup_ips'][backup_id]
                self.save_database()
                
                result_text = (
                    f"✅ <b>Yedek IP Silindi!</b>\n\n"
                    f"🌐 <b>IP:</b> <code>{ip}</code>\n"
                    f"📊 <b>API:</b> <code>{api_id}</code>\n"
                    f"🆔 <b>Backup ID:</b> <code>{backup_id}</code>\n\n"
                    f"⚠️ <b>Not:</b> iptables kuralları sunucuda manuel temizlenmelidir.\n"
                    f"💡 Sunucuda özel işlem gerekmez."
                )
                
                logger.info(f"✅ Backup IP deleted: {ip} (ID: {backup_id})")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error deleting backup IP: {e}")
                await update.message.reply_text(
                    "❌ Yedek IP silinirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_restore_backup':
            # Yedek geri yükleme
            try:
                import os
                
                backup_filename = text.strip()
                backup_dir = "/opt/outline-telegram-bot/backups"
                backup_path = os.path.join(backup_dir, backup_filename)
                
                if not os.path.exists(backup_path):
                    await update.message.reply_text(
                        f"❌ <b>Yedek bulunamadı!</b>\n\n"
                        f"Dosya: <code>{backup_filename}</code>\n\n"
                        f"💡 Lütfen geçerli bir yedek dosya adı girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # Yedek dosyasını oku
                with open(backup_path, 'r') as f:
                    backup_data = json.load(f)
                
                await update.message.reply_text("⏳ <b>Yedek geri yükleniyor...</b>", parse_mode='HTML')
                
                # Mevcut veritabanını yedekle (önce, varsa)
                current_backup_path = f"/opt/outline-telegram-bot/database.json.before_restore.{int(time.time())}"
                import shutil
                if os.path.exists(self.config['database']['path']):
                    shutil.copy(self.config['database']['path'], current_backup_path)
                
                # Veritabanını geri yükle
                self.database = backup_data['database']
                self.save_database()
                self._sync_used_ports_from_database()
                
                # Config'i geri yükle (API'ler)
                if 'config' in backup_data:
                    self.config['outline_apis'] = backup_data['config']['outline_apis']
                    self.save_config()
                
                # ÖNEMLİ: API'deki mevcut anahtarları temizle ve yeniden oluştur
                await update.message.reply_text("🧹 <b>API temizleniyor ve anahtarlar yeniden oluşturuluyor...</b>", parse_mode='HTML')
                update_result = await self.update_keys_with_new_api()
                
                restored_keys = len(backup_data['database']['keys'])
                restored_apis = len(backup_data['config']['outline_apis'])
                restored_backup_ips = len(backup_data['database'].get('backup_ips', {}))
                
                # Süre bilgisi
                duration_info = ""
                if 'duration' in update_result and update_result['duration'] > 60:
                    duration_info = f"\n⏱️ <b>İşlem Süresi:</b> {update_result['duration']} saniye"
                
                current_port = self.config.get('outline_port', 444)
                result_text = (
                    f"✅ <b>Yedek Geri Yüklendi!</b>\n\n"
                    f"📁 <b>Dosya:</b> <code>{backup_filename}</code>\n"
                    f"🕐 <b>Yedek Tarihi:</b> {backup_data.get('created_at', 'Bilinmeyen')}\n\n"
                    f"♻️ <b>Geri Yüklenen Veriler:</b>\n"
                    f"• Anahtarlar: <code>{restored_keys}</code> adet\n"
                    f"• API'ler: <code>{restored_apis}</code> adet\n"
                    f"• Yedek IP'ler: <code>{restored_backup_ips}</code> adet\n\n"
                    f"🔨 <b>API Yenileme:</b>\n"
                    f"• Temizlenen: <code>{update_result.get('cleaned', 0)}</code> anahtar\n"
                    f"• Yeniden oluşturulan: <code>{update_result.get('created', 0)}</code> anahtar"
                    f"{duration_info}\n"
                    f"• Port: <code>444-999</code>\n\n"
                    f"🔒 <b>Güvenlik:</b>\n"
                    + (f"Eski veritabanı yedeklendi:\n<code>{current_backup_path}</code>\n\n" if os.path.exists(current_backup_path) else "Temiz kurulum — önceki veritabanı yok.\n\n")
                    + f"✅ Tüm anahtarlar <code>444-999</code> port aralığında yeniden oluşturuldu!"
                )
                
                logger.info(f"✅ Backup restored: {backup_filename} ({restored_keys} keys, {restored_apis} APIs, {update_result.get('created', 0)} recreated)")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error restoring backup: {e}")
                await update.message.reply_text(
                    f"❌ <b>Yedek geri yüklenirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_delete_backup':
            # Yedek silme
            try:
                import os
                
                backup_filename = text.strip()
                backup_dir = "/opt/outline-telegram-bot/backups"
                backup_path = os.path.join(backup_dir, backup_filename)
                
                if not os.path.exists(backup_path):
                    await update.message.reply_text(
                        f"❌ <b>Yedek bulunamadı!</b>\n\n"
                        f"Dosya: <code>{backup_filename}</code>\n\n"
                        f"💡 Lütfen geçerli bir yedek dosya adı girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    return
                
                # Dosyayı sil
                os.remove(backup_path)
                
                result_text = (
                    f"✅ <b>Yedek Silindi!</b>\n\n"
                    f"📁 <b>Dosya:</b> <code>{backup_filename}</code>\n\n"
                    f"🗑️ Yedek dosyası kalıcı olarak silindi."
                )
                
                logger.info(f"✅ Backup deleted: {backup_filename}")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error deleting backup: {e}")
                await update.message.reply_text(
                    f"❌ <b>Yedek silinirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_delete_api':
            # API silme
            try:
                api_id_to_delete = text.strip().lower()
                
                # api1 kontrolü
                if api_id_to_delete == 'api1':
                    await update.message.reply_text(
                        "❌ <b>Ana API Silinemez!</b>\n\n"
                        "🔒 api1 (ana API) sistem tarafından korunmaktadır.\n"
                        "Bu API silinemez.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # API'yi bul
                api_to_delete = None
                for api_info in self.config['outline_apis']:
                    if api_info['id'] == api_id_to_delete:
                        api_to_delete = api_info
                        break
                
                if not api_to_delete:
                    await update.message.reply_text(
                        f"❌ <b>API Bulunamadı!</b>\n\n"
                        f"🔍 <code>{api_id_to_delete}</code> ID'li API bulunamadı.\n"
                        f"Lütfen geçerli bir API ID girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Anahtarları sil
                await update.message.reply_text(
                    f"🔄 <b>API Siliniyor...</b>\n\n"
                    f"📝 API: {api_to_delete['name']}\n"
                    f"🔑 Anahtar Sayısı: {len(api_to_delete['keys'])}",
                    parse_mode='HTML'
                )
                
                deleted_keys = 0
                for key_id in api_to_delete['keys']:
                    try:
                        # Database'den outline_key_id'yi al
                        if key_id in self.database['keys']:
                            outline_key_id = self.database['keys'][key_id].get('outline_key_id')
                            key_port = self.database['keys'][key_id].get('port')  # Port bilgisi
                            if outline_key_id:
                                await self.delete_outline_key(outline_key_id, api_id=api_id_to_delete, port=key_port)
                            # Database'den de sil
                            del self.database['keys'][key_id]
                            deleted_keys += 1
                    except Exception as e:
                        logger.error(f"Error deleting key {key_id}: {e}")
                
                # Config'den API'yi kaldır
                self.config['outline_apis'] = [
                    api for api in self.config['outline_apis'] 
                    if api['id'] != api_id_to_delete
                ]
                self.save_config()
                self.save_database()
                
                result_text = (
                    f"✅ <b>API Başarıyla Silindi!</b>\n\n"
                    f"🗑️ <b>Silinen API:</b> {api_to_delete['name']}\n"
                    f"🆔 <b>API ID:</b> <code>{api_id_to_delete}</code>\n"
                    f"🔑 <b>Silinen Anahtar:</b> {deleted_keys}\n\n"
                    f"📊 <b>Kalan API:</b> {len(self.config['outline_apis'])}\n\n"
                    f"✅ Tüm anahtarlar ve veriler temizlendi."
                )
                
                logger.info(f"✅ API deleted: {api_id_to_delete} ({deleted_keys} keys)")
                await update.message.reply_text(
                    result_text, 
                    parse_mode='HTML', 
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                
            except Exception as e:
                logger.error(f"❌ Error deleting API: {e}")
                await update.message.reply_text(
                    f"❌ <b>API silinirken hata oluştu!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_move_source_api':
            # Kaynak API seçimi
            try:
                source_api_id = text.strip().lower()
                source_apis = context.user_data.get('source_apis', [])
                
                if source_api_id not in source_apis:
                    await update.message.reply_text(
                        f"❌ <b>Geçersiz API ID!</b>\n\n"
                        f"✅ Geçerli API'ler: {', '.join(source_apis)}",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Kaynak API bilgilerini al
                source_api_info = self.get_api_by_id(source_api_id)
                if not source_api_info:
                    await update.message.reply_text(
                        "❌ API bulunamadı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Kaynak API'deki anahtarları oluşturulma zamanına göre sırala
                source_keys = []
                for key_id in source_api_info['keys']:
                    if key_id in self.database['keys']:
                        source_keys.append(key_id)
                
                # Oluşturulma zamanına göre sırala
                sorted_source_keys = sorted(
                    source_keys,
                    key=lambda k: self.database['keys'][k].get('created_at', 0)
                )
                
                total_keys = len(sorted_source_keys)
                
                if total_keys == 0:
                    await update.message.reply_text(
                        "❌ Bu API'de anahtar yok!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                context.user_data['move_source_api_id'] = source_api_id
                context.user_data['move_sorted_keys'] = sorted_source_keys
                context.user_data['state'] = 'waiting_move_range'
                
                range_text = (
                    f"🔀 <b>Anahtar Taşıma - Aralık Seç</b>\n\n"
                    f"📊 <b>Kaynak API:</b> {source_api_info['name']}\n"
                    f"🔑 <b>Toplam Anahtar:</b> {total_keys}\n\n"
                    f"⏱️ <b>Sıralama:</b> Oluşturulma zamanına göre (en eski → en yeni)\n\n"
                    f"📝 <b>Format:</b> BAŞLANGIÇ-BİTİŞ\n\n"
                    f"💡 <b>Örnekler:</b>\n"
                    f"• <code>1-50</code> → İlk 50 anahtar\n"
                    f"• <code>25-50</code> → 25. ile 50. anahtar arası\n"
                    f"• <code>50-son</code> → 50. anahtardan sona kadar\n"
                    f"• <code>1-son</code> → Tüm anahtarlar\n\n"
                    f"✏️ Aralığı girin:"
                )
                
                await update.message.reply_text(range_text, parse_mode='HTML')
                
            except Exception as e:
                logger.error(f"❌ Error in move_source_api: {e}")
                await update.message.reply_text(
                    "❌ Hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_move_range':
            # Taşınacak aralık seçimi
            try:
                range_input = text.strip()
                sorted_keys = context.user_data.get('move_sorted_keys', [])
                total_keys = len(sorted_keys)
                
                # Aralığı parse et
                import re
                match = re.match(r'^(\d+)-(\d+|son)$', range_input.lower())
                
                if not match:
                    await update.message.reply_text(
                        "❌ Geçersiz format!\n"
                        "Doğru format: 1-50, 25-50, 50-son",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                start = int(match.group(1))
                end = total_keys if match.group(2) == 'son' else int(match.group(2))
                
                # Aralık kontrolü
                if start < 1 or start > total_keys:
                    await update.message.reply_text(
                        f"❌ Başlangıç değeri 1-{total_keys} arasında olmalı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                if end > total_keys:
                    end = total_keys
                
                if start > end:
                    await update.message.reply_text(
                        "❌ Başlangıç değeri bitiş değerinden büyük olamaz!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Seçili anahtarlar
                selected_keys = sorted_keys[start-1:end]
                
                context.user_data['move_range_start'] = start
                context.user_data['move_range_end'] = end
                context.user_data['move_selected_keys'] = selected_keys
                context.user_data['state'] = 'waiting_move_target_api'
                
                # Hedef API listesi (sadece kaynak API hariç)
                source_api_id = context.user_data.get('move_source_api_id')
                target_api_list = "🔀 <b>Anahtar Taşıma - Hedef API Seç</b>\n\n"
                target_api_list += f"📊 <b>Taşınacak:</b> {end - start + 1} anahtar ({start}-{end})\n\n"
                target_api_list += f"🎯 <b>Hedef API Seçenekleri:</b>\n\n"
                
                # API'leri sırala: api1 önce, sonra diğerleri
                sorted_apis = sorted(
                    self.config['outline_apis'],
                    key=lambda x: (x['id'] != 'api1', x['id'])
                )
                
                target_apis = []
                for idx, api_info in enumerate(sorted_apis, 1):
                    api_id = api_info['id']
                    # Sadece kaynak API'yi gösterme (api1 dahil edilebilir)
                    if api_id != source_api_id:
                        api_url = api_info['api']['apiUrl']
                        original_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))
                        key_count = len(api_info['keys'])
                        
                        # İsimlendirme
                        if api_id == 'api1':
                            display_name = f"Ana API ({original_ip})"
                        else:
                            display_name = f"Yedek API - {api_id.upper()} ({original_ip})"
                        
                        target_api_list += f"<b>{idx}. {display_name}</b>\n"
                        target_api_list += f"   🆔 ID: <code>{api_id}</code>\n"
                        target_api_list += f"   🔑 Mevcut Anahtar: {key_count}\n\n"
                        target_apis.append(api_id)
                
                if not target_apis:
                    await update.message.reply_text(
                        "❌ <b>Hedef API bulunamadı!</b>\n\n"
                        "💡 Kaynak API dışında başka API yok.\n"
                        "⚠️ Aynı API içinde anahtar taşınamaz!\n\n"
                        "Lütfen önce yeni API ekleyin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                target_api_list += f"❓ <b>Hangi API'ye taşımak istiyorsunuz?</b>\n\n"
                target_api_list += f"✏️ API ID yazın (örnek: <code>{target_apis[0]}</code>)\n\n"
                target_api_list += f"ℹ️ <b>Not:</b> Kaynak ve hedef API farklı olmalıdır."
                
                context.user_data['target_apis'] = target_apis
                
                # Ana menü butonu ekle
                keyboard = [[InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await update.message.reply_text(target_api_list, parse_mode='HTML', reply_markup=reply_markup)
                
            except Exception as e:
                logger.error(f"❌ Error in move_range: {e}")
                await update.message.reply_text(
                    "❌ Hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_move_target_api':
            # Hedef API seçimi ve taşıma işlemi
            try:
                target_api_id = text.strip().lower()
                target_apis = context.user_data.get('target_apis', [])
                
                if target_api_id not in target_apis:
                    await update.message.reply_text(
                        f"❌ <b>Geçersiz API ID!</b>\n\n"
                        f"✅ Geçerli API'ler: {', '.join(target_apis)}",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Bilgileri al
                source_api_id = context.user_data.get('move_source_api_id')
                selected_keys = context.user_data.get('move_selected_keys', [])
                start = context.user_data.get('move_range_start')
                end = context.user_data.get('move_range_end')
                
                source_api_info = self.get_api_by_id(source_api_id)
                target_api_info = self.get_api_by_id(target_api_id)
                
                await update.message.reply_text(
                    f"🔄 <b>Anahtarlar taşınıyor...</b>\n\n"
                    f"📤 Kaynak: {source_api_info['name']}\n"
                    f"📥 Hedef: {target_api_info['name']}\n"
                    f"🔑 Anahtar: {len(selected_keys)}"
                )
                
                moved_count = 0
                failed_count = 0
                
                for key_id in selected_keys:
                    try:
                        key_data = self.database['keys'][key_id]
                        port = key_data['port']
                        custom_id = self.get_custom_id(key_id)
                        
                        # Eski anahtarı sil
                        old_outline_key_id = key_data.get('outline_key_id')
                        old_key_port = key_data.get('port')  # Port bilgisi
                        if old_outline_key_id:
                            try:
                                await self.delete_outline_key(old_outline_key_id, api_id=source_api_id, port=old_key_port)
                                logger.info(f"Deleted key {old_outline_key_id} from {source_api_id}")
                            except Exception as e:
                                logger.warning(f"Could not delete old key: {e}")
                        
                        # Yeni API'de oluştur
                        new_outline_key = await self.create_outline_key(
                            f"vip-user-{custom_id}",
                            port,
                            api_id=target_api_id
                        )
                        
                        # ss_url'deki IP'yi güncelle
                        new_ss_url = new_outline_key['accessUrl']
                        target_original_ip = target_api_info.get('original_ip')
                        if target_original_ip and target_original_ip in new_ss_url:
                            target_current_ip = self.get_ip_from_api_url(target_api_info['api']['apiUrl'])
                            if target_current_ip and target_original_ip != target_current_ip:
                                new_ss_url = new_ss_url.replace(target_original_ip, target_current_ip)
                        
                        # Database güncelle
                        self.database['keys'][key_id]['outline_key_id'] = new_outline_key['id']
                        self.database['keys'][key_id]['ss_url'] = new_ss_url
                        self.database['keys'][key_id]['api_id'] = target_api_id
                        
                        # Config güncelle
                        if key_id in source_api_info['keys']:
                            source_api_info['keys'].remove(key_id)
                        if key_id not in target_api_info['keys']:
                            target_api_info['keys'].append(key_id)
                        
                        moved_count += 1
                        logger.info(f"✅ Moved key {key_id[:12]}... from {source_api_id} to {target_api_id}")
                        
                    except Exception as e:
                        failed_count += 1
                        logger.error(f"❌ Error moving key {key_id}: {e}")
                
                self.save_config()
                self.save_database()
                
                result_text = (
                    f"✅ <b>Anahtar Taşıma Tamamlandı!</b>\n\n"
                    f"📊 <b>Sonuçlar:</b>\n"
                    f"• Aralık: {start}-{end}\n"
                    f"• ✅ Taşınan: {moved_count}\n"
                    f"• ❌ Başarısız: {failed_count}\n\n"
                    f"📤 <b>Kaynak:</b> {source_api_info['name']}\n"
                    f"   • Kalan: {len(source_api_info['keys'])} anahtar\n\n"
                    f"📥 <b>Hedef:</b> {target_api_info['name']}\n"
                    f"   • Toplam: {len(target_api_info['keys'])} anahtar"
                )
                
                logger.info(f"✅ Key move completed: {moved_count} moved, {failed_count} failed")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error in move_target_api: {e}")
                await update.message.reply_text(
                    "❌ Taşıma sırasında hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_new_ip':
            # Yeni IP ile anahtarları güncelle (Tek API veya Seçili API)
            try:
                new_ip = text.strip()
                logger.info(f"Received IP update request: {new_ip}")
                
                # IP formatını doğrula
                import re
                ipv4_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
                ipv6_pattern = r'^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'
                
                is_valid_ip = re.match(ipv4_pattern, new_ip) or re.match(ipv6_pattern, new_ip)
                
                if not is_valid_ip:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz IP adresi!</b>\n\n"
                        "✅ <b>Geçerli formatlar:</b>\n"
                        "• IPv4: <code>123.45.67.89</code>\n"
                        "• IPv6: <code>2001:db8::1</code>\n\n"
                        "✏️ Lütfen geçerli bir IP adresi girin:",
                        parse_mode='HTML'
                    )
                    return
                
                if not self.database['keys']:
                    await update.message.reply_text(
                        "❌ Güncellenecek anahtar yok!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Seçili API ID'yi al (çoklu API için)
                selected_api_id = context.user_data.get('selected_api_id') or context.user_data.get('single_api_id')
                
                # Eski IP'yi tespit et - GELİŞMİŞ YÖNTEM
                # ÖNEMLİ: ss_url'lerden tespit et, API URL'den değil!
                # Çünkü IP güncellemesi yapıldıktan sonra ss_url'deki IP değişir ama API URL değişmez
                old_ip = None
                detection_method = None
                
                # 1. SEÇİLİ API'nin anahtarlarından mevcut IP'yi tespit et
                from collections import Counter
                import base64
                
                detected_ips = []
                
                # SEÇİLİ API'ye ait anahtarları filtrele (ÖNEMLİ!)
                keys_to_check = []
                if selected_api_id:
                    # SADECE seçili API'nin anahtarlarından IP al
                    for key_id, key_data in self.database['keys'].items():
                        if key_data.get('api_id') == selected_api_id:
                            keys_to_check.append((key_id, key_data))
                    
                    if not keys_to_check:
                        logger.warning(f"⚠️ No keys found for API {selected_api_id}")
                    else:
                        logger.info(f"🔍 Checking {len(keys_to_check)} keys from API {selected_api_id}")
                else:
                    # Tüm anahtarlar
                    keys_to_check = list(self.database['keys'].items())
                    logger.info(f"🔍 Checking all {len(keys_to_check)} keys")
                
                # Seçili API'nin anahtarlarından IP'leri çıkar
                for key_id, key_data in keys_to_check:
                    ss_url = key_data.get('ss_url', '')
                    
                    try:
                        # ss:// formatı için
                        if ss_url.startswith('ss://'):
                            # Method 1: Direkt regex ile IP bul
                            ipv4_match = re.search(r'@([\d\.]+):', ss_url)
                            if ipv4_match:
                                detected_ips.append(ipv4_match.group(1))
                                continue
                            
                            ipv6_match = re.search(r'@\[([0-9a-fA-F:]+)\]:', ss_url)
                            if ipv6_match:
                                detected_ips.append(ipv6_match.group(1))
                                continue
                            
                            # Method 2: Base64 decode
                            try:
                                encoded = ss_url[5:].split('#')[0]
                                if '@' in encoded:
                                    # Encoded değil
                                    ip_part = encoded.split('@')[1].split(':')[0].strip('[]')
                                    detected_ips.append(ip_part)
                                else:
                                    # Base64 encoded - Cache kontrolü
                                    if encoded in self.base64_decode_cache:
                                        decoded = self.base64_decode_cache[encoded]
                                        logger.debug(f"✨ Cache hit for IP detection")
                                    else:
                                        decoded = base64.b64decode(encoded + '==').decode('utf-8', errors='ignore')
                                        # Cache'e ekle
                                        if len(self.base64_decode_cache) < 1000:
                                            self.base64_decode_cache[encoded] = decoded
                                    
                                    if '@' in decoded:
                                        ip_part = decoded.split('@')[1].split(':')[0].strip('[]')
                                        detected_ips.append(ip_part)
                            except:
                                pass
                        
                        # ssconf:// formatı için
                        elif ss_url.startswith('ssconf://'):
                            # ssconf formatında IP bulma
                            pass
                        
                        # Diğer formatlar için genel regex
                        else:
                            # Herhangi bir IP pattern ara
                            ipv4_all = re.findall(r'\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b', ss_url)
                            if ipv4_all:
                                detected_ips.extend(ipv4_all)
                            
                    except Exception as e:
                        logger.error(f"Error parsing IP from key {key_id[:12]}: {e}")
                
                # En çok geçen IP'yi seç (seçili API'nin mevcut IP'si)
                if detected_ips:
                    ip_counter = Counter(detected_ips)
                    old_ip = ip_counter.most_common(1)[0][0]
                    api_name_log = f"API {selected_api_id}" if selected_api_id else "all APIs"
                    detection_method = f"ss_url from {api_name_log} ({ip_counter[old_ip]}/{len(keys_to_check)} keys)"
                    logger.info(f"✅ Detected current IP from {api_name_log} ss_urls: {old_ip} (found in {ip_counter[old_ip]} keys)")
                
                # 2. Son çare: API URL'den al (sadece hiç anahtar yoksa)
                if not old_ip and selected_api_id:
                    api_info = self.get_api_by_id(selected_api_id)
                    if api_info:
                        old_ip = self.get_ip_from_api_url(api_info['api']['apiUrl'])
                        if old_ip:
                            detection_method = "API URL (no keys found)"
                            logger.info(f"✅ Using IP from API URL: {old_ip}")
                
                if not old_ip:
                    # Manuel giriş talep et
                    await update.message.reply_text(
                        "❌ <b>Mevcut IP adresi tespit edilemedi!</b>\n\n"
                        "📊 <b>Neden?</b>\n"
                        "• Anahtarlar farklı formatlarda olabilir\n"
                        "• ss_url encode edilmiş olabilir\n"
                        "• Hiç anahtar oluşturulmamış olabilir\n\n"
                        "💡 <b>Çözüm:</b> Manuel olarak girin:\n\n"
                        "<b>Format:</b> <code>ESKİ_IP,YENİ_IP</code>\n\n"
                        "<b>Örnek:</b> <code>11.22.33.44,55.66.77.88</code>\n\n"
                        "✏️ Lütfen eski ve yeni IP'yi girin:",
                        parse_mode='HTML'
                    )
                    # State'i değiştirme, aynı state'te kal
                    context.user_data['state'] = 'waiting_new_ip_manual'
                    return
                
                logger.info(f"✅ IP detection successful: {old_ip} (method: {detection_method})")
                
                # Hangi anahtarlar güncellenecek?
                if selected_api_id:
                    # Sadece seçili API'nin anahtarları
                    api_info = self.get_api_by_id(selected_api_id)
                    api_name = api_info['name'] if api_info else "Bilinmeyen API"
                    
                    # Database'den bu API'ye ait anahtarları bul
                    keys_to_update = []
                    keys_without_api_id = 0
                    
                    for key_id, key_data in self.database['keys'].items():
                        # Anahtar bu API'ye ait mi kontrol et
                        if key_data.get('api_id') == selected_api_id:
                            keys_to_update.append(key_id)
                        # api_id yoksa VE tek API varsa, o API'ye ata
                        elif 'api_id' not in key_data:
                            keys_without_api_id += 1
                            # Tek API varsa veya ss_url'deki IP bu API'ye aitse
                            if len(self.config['outline_apis']) == 1:
                                # Tek API var, tüm anahtarlar ona ait
                                keys_to_update.append(key_id)
                                # api_id'yi otomatik ekle
                                self.database['keys'][key_id]['api_id'] = selected_api_id
                                logger.info(f"Auto-assigned api_id={selected_api_id} to key {key_id}")
                            else:
                                # Çoklu API var, ss_url'den IP'ye bakarak eşleştir
                                ss_url = key_data.get('ss_url', '')
                                api_url = api_info['api']['apiUrl']
                                api_ip = self.get_ip_from_api_url(api_url)
                                
                                if api_ip and api_ip in ss_url:
                                    keys_to_update.append(key_id)
                                    # api_id'yi otomatik ekle
                                    self.database['keys'][key_id]['api_id'] = selected_api_id
                                    logger.info(f"Matched and assigned api_id={selected_api_id} to key {key_id} by IP {api_ip}")
                    
                    # Değişiklikleri kaydet
                    if keys_without_api_id > 0:
                        self.save_database()
                    
                    logger.info(f"Found {len(keys_to_update)} keys for API {selected_api_id} (auto-fixed {keys_without_api_id} keys without api_id)")
                else:
                    # Tüm anahtarlar
                    keys_to_update = list(self.database['keys'].keys())
                    api_name = "Tüm API'ler"
                
                # Original IP'yi al - Backup IP kontrolü
                original_ip_display = old_ip
                if selected_api_id:
                    api_info = self.get_api_by_id(selected_api_id)
                    if api_info:
                        original_ip_display = api_info.get('original_ip', old_ip)
                        
                        # BACKUP IP KONTROLÜ: Eğer old_ip bir backup IP ise, orijinal IP'yi bul
                        backup_ips_db = self.database.get('backup_ips', {})
                        for backup_id, backup_data in backup_ips_db.items():
                            if backup_data.get('api_id') == selected_api_id and backup_data.get('ip') == old_ip:
                                # Bu bir backup IP! Orijinal IP'yi kullan
                                original_ip_display = backup_data.get('original_ip', original_ip_display)
                                logger.info(f"✅ Detected backup IP: {old_ip} → original: {original_ip_display}")
                                break
                
                # Dinamik port al
                current_port = self.config.get('outline_port', 444)
                
                # Onay mesajı - iptables deployment için
                confirm_text = (
                    f"🔄 <b>IP Adresi Güncelleme - iptables Deployment</b>\n\n"
                    f"📊 <b>API:</b> {api_name}\n"
                    f"🔑 <b>Güncellenecek:</b> {len(keys_to_update)} anahtar\n\n"
                    f"🔵 <b>Kaynak (Outline):</b> <code>{original_ip_display}</code>\n"
                    f"🟢 <b>Hedef (Yeni IP):</b> <code>{new_ip}</code>\n"
                    f"🔌 <b>Port Aralığı:</b> <code>444-999</code> (556 port)\n\n"
                    f"⚡ <b>İşlem:</b>\n"
                    f"1️⃣ Tüm anahtarların IP'si güncellenir\n"
                    f"2️⃣ iptables yönlendirme komutları oluşturulur\n"
                    f"3️⃣ Yeni sunucuda tek komut ile 556 port yönlendirilir\n\n"
                    f"❓ <b>Devam etmek istiyor musunuz?</b>"
                )
                
                # IP'leri encode et (| ayırıcı + API ID)
                encoded_data = f"{new_ip}|{old_ip}|{selected_api_id or 'all'}"
                
                # Onay butonları
                keyboard = [
                    [InlineKeyboardButton("✅ Onayla", callback_data=f"confirm_ip_update_{encoded_data}")],
                    [InlineKeyboardButton("❌ İptal", callback_data="cancel_ip_update")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await update.message.reply_text(confirm_text, parse_mode='HTML', reply_markup=reply_markup)
                
                # State'i temizle (buton callback'i yapacak)
                context.user_data.clear()
                
            except Exception as e:
                logger.error(f"IP validation error: {e}")
                logger.error(f"Exception details: {traceback.format_exc()}")
                reply_markup = self.get_back_to_menu_keyboard()
                await update.message.reply_text(
                    "❌ IP doğrulama hatası!",
                    reply_markup=reply_markup
                )
                context.user_data.clear()
        
        # Not: confirm_ip_update artık buton callback ile yapılıyor (yukarıda)
        # Eski mesaj handler kaldırıldı
        
        elif state == 'waiting_new_ip_manual':
            # Manuel IP girişi - ESKİ_IP,YENİ_IP formatı
            try:
                input_text = text.strip()
                
                # Virgül ile ayır
                if ',' not in input_text:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz format!</b>\n\n"
                        "✅ <b>Doğru format:</b> <code>ESKİ_IP,YENİ_IP</code>\n\n"
                        "<b>Örnek:</b> <code>11.22.33.44,55.66.77.88</code>\n\n"
                        "✏️ Lütfen tekrar girin:",
                        parse_mode='HTML'
                    )
                    return
                
                parts = input_text.split(',')
                if len(parts) != 2:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz format!</b>\n\n"
                        "✅ <b>Doğru format:</b> <code>ESKİ_IP,YENİ_IP</code>\n\n"
                        "<b>Örnek:</b> <code>11.22.33.44,55.66.77.88</code>\n\n"
                        "✏️ Lütfen tekrar girin:",
                        parse_mode='HTML'
                    )
                    return
                
                old_ip = parts[0].strip()
                new_ip = parts[1].strip()
                
                # IP formatını doğrula
                import re
                ipv4_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
                ipv6_pattern = r'^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'
                
                is_valid_old = re.match(ipv4_pattern, old_ip) or re.match(ipv6_pattern, old_ip)
                is_valid_new = re.match(ipv4_pattern, new_ip) or re.match(ipv6_pattern, new_ip)
                
                if not is_valid_old or not is_valid_new:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz IP adresi!</b>\n\n"
                        "✅ <b>Geçerli formatlar:</b>\n"
                        "• IPv4: <code>123.45.67.89</code>\n"
                        "• IPv6: <code>2001:db8::1</code>\n\n"
                        "<b>Format:</b> <code>ESKİ_IP,YENİ_IP</code>\n\n"
                        "✏️ Lütfen tekrar girin:",
                        parse_mode='HTML'
                    )
                    return
                
                logger.info(f"✅ Manual IP input: {old_ip} → {new_ip}")
                
                # Seçili API ID'yi al
                selected_api_id = context.user_data.get('selected_api_id') or context.user_data.get('single_api_id')
                
                # Hangi anahtarlar güncellenecek?
                if selected_api_id:
                    api_info = self.get_api_by_id(selected_api_id)
                    api_name = api_info['name'] if api_info else "Bilinmeyen API"
                    
                    # Database'den bu API'ye ait anahtarları bul
                    keys_to_update = []
                    for key_id, key_data in self.database['keys'].items():
                        if key_data.get('api_id') == selected_api_id:
                            keys_to_update.append(key_id)
                        elif 'api_id' not in key_data and len(self.config['outline_apis']) == 1:
                            keys_to_update.append(key_id)
                            self.database['keys'][key_id]['api_id'] = selected_api_id
                else:
                    # Tüm anahtarlar
                    keys_to_update = list(self.database['keys'].keys())
                    api_name = "Tüm API'ler"
                
                # Original IP'yi al - Backup IP kontrolü
                original_ip_display = old_ip
                if selected_api_id:
                    api_info = self.get_api_by_id(selected_api_id)
                    if api_info:
                        original_ip_display = api_info.get('original_ip', old_ip)
                        
                        # BACKUP IP KONTROLÜ
                        backup_ips_db = self.database.get('backup_ips', {})
                        for backup_id, backup_data in backup_ips_db.items():
                            if backup_data.get('api_id') == selected_api_id and backup_data.get('ip') == old_ip:
                                original_ip_display = backup_data.get('original_ip', original_ip_display)
                                logger.info(f"✅ Detected backup IP: {old_ip} → original: {original_ip_display}")
                                break
                
                # Onay mesajı - Bu waiting_new_ip_manual'deki eski onay mesajı
                # Artık kullanılmıyor çünkü confirm_ip_update'te yenisi var
                # Ancak bu fonksiyon hala tetiklenebilir, bu yüzden basit bir mesaj bırak
                confirm_text = (
                    f"🔄 <b>IP Adresi Güncelleme Onayı</b>\n\n"
                    f"📊 <b>Hedef:</b> {api_name}\n"
                    f"🔑 <b>Güncellenecek:</b> {len(keys_to_update)} anahtar\n\n"
                    f"🔵 <b>Kaynak (Outline):</b> <code>{original_ip_display}</code>\n"
                    f"🟢 <b>Yeni IP:</b> <code>{new_ip}</code>\n"
                    f"🔌 <b>Port Aralığı:</b> <code>444-999</code> (556 port)\n\n"
                    f"⚡ <b>İşlem:</b>\n"
                    f"1️⃣ Tüm anahtarların IP'si güncellenir\n"
                    f"2️⃣ iptables yönlendirme komutları oluşturulur\n"
                    f"3️⃣ Yeni sunucuda tek komut ile 556 port yönlendirilir\n\n"
                    f"❓ <b>Devam etmek istiyor musunuz?</b>"
                )
                
                # IP'leri encode et
                encoded_data = f"{new_ip}|{old_ip}|{selected_api_id or 'all'}"
                
                # Onay butonları
                keyboard = [
                    [InlineKeyboardButton("✅ Onayla", callback_data=f"confirm_ip_update_{encoded_data}")],
                    [InlineKeyboardButton("❌ İptal", callback_data="cancel_ip_update")]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await update.message.reply_text(confirm_text, parse_mode='HTML', reply_markup=reply_markup)
                
                # State'i temizle
                context.user_data.clear()
                
            except Exception as e:
                logger.error(f"Manual IP input error: {e}")
                logger.error(f"Exception details: {traceback.format_exc()}")
                await update.message.reply_text(
                    "❌ Hata oluştu! Lütfen tekrar deneyin.",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_select_api_to_refresh':
            # API seçimi - hangi API yenilenecek
            try:
                # YAML modunda API yoksa → YAML güncelleme seçenekleri
                if not self.config['outline_apis']:
                    has_yaml = bool(self.config.get('default_yaml_content'))
                    keyboard = [
                        [InlineKeyboardButton("📄 Yeni YAML Yükle", callback_data="add_yaml")],
                        [InlineKeyboardButton("✏️ Endpoint IP Düzenle", callback_data="edit_yaml_endpoint")],
                        [InlineKeyboardButton("➕ Outline API Ekle", callback_data="add_new_api")],
                        [InlineKeyboardButton("🏠 Ana Menü", callback_data="main_menu")]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    await update.message.reply_text(
                        f"⚠️ <b>API Bulunamadı!</b>\n\nYAML modundasınız. Ne yapmak istiyorsunuz?\n\n"
                        f"• YAML: {'Yüklendi ✅' if has_yaml else 'Yok ❌'}",
                        parse_mode='HTML', reply_markup=reply_markup
                    )
                    context.user_data.clear()
                    return

                selected_api_id = text.strip().lower()
                
                # API'yi bul
                selected_api = None
                for api_info in self.config['outline_apis']:
                    if api_info['id'] == selected_api_id:
                        selected_api = api_info
                        break
                
                if not selected_api:
                    await update.message.reply_text(
                        f"❌ <b>API Bulunamadı!</b>\n\n"
                        f"🔍 <code>{selected_api_id}</code> ID'li API bulunamadı.\n"
                        f"Lütfen geçerli bir API ID girin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Yeni API bilgisini sor
                api_help_text = (
                    f"🔄 <b>Hepsini Güncelle - Yeni API Bilgisi</b>\n\n"
                    f"📊 <b>Yenilenecek API:</b> {selected_api['name']}\n"
                    f"🆔 <b>ID:</b> <code>{selected_api_id}</code>\n"
                    f"🔑 <b>Anahtar Sayısı:</b> {len(selected_api['keys'])}\n\n"
                    f"⚠️ <b>Uyarı:</b> Tüm anahtarlar yeniden oluşturulacak!\n\n"
                    f"📋 <b>Desteklenen formatlar:</b>\n\n"
                    f"1️⃣ <b>JSON Format:</b>\n"
                    f"<code>{{\"apiUrl\":\"https://IP:PORT/PATH\",\"certSha256\":\"HASH\"}}</code>\n\n"
                    f"2️⃣ <b>Sadece URL:</b>\n"
                    f"<code>https://IP:PORT/PATH</code>\n\n"
                    f"✏️ Yeni API bilgisini girin:"
                )
                
                context.user_data['refresh_api_id'] = selected_api_id
                context.user_data['state'] = 'waiting_update_all_api'
                await update.message.reply_text(api_help_text, parse_mode='HTML')
                
            except Exception as e:
                logger.error(f"Error in select_api_to_refresh: {e}")
                await update.message.reply_text(
                    "❌ API seçiminde hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_update_all_api':
            # Seçilen API'deki anahtarları yenile
            try:
                # Master key varsa otomatik sil
                if 'master_ss_key' in self.config:
                    del self.config['master_ss_key']
                    self.save_config()
                    logger.info("Master key otomatik silindi - API güncellemesi başladı")
                
                new_api = text.strip()
                refresh_api_id = context.user_data.get('refresh_api_id')
                
                logger.info(f"Refreshing API {refresh_api_id} with new API: {new_api[:50]}...")
                
                # API formatını parse et
                import json
                import asyncio
                import ssl
                from aiohttp import ClientSession, ClientTimeout
                api_data = None
                
                if new_api.startswith('{') and new_api.endswith('}'):
                    api_data = json.loads(new_api)
                elif new_api.startswith('https://') or new_api.startswith('http://'):
                    api_data = {'apiUrl': new_api}
                else:
                    await update.message.reply_text(
                        "❌ Geçersiz API formatı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # IP extraction
                from urllib.parse import urlparse
                import re
                api_url = api_data.get('apiUrl', '')
                current_ip = self.get_ip_from_api_url(api_url)
                original_ip = 'Unknown'
                try:
                    parsed = urlparse(api_url)
                    hostname = parsed.hostname
                    if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
                        original_ip = hostname
                    elif ':' in hostname:
                        original_ip = hostname
                    else:
                        original_ip = hostname
                except:
                    pass
                
                # Eski API'yi bul ve güncelle
                target_api = None
                other_apis = []
                for api_info in self.config['outline_apis']:
                    if api_info['id'] == refresh_api_id:
                        target_api = api_info
                    else:
                        other_apis.append(api_info)
                
                if not target_api:
                    await update.message.reply_text(
                        "❌ Hedef API bulunamadı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # API config'i güncelle
                target_api['api'] = api_data
                target_api['original_ip'] = original_ip
                target_api['name'] = f'Ana API ({current_ip})'
                
                # Geçici olarak sadece bu API'yi tut (anahtar oluşturma için)
                old_apis = self.config['outline_apis']
                self.config['outline_apis'] = [target_api] + other_apis
                
                # Bu API'deki anahtarları yenile
                await update.message.reply_text(
                    f"🔄 <b>{target_api['name']} yenileniyor...</b>\n\n"
                    f"🔑 Anahtar sayısı: {len(target_api['keys'])}\n"
                    f"🧹 Önce mevcut anahtarlar temizleniyor...",
                    parse_mode='HTML'
                )
                
                import time
                start_time = time.time()
                
                # ÖNEMLİ: API'deki mevcut vip-user- anahtarlarını PARALEL temizle
                cleaned_count = 0
                async with ClientSession() as session:
                    ssl_context = ssl.create_default_context()
                    ssl_context.check_hostname = False
                    ssl_context.verify_mode = ssl.CERT_NONE
                    
                    try:
                        async with session.get(f"{target_api['api']['apiUrl']}/access-keys", ssl=ssl_context) as response:
                            if response.status == 200:
                                data = await response.json()
                                outline_keys = data.get('accessKeys', [])
                                
                                # Tüm silme işlemlerini paralel çalıştır
                                delete_tasks = []
                                for key in outline_keys:
                                    key_name = key.get('name', '')
                                    if key_name.startswith('vip-user-'):
                                        key_id_to_delete = key.get('id')
                                        delete_tasks.append(self._delete_key_async(session, target_api['api']['apiUrl'], key_id_to_delete, key_name, ssl_context))
                                
                                if delete_tasks:
                                    delete_results = await asyncio.gather(*delete_tasks, return_exceptions=True)
                                    cleaned_count = sum(1 for r in delete_results if r is True)
                                    logger.info(f"✅ Cleaned {cleaned_count} keys from API (parallel)")
                    except Exception as e:
                        logger.error(f"❌ Error during API cleanup: {e}")
                
                # Port havuzunu temizle (HER ZAMAN YENİ portlar atanacak)
                logger.info("🔄 Port havuzu temizleniyor (YENİ port atama için)...")
                old_port_count = len(self.used_ports)
                self.used_ports.clear()
                self.reserved_ports.clear()
                self.config['port_range']['used_ports'] = []
                self.save_config()
                logger.info(f"✅ Port havuzu temizlendi: {old_port_count} port serbest bırakıldı")
                
                # Süre kontrolü - temizlik
                elapsed = time.time() - start_time
                if elapsed > 60:
                    await update.message.reply_text(
                        f"⏱️ <b>Temizlik 1 dakikayı aştı</b>\n"
                        f"Süre: {int(elapsed)}s - {cleaned_count} anahtar silindi",
                        parse_mode='HTML'
                    )
                
                current_port = self.config.get('outline_port', 444)
                await update.message.reply_text(
                    f"🔨 <b>Anahtarlar yeniden oluşturuluyor...</b>\n\n"
                    f"🔐 Her anahtara YENİ benzersiz port (<code>444-999</code> arası)",
                    parse_mode='HTML'
                )
                
                updated_count = 0
                failed_count = 0
                
                # Sadece seçilen API'deki anahtarları PARALEL yeniden oluştur
                keys_to_refresh = [kid for kid in target_api['keys'] if kid in self.database['keys']]
                
                create_tasks = []
                for key_id in keys_to_refresh:
                    key_data = self.database['keys'][key_id]
                    custom_id = self.get_custom_id(key_id)
                    create_tasks.append(self._refresh_single_key(key_id, custom_id, refresh_api_id, target_api['api']['apiUrl'], original_ip, current_ip))
                
                # Batch işleme (20'şer anahtar)
                batch_size = 20
                total_keys = len(create_tasks)
                
                for i in range(0, total_keys, batch_size):
                    batch = create_tasks[i:i+batch_size]
                    logger.info(f"🔨 Refreshing batch {i//batch_size + 1}/{(total_keys + batch_size - 1)//batch_size} ({len(batch)} keys)...")
                    
                    batch_results = await asyncio.gather(*batch, return_exceptions=True)
                    
                    for result in batch_results:
                        if isinstance(result, dict):
                            if result.get('success'):
                                updated_count += 1
                            else:
                                failed_count += 1
                        elif isinstance(result, Exception):
                            failed_count += 1
                            logger.error(f"❌ Batch refresh error: {result}")
                    
                    # Her batch sonrası süre kontrolü
                    elapsed = time.time() - start_time
                    if elapsed > 60 and i == 0:
                        await update.message.reply_text(
                            f"⏱️ <b>İlk batch 1 dakikayı aştı</b>\n"
                            f"Süre: {int(elapsed)}s - {updated_count}/{total_keys} anahtar oluşturuldu",
                            parse_mode='HTML'
                        )
                
                # Config'i kaydet
                self.save_config()
                self.save_database()
                
                # Toplam süre
                total_time = time.time() - start_time
                duration_info = ""
                if total_time > 60:
                    duration_info = f"\n⏱️ <b>İşlem Süresi:</b> {int(total_time)} saniye"
                
                current_port = self.config.get('outline_port', 444)
                result_text = (
                    f"✅ <b>API Yenileme Tamamlandı!</b>\n\n"
                    f"📊 <b>Sonuçlar:</b>\n"
                    f"• Temizlenen: {cleaned_count}\n"
                    f"• Güncellenen: {updated_count}\n"
                    f"• Başarısız: {failed_count}{duration_info}\n\n"
                    f"🔨 <b>Port:</b> <code>444-999</code>\n"
                    f"🆔 <b>API ID:</b> <code>{refresh_api_id}</code>\n"
                    f"📍 <b>Yeni IP:</b> <code>{current_ip}</code>\n\n"
                )
                
                # Sadece api1 ana API'dir
                if refresh_api_id == 'api1':
                    result_text += "🌟 <b>Ana API yenilendi!</b>"
                else:
                    result_text += f"💡 <b>Yedek API yenilendi (Ana API: api1)</b>"
                
                reply_markup = self.get_back_to_menu_keyboard()
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                
            except Exception as e:
                logger.error(f"❌ Error updating all APIs: {e}")
                await update.message.reply_text(
                    "❌ API güncellenirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_custom_range':
            # Özel aralık için API güncelleme
            try:
                range_input = text.strip()
                total_keys = len(self.database['keys'])
                
                # Aralığı parse et: "1-250", "251-500", "501-son"
                import re
                match = re.match(r'^(\d+)-(\d+|son)$', range_input.lower())
                
                if not match:
                    await update.message.reply_text(
                        "❌ Geçersiz format!\n"
                        "Doğru format: 1-250, 251-500, 501-son",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                start = int(match.group(1))
                end = total_keys if match.group(2) == 'son' else int(match.group(2))
                
                # Aralık kontrolü
                if start < 1 or start > total_keys:
                    await update.message.reply_text(
                        f"❌ Başlangıç değeri 1-{total_keys} arasında olmalı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                if end > total_keys:
                    end = total_keys
                
                if start > end:
                    await update.message.reply_text(
                        "❌ Başlangıç değeri bitiş değerinden büyük olamaz!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Aralık bilgisini kaydet
                context.user_data['range_start'] = start
                context.user_data['range_end'] = end
                context.user_data['state'] = 'waiting_custom_api'
                
                api_help_text = (
                    f"🎯 <b>Özel Güncelleme - API Girin</b>\n\n"
                    f"📊 <b>Seçili Aralık:</b>\n"
                    f"• Başlangıç: {start}\n"
                    f"• Bitiş: {end}\n"
                    f"• Toplam: {end - start + 1} anahtar\n"
                    f"• Sıralama: Oluşturulma zamanına göre (en eski → en yeni)\n\n"
                    f"💡 <b>Not:</b> İlk oluşturulan {end - start + 1} anahtar güncellenir\n\n"
                    f"📋 <b>API Formatları:</b>\n\n"
                    f"1️⃣ <b>JSON:</b>\n"
                    f"<code>{{\"apiUrl\":\"https://IP:PORT/PATH\",\"certSha256\":\"HASH\"}}</code>\n\n"
                    f"2️⃣ <b>URL:</b>\n"
                    f"<code>https://IP:PORT/PATH</code>\n\n"
                    f"✏️ Yeni API bilgisini girin:"
                )
                
                await update.message.reply_text(api_help_text, parse_mode='HTML')
                
            except Exception as e:
                logger.error(f"❌ Error parsing custom range: {e}")
                await update.message.reply_text(
                    "❌ Aralık işlenirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_custom_api':
            # Özel aralık için API al
            try:
                new_api = text.strip()
                start = context.user_data.get('range_start')
                end = context.user_data.get('range_end')
                
                # API formatını parse et
                import json
                api_data = None
                
                if new_api.startswith('{') and new_api.endswith('}'):
                    api_data = json.loads(new_api)
                elif new_api.startswith('https://') or new_api.startswith('http://'):
                    api_data = {'apiUrl': new_api}
                else:
                    await update.message.reply_text(
                        "❌ Geçersiz API formatı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # IP extraction
                from urllib.parse import urlparse
                import re
                api_url = api_data.get('apiUrl', '')
                ip = self.get_ip_from_api_url(api_url)
                original_ip = 'Unknown'
                try:
                    parsed = urlparse(api_url)
                    hostname = parsed.hostname
                    if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', hostname):
                        original_ip = hostname
                    elif ':' in hostname:
                        original_ip = hostname
                    else:
                        original_ip = hostname
                except:
                    pass
                
                # Yeni API ID oluştur ve geçici olarak config'e ekle
                new_api_id = f"api{len(self.config['outline_apis']) + 1}"
                
                # Anahtarları oluşturulma zamanına göre sırala (en eski → en yeni)
                sorted_keys = sorted(
                    self.database['keys'].keys(),
                    key=lambda k: self.database['keys'][k].get('created_at', 0)
                )
                selected_keys = sorted_keys[start-1:end]
                
                logger.info(f"Selected keys {start}-{end}: Sorted by creation time (oldest first)")
                
                # Geçici API config'i oluştur (anahtar oluşturma için gerekli)
                temp_api = {
                    'id': new_api_id,
                    'name': f'API {new_api_id.upper()} ({ip})',
                    'api': api_data,
                    'original_ip': original_ip,
                    'keys': []
                }
                self.config['outline_apis'].append(temp_api)
                
                await update.message.reply_text(
                    f"🔄 Anahtarlar {start}-{end} arası yeni API'ye taşınıyor..."
                )
                
                updated_count = 0
                failed_count = 0
                
                for key_id in selected_keys:
                    try:
                        key_data = self.database['keys'][key_id]
                        port = key_data['port']
                        custom_id = self.get_custom_id(key_id)
                        
                        # Eski anahtarı sil (eğer outline_key_id varsa)
                        old_outline_key_id = key_data.get('outline_key_id')
                        old_api_id = key_data.get('api_id')
                        old_key_port = key_data.get('port')  # Port bilgisi
                        if old_outline_key_id and old_api_id:
                            try:
                                await self.delete_outline_key(old_outline_key_id, api_id=old_api_id, port=old_key_port)
                                logger.info(f"Deleted old key {old_outline_key_id} from API {old_api_id}")
                            except Exception as e:
                                logger.warning(f"Could not delete old key {old_outline_key_id}: {e}")
                        
                        # Yeni API'de anahtar oluştur
                        new_outline_key = await self.create_outline_key(
                            f"vip-user-{custom_id}",
                            api_id=new_api_id,
                            preferred_port=port
                        )
                        
                        # ss_url'deki IP'yi güncelle
                        new_ss_url = new_outline_key['accessUrl']
                        if original_ip and original_ip in new_ss_url:
                            current_ip = self.get_ip_from_api_url(api_data['apiUrl'])
                            if current_ip and original_ip != current_ip:
                                new_ss_url = new_ss_url.replace(original_ip, current_ip)
                                logger.info(f"Updated ss_url IP: {original_ip} → {current_ip}")
                        
                        # Database'i güncelle
                        self.database['keys'][key_id]['outline_key_id'] = new_outline_key['id']
                        self.database['keys'][key_id]['ss_url'] = new_ss_url
                        self.database['keys'][key_id]['api_id'] = new_api_id
                        
                        updated_count += 1
                        logger.info(f"✅ Key {key_id[:12]}... recreated in new API {new_api_id}")
                    except Exception as e:
                        failed_count += 1
                        logger.error(f"❌ Error recreating key {key_id}: {e}")
                
                # API config'i güncelle (seçili anahtarları ekle)
                temp_api['keys'] = selected_keys
                self.save_config()
                self.save_database()
                
                result_text = (
                    f"✅ <b>Özel Güncelleme Tamamlandı!</b>\n\n"
                    f"📊 <b>Sonuçlar:</b>\n"
                    f"• Aralık: {start}-{end} (oluşturulma zamanına göre)\n"
                    f"• Toplam: {end - start + 1} anahtar\n"
                    f"• ✅ Güncellenen: {updated_count}\n"
                    f"• ❌ Başarısız: {failed_count}\n\n"
                    f"🆔 Yeni API: <code>{new_api_id}</code>\n"
                    f"📍 IP: <code>{ip}</code>\n\n"
                    f"💡 İlk oluşturulan {end - start + 1} anahtar yeni API'ye taşındı"
                )
                
                reply_markup = self.get_back_to_menu_keyboard()
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                
            except Exception as e:
                logger.error(f"❌ Error custom API update: {e}")
                await update.message.reply_text(
                    "❌ API güncellenirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_select_api_for_ip':
            # Çoklu API'den hangisinin IP'sini güncelleyeceğini seç
            try:
                selected_api_id = text.strip().lower()
                api_ips = context.user_data.get('api_ips', {})
                
                if selected_api_id not in api_ips:
                    await update.message.reply_text(
                        f"❌ Geçersiz API ID!\n"
                        f"Mevcut API'ler: {', '.join(api_ips.keys())}",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                api_info = api_ips[selected_api_id]
                original_ip = api_info.get('original_ip', 'Unknown')
                current_ip = api_info.get('current_ip', original_ip)
                
                ip_help_text = f"🔄 <b>IP Güncelleme - {api_info['name']}</b>\n\n"
                ip_help_text += f"📊 <b>Seçili API:</b>\n"
                ip_help_text += f"• API ID: <code>{selected_api_id}</code>\n"
                
                if current_ip == original_ip:
                    ip_help_text += f"• Ana IP: <code>{original_ip}</code>\n"
                else:
                    ip_help_text += f"• Ana IP: <code>{original_ip}</code>\n"
                    ip_help_text += f"• Mevcut IP: <code>{current_ip}</code>\n"
                
                ip_help_text += f"• Anahtarlar: {api_info['keys']}\n\n"
                ip_help_text += "📝 <b>Yeni IP adresini girin:</b>\n"
                ip_help_text += "(IPv4: 123.45.67.89 veya IPv6: 2001:db8::1)"
                
                await update.message.reply_text(ip_help_text, parse_mode='HTML')
                
                context.user_data['state'] = 'waiting_new_ip'
                context.user_data['selected_api_id'] = selected_api_id
                
            except Exception as e:
                logger.error(f"❌ Error selecting API for IP: {e}")
                await update.message.reply_text(
                    "❌ API seçilirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_new_port':
            # Yeni port girişi
            try:
                new_port = int(text.strip())
                
                # Port aralığı kontrolü
                if new_port < 1 or new_port > 65535:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz port!</b>\n\n"
                        "📏 <b>Geçerli aralık:</b> 1-65535\n"
                        "💡 <b>Önerilen:</b> 1024-65535",
                        parse_mode='HTML'
                    )
                    return
                
                current_port = self.config.get('outline_port', 444)
                
                if new_port == current_port:
                    await update.message.reply_text(
                        f"⚠️ <b>Aynı port!</b>\n\n"
                        f"Mevcut port zaten <code>{current_port}</code>\n"
                        f"Farklı bir port girin.",
                        parse_mode='HTML'
                    )
                    return
                
                # Config'i güncelle
                self.config['outline_port'] = new_port
                self.save_config()
                
                # IP adresleri al (yönlendirme bilgisi için)
                has_ip_redirect = False
                redirect_info = ""
                
                # Yedek IP'ler var mı kontrol et
                if self.database.get('backup_ips'):
                    has_ip_redirect = True
                    redirect_info = "\n🌐 <b>Yedek IP Yönlendirmesi:</b>\n"
                    for backup_id, backup_data in self.database['backup_ips'].items():
                        backup_ip = backup_data['ip']
                        original_ip = backup_data.get('original_ip', 'Bilinmiyor')
                        redirect_info += f"• <code>{backup_ip}</code> → <code>{original_ip}</code>\n"
                
                # Başarı mesajı
                result_text = (
                    f"✅ <b>Port Config'de Güncellendi!</b>\n\n"
                    f"🔴 <b>Eski Port:</b> <code>444-999</code>\n"
                    f"🟢 <b>Yeni Port:</b> <code>{new_port}</code>\n\n"
                    f"📋 <b>Sırasıyla Yapılması Gerekenler:</b>\n\n"
                    f"1️⃣ <b>API Yenileyin:</b>\n"
                    f"   • Bot'ta: Gelişmiş → Outline API Yenile\n"
                    f"   • Tüm anahtarlar <code>{new_port}</code> portunda yeniden oluşturulacak\n\n"
                    f"2️⃣ <b>IP Adresini Güncelleyin:</b>\n"
                    f"   • Bot'ta: Gelişmiş → IP Adresi Güncelle\n"
                    f"   • Yeni IP için iptables komutlarını uygulayın\n\n"
                    f"🚨 <b>ÖNEMLİ UYARI:</b>\n"
                    f"⚠️ Bu işlemleri <b>GELİŞTİRİCİ OLMADAN ASLA YAPMAYIN!</b>\n"
                    f"⚠️ Yanlış yapılandırma tüm anahtarları bozabilir!\n"
                    f"⚠️ Port değişikliği kritik bir işlemdir!"
                )
                
                logger.info(f"✅ Port updated: {current_port} → {new_port}")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                context.user_data.clear()
                
            except ValueError:
                await update.message.reply_text(
                    "❌ <b>Geçersiz format!</b>\n\n"
                    "Sadece sayı girin.\n"
                    "Örnek: 1234",
                    parse_mode='HTML'
                )
            except Exception as e:
                logger.error(f"❌ Error updating port: {e}")
                await update.message.reply_text(
                    f"❌ <b>Port güncellenirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_admin_add':
            # Admin ekleme - Sadece geliştirici
            if not self.is_developer(user_id):
                await update.message.reply_text(
                    "🚫 Erişim reddedildi!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return
            
            try:
                new_admin_id = text.strip()
                
                # ID formatını kontrol et (sadece rakam)
                if not new_admin_id.isdigit():
                    await update.message.reply_text(
                        "❌ Geçersiz Telegram ID!\n"
                        "ID sadece rakamlardan oluşmalıdır.\n\n"
                        "Örnek: <code>123456789</code>",
                        parse_mode='HTML'
                    )
                    return
                
                # Geliştirici ID'si ile aynı mı?
                if new_admin_id == self.config['developer_id']:
                    await update.message.reply_text(
                        "❌ Bu ID geliştirici ID'si!\n"
                        "Geliştirici zaten tüm yetkilere sahip.",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Zaten admin mi?
                if new_admin_id in self.config['admin_ids']:
                    await update.message.reply_text(
                        "❌ Bu ID zaten admin listesinde!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Admin ekle
                self.config['admin_ids'].append(new_admin_id)
                self.save_config()
                
                result_text = (
                    f"✅ <b>Admin Başarıyla Eklendi!</b>\n\n"
                    f"🆔 <b>Admin ID:</b> <code>{new_admin_id}</code>\n\n"
                    f"👥 <b>Toplam Admin:</b> {len(self.config['admin_ids'])}\n\n"
                    f"💡 <b>Yetkiler:</b>\n"
                    f"• Anahtar oluşturma/silme\n"
                    f"• Kullanıcı listesi görüntüleme\n"
                    f"• IP güncelleme\n"
                    f"• API güncelleme\n"
                    f"• Admin yönetimi: ❌ (sadece geliştirici)"
                )
                
                reply_markup = self.get_back_to_menu_keyboard()
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                
                logger.info(f"✅ New admin added: {new_admin_id} by developer {user_id}")
                
            except Exception as e:
                logger.error(f"❌ Error adding admin: {e}")
                await update.message.reply_text(
                    "❌ Admin eklenirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_admin_remove':
            # Admin silme - Sadece geliştirici
            if not self.is_developer(user_id):
                await update.message.reply_text(
                    "🚫 Erişim reddedildi!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return
            
            try:
                remove_admin_id = text.strip()
                
                # ID formatını kontrol et
                if not remove_admin_id.isdigit():
                    await update.message.reply_text(
                        "❌ Geçersiz Telegram ID!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Geliştirici ID'sini silmeye çalışıyor mu?
                if remove_admin_id == self.config['developer_id']:
                    await update.message.reply_text(
                        "🚫 <b>Geliştirici ID Silinemez!</b>\n\n"
                        "Geliştirici ID'si sistemden silinemez.\n"
                        "Bu ID tüm yetkilere sahip ana hesaptır.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Admin listesinde var mı?
                if remove_admin_id not in self.config['admin_ids']:
                    await update.message.reply_text(
                        "❌ Bu ID admin listesinde yok!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                # Admin sil
                self.config['admin_ids'].remove(remove_admin_id)
                self.save_config()
                
                result_text = (
                    f"✅ <b>Admin Başarıyla Silindi!</b>\n\n"
                    f"🆔 <b>Silinen Admin ID:</b> <code>{remove_admin_id}</code>\n\n"
                    f"👥 <b>Kalan Admin:</b> {len(self.config['admin_ids'])}"
                )
                
                reply_markup = self.get_back_to_menu_keyboard()
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=reply_markup)
                
                logger.info(f"✅ Admin removed: {remove_admin_id} by developer {user_id}")
                
            except Exception as e:
                logger.error(f"❌ Error removing admin: {e}")
                await update.message.reply_text(
                    "❌ Admin silinirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
            
            context.user_data.clear()
        
        elif state == 'waiting_key_duration':
            import time
            duration = text.strip()
            
            # Süre formatını doğrula
            if not self.validate_duration_format(duration):
                error_msg = (
                    "❌ <b>Geçersiz süre formatı!</b>\n\n"
                    "✅ <b>Geçerli formatlar:</b>\n"
                    "• <code>24h</code> = 24 saat\n"
                    "• <code>7d</code> = 7 gün\n" 
                    "• <code>30d</code> = 30 gün\n"
                    "• <code>1y</code> = 1 yıl\n\n"
                    "💡 <b>Kurallar:</b>\n"
                    "• Sadece sayı + h/d/y karakteri\n"
                    "• Örnekler: 1h, 12h, 1d, 7d, 30d, 1y\n\n"
                    "✏️ <b>Lütfen doğru formatda süre girin:</b>"
                )
                await update.message.reply_text(error_msg, parse_mode='HTML')
                return
            
            count = context.user_data.get('key_count', 1)
            
            logger.info(f"Starting key creation: count={count}, duration={duration}")
            
            # Toplam anahtar sayısını hesapla (mevcut + yeni)
            current_key_count = len(self.database['keys'])
            
            logger.info(f"Current key count: {current_key_count}")

            master_ss_key = self.config.get('master_ss_key')
            default_yaml_content = self.config.get('default_yaml_content')
            yaml_mode = self.is_yaml_mode_active()
            
            # Seçili API'yi al
            selected_api_id = context.user_data.get('selected_api_for_key')
            if not selected_api_id:
                if self.config['outline_apis']:
                    # Fallback: İlk API'yi kullan
                    selected_api_id = self.config['outline_apis'][0]['id']
                    logger.warning(f"⚠️ No API selected, using default: {selected_api_id}")
                elif yaml_mode:
                    selected_api_id = 'yaml'
                    logger.info("ℹ️ No API configured, using YAML mode")

            api_info = self.get_api_by_id(selected_api_id) if selected_api_id != 'yaml' else None
            if not api_info and not (yaml_mode or master_ss_key):
                await update.message.reply_text("❌ Seçili API bulunamadı!", reply_markup=self.get_back_to_menu_keyboard())
                context.user_data.clear()
                return
            
            if api_info:
                logger.info(f"Creating {count} keys using API: {selected_api_id} ({api_info['name']})")
            else:
                logger.info(f"Creating {count} keys in YAML mode (api_id={selected_api_id})")
            
            # Anahtarları oluştur
            created_keys = []
            for i in range(count):
                try:
                    # Her anahtar için özel isim al
                    custom_name = context.user_data.get('key_name', 'DEFAULT')  # Özel ismi al
                    key_id = self.generate_key_id(custom_name)  # Sadece custom_name geç, key_number otomatik hesaplanacak
                    
                    logger.info(f"Creating key {i+1}/{count}: ID={key_id}, API={selected_api_id}")
                    
                    if master_ss_key:
                        # Master anahtar varsa, onu kullan (Outline API'ye hiç gitme)
                        logger.info(f"✅ Using master ss:// key for new key creation")
                        ss_url = master_ss_key
                        
                        # IP güncellemesi kontrol et - mevcut anahtarlardan güncel IP'yi tespit et
                        import re
                        from collections import Counter
                        
                        current_ip = None
                        if api_info and api_info.get('keys'):
                            detected_ips = []
                            
                            for existing_key_id in api_info['keys']:
                                if existing_key_id in self.database['keys']:
                                    existing_ss_url = self.database['keys'][existing_key_id].get('ss_url', '')
                                    ipv4_match = re.search(r'@([\d\.]+):', existing_ss_url)
                                    if ipv4_match:
                                        detected_ips.append(ipv4_match.group(1))
                            
                            if detected_ips:
                                # En çok geçen IP = mevcut aktif IP
                                ip_counter = Counter(detected_ips)
                                current_ip = ip_counter.most_common(1)[0][0]
                                logger.info(f"✅ Master key mode: Detected current IP from existing keys: {current_ip}")
                        
                        # Master ss_url'den orijinal IP'yi çıkar
                        original_ip_in_master = None
                        ipv4_match = re.search(r'@([\d\.]+):', ss_url)
                        if ipv4_match:
                            original_ip_in_master = ipv4_match.group(1)
                        
                        # Eğer IP güncellemesi yapılmışsa (mevcut anahtarlarda farklı IP varsa), master key'i güncelle
                        if current_ip and original_ip_in_master and current_ip != original_ip_in_master:
                            ss_url = ss_url.replace(original_ip_in_master, current_ip)
                            logger.info(f"✅ Master key IP updated: {original_ip_in_master} → {current_ip}")
                        elif current_ip:
                            logger.info(f"ℹ️ Master key IP unchanged: {current_ip}")
                        
                        # Dummy outline_key_id oluştur (API'den gelmediği için)
                        outline_key_id = f"master-{int(time.time())}-{i}"
                    elif yaml_mode:
                        # Varsayılan YAML varsa API'ye gitmeden anahtar üret
                        logger.info("✅ YAML mode active: skipping Outline API key creation")
                        ss_url = ""
                        outline_key_id = f"yaml-{int(time.time())}-{i}"
                    else:
                        # Master anahtar yoksa, eski mantıkla Outline API'den al
                        logger.info(f"No master key, creating from Outline API")
                        # Seçili API'den anahtar oluştur (dinamik port, Outline otomatik parola)
                        outline_key = await self.create_outline_key(f"vip-user-{key_id}", api_id=selected_api_id)
                        
                        logger.info(f"Outline key created successfully: {outline_key.get('id', 'Unknown')}")
                        
                        # ss_url'i al ve IP'yi güncelle
                        ss_url = outline_key['accessUrl']
                        outline_key_id = outline_key['id']
                        
                        # Original IP: Outline API'nin çalıştığı IP (API URL'den)
                        original_ip = api_info.get('original_ip') or self.get_ip_from_api_url(api_info['api']['apiUrl'])
                        
                        # Current IP: Client'ların bağlanacağı IP
                        # ÖNEMLİ: Backup IP otomatik kullanılmaz! Sadece IP güncellemesiyle aktif edilir.
                        # Öncelik sırası:
                        # 1. Mevcut anahtarlardaki IP (güncel/aktif IP)
                        # 2. Original IP (hiç güncelleme yapılmamışsa)
                        
                        current_ip = None
                        
                        # 1. Mevcut anahtarlardan güncel IP'yi al (EN ÖNEMLİ)
                        if api_info.get('keys'):
                            import re
                            from collections import Counter
                            detected_ips = []
                            
                            for existing_key_id in api_info['keys']:
                                if existing_key_id in self.database['keys']:
                                    existing_ss_url = self.database['keys'][existing_key_id].get('ss_url', '')
                                    ipv4_match = re.search(r'@([\d\.]+):', existing_ss_url)
                                    if ipv4_match:
                                        detected_ips.append(ipv4_match.group(1))
                            
                            if detected_ips:
                                # En çok geçen IP = mevcut aktif IP
                                ip_counter = Counter(detected_ips)
                                current_ip = ip_counter.most_common(1)[0][0]
                                logger.info(f"✅ Using current IP from existing keys: {current_ip} (found in {ip_counter[current_ip]} keys)")
                        
                        # 2. Hiçbir anahtar yoksa original IP kullan
                        if not current_ip:
                            current_ip = original_ip
                            logger.info(f"ℹ️ Using original IP (no existing keys): {current_ip}")
                        
                        # IP değiştirme - ss_url'deki original_ip'yi current_ip ile değiştir
                        if original_ip != current_ip:
                            ss_url = ss_url.replace(original_ip, current_ip)
                            logger.info(f"✅ Updated ss_url IP: {original_ip} → {current_ip}")
                        else:
                            logger.info(f"ℹ️ No IP change needed: {current_ip}")
                    
                    # Benzersiz UDID oluştur
                    udid = self.ensure_unique_udid()
                    
                    # Master key modunda port havuzu kullanılmaz; diğer modda benzersiz port atanır
                    if master_ss_key or yaml_mode:
                        # Master ss:// içindeki sabit port (sadece yönlendirme için bilgi amaçlı)
                        current_port = self._get_master_key_port()
                    else:
                        # Normal mod: Outline'dan dönen port'u kullan, yoksa havuzdan seç ve işaretle
                        current_port = self._to_int_port(outline_key.get('port'))
                        if current_port is None:
                            current_port = self.get_available_port()
                        self.mark_port_used(current_port)
                    
                    # Veritabanına kaydet
                    default_yaml_content = self.config.get('default_yaml_content')
                    self.database['keys'][key_id] = {
                        "id": key_id,
                        "port": current_port,
                        "udid": udid,
                        "ss_url": ss_url,
                        "yaml_content": default_yaml_content if yaml_mode else None,
                        "outline_key_id": outline_key_id,  # Master key kullanıldıysa dummy ID
                        "api_id": selected_api_id if api_info else "yaml",  # API'siz modda yaml
                        "created_at": time.time(),
                        "duration": duration,
                        "requests": 0,
                        "from_master_key": bool(master_ss_key or yaml_mode)  # API'siz modda Outline silmeyi atla
                    }
                    
                    # API'nin key listesine ekle
                    if api_info and key_id not in api_info['keys']:
                        api_info['keys'].append(key_id)
                        self.save_config()
                    
                    subscription_url = f"https://{self.config['domain']}/vip-user/{key_id}/{udid}"
                    created_keys.append(subscription_url)
                    logger.info(f"Key {i+1} added to database: {subscription_url}")
                    
                except Exception as e:
                    error_msg = str(e)
                    logger.error(f"Key creation error for key {i+1}: {error_msg}")
                    logger.error(f"Exception type: {type(e).__name__}")
                    import traceback
                    logger.error(f"Traceback: {traceback.format_exc()}")
                    
                    # İlk hatada kullanıcıya detaylı mesaj gönder
                    if len(created_keys) == 0 and i == 0:
                        import html
                        safe_error_msg = html.escape(error_msg)
                        await update.message.reply_text(
                            f"❌ <b>Anahtar oluşturulamadı!</b>\n\n"
                            f"<code>{safe_error_msg}</code>\n\n"
                            f"💡 <b>Olası Çözümler:</b>\n"
                            f"1. IP güncellemesi yaptıysanız, yeni IP'de Outline API çalıştığından emin olun\n"
                            f"2. Firewall kurallarını kontrol edin\n"
                            f"3. IP yönlendirmesinin doğru olduğunu kontrol edin\n"
                            f"4. API ayarlarını kontrol edin (/api)",
                            parse_mode='HTML',
                            reply_markup=self.get_back_to_menu_keyboard()
                        )
                        context.user_data.clear()
                        return
                    continue
            
            self.database['stats']['total_keys'] += len(created_keys)
            self.save_database()
            
            logger.info(f"Key creation completed: {len(created_keys)} keys created successfully")
            
            if created_keys:
                # Tek başlık mesajı
                duration_text = duration
                if duration.endswith('d'):
                    days = int(duration[:-1])
                    duration_text = f"{days} günlük"
                elif duration.endswith('y'):
                    years = int(duration[:-1])
                    duration_text = f"{years} yıllık"
                elif duration.endswith('h'):
                    hours = int(duration[:-1])
                    duration_text = f"{hours} saatlik"
                
                response = f"✅ <b>{len(created_keys)} tane {duration_text} anahtar oluşturuldu:</b>\n\n"
                
                # Anahtarları numaralı liste olarak ekle
                for i, url in enumerate(created_keys, 1):
                    response += f"<b>{i}.</b> {url}\n\n"
                
                response += "🎯 <b>Kullanım:</b> Bu linkleri Outline Client'a ekleyin\n"
                response += "📱 <b>Uygulama:</b> Google Play/App Store'dan 'Outline' indirin"
                
                # Mesaj uzunluğu kontrolü (Telegram limit: 4096 karakter)
                if len(response) > 4000:
                    # Mesajı parçalara böl
                    header = f"✅ <b>{len(created_keys)} tane {duration_text} anahtar oluşturuldu:</b>\n\n"
                    footer = "\n🎯 <b>Kullanım:</b> Bu linkleri Outline Client'a ekleyin\n📱 <b>Uygulama:</b> Google Play/App Store'dan 'Outline' indirin"
                    
                    # İlk mesaj olarak header'ı gönder
                    await update.message.reply_text(header, parse_mode='HTML')
                    
                    # Anahtarları grup halinde gönder (10'ar 10'ar)
                    for i in range(0, len(created_keys), 10):
                        chunk_keys = created_keys[i:i+10]
                        chunk_response = ""
                        for j, url in enumerate(chunk_keys, i+1):
                            chunk_response += f"<b>{j}.</b> {url}\n\n"
                        
                        await update.message.reply_text(chunk_response, parse_mode='HTML')
                    
                    # Son olarak footer'ı gönder
                    await update.message.reply_text(footer, parse_mode='HTML')
                else:
                    # Normal mesaj gönder
                    try:
                        await update.message.reply_text(response, parse_mode='HTML')
                        logger.info(f"Keys message sent successfully to user")
                    except Exception as e:
                        logger.error(f"Error sending keys message: {e}")
                        # HTML hatası varsa plain text dene
                        try:
                            plain_response = response.replace('<b>', '').replace('</b>', '').replace('<code>', '').replace('</code>', '')
                            await update.message.reply_text(plain_response)
                            logger.info(f"Keys message sent as plain text")
                        except Exception as e2:
                            logger.error(f"Error sending plain text message: {e2}")
                

                # Anahtar oluşturma sonrası otomatik ana menüyü göster
                await self.show_main_menu(update, context, edit_message=False)
                
            else:
                await update.message.reply_text("❌ Anahtar oluşturulamadı!")
                
                # Hata durumunda da otomatik ana menüyü göster
                await self.show_main_menu(update, context, edit_message=False)
                
            context.user_data.clear()
        
        elif state == 'waiting_new_api_for_restore':
            # Yeni API ekle ve backup'ı geri yükle
            try:
                import os
                import shutil
                import hashlib
                import json
                import ssl
                import time
                from urllib.parse import urlparse
                from aiohttp import ClientSession
                
                api_input = text.strip()
                
                # JSON formatı mı yoksa düz URL mi kontrol et
                api_url = None
                cert_sha256 = ""
                
                # JSON formatı dene
                if api_input.startswith('{'):
                    try:
                        api_data = json.loads(api_input)
                        api_url = api_data.get('apiUrl')
                        cert_sha256 = api_data.get('certSha256', '')
                        logger.info(f"✅ JSON format detected: URL={api_url}, CertSHA256={cert_sha256[:20]}...")
                    except json.JSONDecodeError:
                        await update.message.reply_text(
                            "❌ <b>Geçersiz JSON formatı!</b>\n\n"
                            "✅ <b>Doğru formatlar:</b>\n\n"
                            "<b>1. JSON Format:</b>\n"
                            "<code>{\"apiUrl\":\"https://11.22.33.44:12345/abc\",\"certSha256\":\"ABC123...\"}</code>\n\n"
                            "<b>2. Sadece URL:</b>\n"
                            "<code>https://11.22.33.44:12345/abc123</code>",
                            parse_mode='HTML'
                        )
                        return
                else:
                    # Düz URL formatı
                    api_url = api_input
                
                # URL kontrolü
                if not api_url or not api_url.startswith('https://'):
                    await update.message.reply_text(
                        "❌ <b>Geçersiz API URL!</b>\n\n"
                        "URL <code>https://</code> ile başlamalıdır.\n\n"
                        "✅ <b>Doğru formatlar:</b>\n\n"
                        "<b>1. JSON Format:</b>\n"
                        "<code>{\"apiUrl\":\"https://11.22.33.44:12345/abc\",\"certSha256\":\"ABC123...\"}</code>\n\n"
                        "<b>2. Sadece URL:</b>\n"
                        "<code>https://11.22.33.44:12345/abc123</code>",
                        parse_mode='HTML'
                    )
                    return
                
                await update.message.reply_text("⏳ <b>API ekleniyor...</b>", parse_mode='HTML')
                
                # Cert SHA256 yoksa otomatik al
                if not cert_sha256:
                    try:
                        parsed = urlparse(api_url)
                        hostname = parsed.hostname
                        port = parsed.port or 443
                        
                        import ssl
                        import socket
                        context_ssl = ssl.create_default_context()
                        context_ssl.check_hostname = False
                        context_ssl.verify_mode = ssl.CERT_NONE
                        
                        with socket.create_connection((hostname, port), timeout=5) as sock:
                            with context_ssl.wrap_socket(sock, server_hostname=hostname) as ssock:
                                cert_der = ssock.getpeercert(binary_form=True)
                                cert_sha256 = hashlib.sha256(cert_der).hexdigest().upper()
                                logger.info(f"✅ Auto-fetched cert SHA256: {cert_sha256[:20]}...")
                    except Exception as e:
                        logger.warning(f"Could not fetch cert SHA256: {e}")
                
                # IP çıkar
                ip = self.get_ip_from_api_url(api_url)
                
                # Yeni API'yi HER ZAMAN api1 olarak oluştur (mevcut API1'i değiştir)
                new_api_id = "api1"
                
                # Yeni API ekle
                new_api = {
                    'id': new_api_id,
                    'name': f'API 1 ({ip})',
                    'api': {
                        'apiUrl': api_url,
                        'certSha256': cert_sha256
                    },
                    'original_ip': ip,
                    'keys': []
                }
                
                # Backup verilerini al
                backup_path = context.user_data.get('backup_path')
                backup_data = context.user_data.get('backup_data')
                filename = context.user_data.get('backup_filename')
                
                if not backup_path or not backup_data:
                    await update.message.reply_text(
                        "❌ <b>Yedek bilgisi bulunamadı!</b>\n\nLütfen tekrar yedek dosyasını gönderin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                await update.message.reply_text("⏳ <b>Yedek geri yükleniyor...</b>", parse_mode='HTML')
                
                # Mevcut veritabanını yedekle (güvenlik için, varsa)
                current_backup_path = f"{self.config['database']['path']}.before_restore.{int(time.time())}"
                if os.path.exists(self.config['database']['path']):
                    shutil.copy(self.config['database']['path'], current_backup_path)
                
                # Önce yeni API'yi config'e ekle - MEVCUT API1'İ TAMAMEN DEĞİŞTİR
                self.config['outline_apis'] = [new_api]  # Eski API'leri sil, sadece yeni API1
                self.set_connection_mode('api')
                
                # Veritabanını temizle
                self.database = backup_data['database']
                self.save_database()
                
                # Port havuzunu temizle (anahtarlar yeniden oluşturulurken yeni portlar atanacak)
                logger.info("🔄 Port havuzu temizleniyor (YENİ port atama için)...")
                old_port_count = len(self.used_ports)
                self.used_ports.clear()
                self.reserved_ports.clear()
                self.config['port_range']['used_ports'] = []
                self.save_config()
                logger.info(f"✅ Port havuzu temizlendi: {old_port_count} port serbest bırakıldı - Her anahtara YENİ benzersiz port atanacak")
                
                self._sync_used_ports_from_database()
                
                # Anahtarları YENİ API'de oluştur
                current_port = self.config.get('outline_port', 444)
                await update.message.reply_text(
                    f"🔄 <b>Anahtarlar yeni API1'de oluşturuluyor...</b>\n\n"
                    f"📊 Toplam: {len(self.database['keys'])} anahtar\n"
                    f"🔨 Her anahtara YENİ benzersiz port (<code>444-999</code> arası)",
                    parse_mode='HTML'
                )
                
                # ÖNEMLİ: Önce API'deki mevcut vip-user- anahtarlarını temizle
                await update.message.reply_text("🧹 <b>API temizleniyor...</b>", parse_mode='HTML')
                async with ClientSession() as session:
                    ssl_context = ssl.create_default_context()
                    ssl_context.check_hostname = False
                    ssl_context.verify_mode = ssl.CERT_NONE
                    
                    cleaned_count = 0
                    try:
                        async with session.get(f"{api_url}/access-keys", ssl=ssl_context) as response:
                            if response.status == 200:
                                data = await response.json()
                                outline_keys = data.get('accessKeys', [])
                                
                                for key in outline_keys:
                                    key_name = key.get('name', '')
                                    if key_name.startswith('vip-user-'):
                                        key_id_to_delete = key.get('id')
                                        try:
                                            async with session.delete(
                                                f"{api_url}/access-keys/{key_id_to_delete}",
                                                ssl=ssl_context
                                            ) as del_response:
                                                if del_response.status == 204:
                                                    cleaned_count += 1
                                        except Exception as e:
                                            logger.warning(f"⚠️ Could not delete key {key_name}: {e}")
                                
                                logger.info(f"✅ Cleaned {cleaned_count} keys from API")
                    except Exception as e:
                        logger.error(f"❌ Error during API cleanup: {e}")
                
                created_count = 0
                failed_count = 0
                
                for key_id, key_data in list(self.database['keys'].items()):
                    try:
                        custom_id = self.get_custom_id(key_id)
                        
                        # Yeni API1'de anahtar oluştur - HER ZAMAN YENİ benzersiz port ata
                        new_outline_key = await self.create_outline_key(
                            f"vip-user-{custom_id}",
                            api_id=new_api_id,
                            preferred_port=None  # ← HER ZAMAN YENİ port
                        )
                        
                        # ss_url güncelle
                        new_ss_url = new_outline_key['accessUrl']
                        
                        # Anahtarın gerçek portunu al (create_outline_key zaten mark_port_used çağırdı)
                        created_port = self._to_int_port(new_outline_key.get('port'))
                        if created_port is None:
                            # Fallback: Outline port dönmediyse havuzdan seç
                            created_port = await self._reserve_port(None)
                            self.mark_port_used(created_port)
                        
                        # Database'i güncelle - her şey api1 olacak
                        self.database['keys'][key_id]['outline_key_id'] = new_outline_key['id']
                        self.database['keys'][key_id]['ss_url'] = new_ss_url
                        self.database['keys'][key_id]['api_id'] = new_api_id
                        self.database['keys'][key_id]['port'] = created_port
                        self.database['keys'][key_id]['yaml_content'] = None
                        
                        # API'nin key listesine ekle
                        new_api['keys'].append(key_id)
                        
                        created_count += 1
                        
                        if created_count % 10 == 0:
                            logger.info(f"✅ Progress: {created_count}/{len(self.database['keys'])} keys created")
                        
                    except Exception as e:
                        failed_count += 1
                        logger.error(f"❌ Error creating key {key_id} in new API: {e}")
                        # Başarısız anahtarı sil
                        del self.database['keys'][key_id]
                
                # Config ve database'i kaydet
                self.save_config()
                self.save_database()
                
                # İndirilen dosyayı sil
                os.remove(backup_path)
                
                # Context'i temizle
                context.user_data.clear()
                
                # İstatistikler
                restored_keys = created_count
                restored_backup_ips = len(backup_data['database'].get('backup_ips', {}))
                
                current_port = self.config.get('outline_port', 444)
                result_text = (
                    f"✅ <b>Yedek Başarıyla Geri Yüklendi!</b>\n\n"
                    f"📁 <b>Dosya:</b> <code>{filename}</code>\n"
                    f"🕐 <b>Yedek Tarihi:</b> {backup_data.get('created_at', 'Bilinmeyen')}\n\n"
                    f"♻️ <b>Geri Yüklenen Veriler:</b>\n"
                    f"• ✅ Oluşturulan: <code>{created_count}</code> anahtar\n"
                    f"• ❌ Başarısız: <code>{failed_count}</code> anahtar\n"
                    f"• Yedek IP'ler: <code>{restored_backup_ips}</code> adet\n\n"
                    f"🔨 <b>API Yenileme:</b>\n"
                    f"• Temizlenen: <code>{cleaned_count}</code> anahtar\n"
                    f"• Port: <code>444-999</code>\n\n"
                    f"🔄 <b>API1 Güncellendi:</b>\n"
                    f"• ID: <code>api1</code>\n"
                    f"• IP: <code>{ip}</code>\n"
                    f"• URL: <code>{api_url[:50]}...</code>\n"
                    f"• Cert SHA256: <code>{cert_sha256[:20]}...</code>\n\n"
                    f"✨ <b>Önemli:</b>\n"
                    f"Her anahtara YENİ benzersiz port atandı (<code>444-999</code> arası)!\n"
                    f"Eski API tamamen değiştirildi.\n\n"
                    f"🔒 <b>Güvenlik:</b>\n"
                    + (f"Eski veritabanı yedeklendi:\n<code>{current_backup_path}</code>\n\n" if os.path.exists(current_backup_path) else "Temiz kurulum — önceki veritabanı yok.\n\n")
                    + f"✅ Tüm anahtarlar yeni API1'de aktif!"
                )
                
                logger.info(f"✅ Backup restored with new API1: {filename} ({created_count} keys created, {failed_count} failed)")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error restoring with new API: {e}")
                import traceback
                logger.error(traceback.format_exc())
                await update.message.reply_text(
                    f"❌ <b>Yedek geri yüklenirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_api_for_backup_ip':
            # Yedek IP için API seçimi
            try:
                selected_api_id = text.strip().lower()
                
                # API'nin var olup olmadığını kontrol et
                api_info = self.get_api_by_id(selected_api_id)
                if not api_info:
                    await update.message.reply_text(
                        f"❌ <b>Geçersiz API ID!</b>\n\n"
                        f"Mevcut API'ler: {', '.join([api['id'] for api in self.config['outline_apis']])}\n\n"
                        f"Lütfen geçerli bir API ID girin:",
                        parse_mode='HTML'
                    )
                    return
                
                # API bilgilerini kaydet
                context.user_data['selected_api_for_backup_ip'] = selected_api_id
                
                # Yeni IP iste
                original_ip = api_info.get('original_ip', 'Bilinmiyor')
                
                await update.message.reply_text(
                    f"➕ <b>Yedek IP Ekle - {api_info['name']}</b>\n\n"
                    f"🆔 <b>API ID:</b> <code>{selected_api_id}</code>\n"
                    f"🔵 <b>Orijinal IP:</b> <code>{original_ip}</code>\n\n"
                    f"📝 <b>Yeni IP adresini girin:</b>\n"
                    f"(IPv4: 123.45.67.89 veya IPv6: 2001:db8::1)",
                    parse_mode='HTML'
                )
                context.user_data['state'] = 'waiting_backup_ip_input'
                
            except Exception as e:
                logger.error(f"❌ Error selecting API for backup IP: {e}")
                await update.message.reply_text(
                    "❌ API seçilirken hata oluştu!",
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
        
        elif state == 'waiting_backup_ip_input':
            # Yedek IP adresi girişi - iptables deployment
            try:
                target_ip = text.strip()  # Yeni IP (yedek sunucu)
                
                # IP formatını doğrula
                import re
                ipv4_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
                ipv6_pattern = r'^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'
                
                is_valid_ip = re.match(ipv4_pattern, target_ip) or re.match(ipv6_pattern, target_ip)
                
                if not is_valid_ip:
                    await update.message.reply_text(
                        "❌ <b>Geçersiz IP adresi!</b>\n\n"
                        "✅ <b>Geçerli formatlar:</b>\n"
                        "• IPv4: <code>123.45.67.89</code>\n"
                        "• IPv6: <code>2001:db8::1</code>\n\n"
                        "✏️ Lütfen geçerli bir IP adresi girin:",
                        parse_mode='HTML'
                    )
                    return
                
                selected_api_id = context.user_data.get('selected_api_for_backup_ip')
                api_info = self.get_api_by_id(selected_api_id)
                
                if not api_info:
                    await update.message.reply_text(
                        "❌ API bulunamadı!",
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return
                
                api_url = api_info['api']['apiUrl']
                outline_ip = api_info.get('original_ip', self.get_ip_from_api_url(api_url))  # Outline IP (hedef)
                
                # Backup ID oluştur
                import uuid
                import time
                backup_id = str(uuid.uuid4())[:8]

                # Database'e kaydet
                if 'backup_ips' not in self.database:
                    self.database['backup_ips'] = {}

                self.database['backup_ips'][backup_id] = {
                    'id': backup_id,
                    'ip': target_ip,
                    'api_id': selected_api_id,
                    'created_at': time.time(),
                    'source_ip': target_ip,
                    'original_ip': outline_ip,
                    'port_range': '444-999',
                    'deployment_method': 'iptables'
                }
                self.save_database()

                # iptables yönlendirme komutları
                iptables_commands = (
                    f"sudo sysctl -w net.ipv4.ip_forward=1\n"
                    f"sudo iptables -t nat -A PREROUTING -p tcp -d {target_ip} --dport 444:999 -j DNAT --to-destination {outline_ip}\n"
                    f"sudo iptables -t nat -A POSTROUTING -p tcp -d {outline_ip} --dport 444:999 -j MASQUERADE\n"
                    f"sudo iptables -A FORWARD -p tcp -d {outline_ip} --dport 444:999 -j ACCEPT\n"
                    f"sudo iptables -t nat -A PREROUTING -p udp -d {target_ip} --dport 444:999 -j DNAT --to-destination {outline_ip}\n"
                    f"sudo iptables -t nat -A POSTROUTING -p udp -d {outline_ip} --dport 444:999 -j MASQUERADE\n"
                    f"sudo iptables -A FORWARD -p udp -d {outline_ip} --dport 444:999 -j ACCEPT"
                )

                # Sonuç mesajı
                result_text = (
                    f"✅ <b>Yedek IP Eklendi!</b>\n\n"
                    f"🆔 <b>Backup ID:</b> <code>{backup_id}</code>\n"
                    f"📊 <b>API:</b> {api_info['name']} (<code>{selected_api_id}</code>)\n"
                    f"🟢 <b>Yedek Sunucu:</b> <code>{target_ip}</code>\n"
                    f"🔵 <b>Hedef (Outline):</b> <code>{outline_ip}</code>\n"
                    f"🔌 <b>Port Aralığı:</b> <code>444-999</code> (556 port)\n\n"
                    f"⚙️ <b>iptables Yönlendirme</b>\n"
                    f"Yedek sunucuda bu komutları çalıştırın:\n\n"
                    f"<code>{iptables_commands}</code>\n\n"
                    f"⚠️ <b>Önemli:</b>\n"
                    f"• TCP ve UDP desteği için tüm kuralları uygulayın\n"
                    f"• Kurallar silinmedikçe yönlendirme kalıcıdır"
                )

                logger.info(f"✅ Backup IP added with iptables deployment: {backup_id} ({target_ip} → {outline_ip}) for API {selected_api_id}")
                await update.message.reply_text(result_text, parse_mode='HTML', reply_markup=self.get_back_to_menu_keyboard())
                
            except Exception as e:
                logger.error(f"❌ Error adding backup IP: {e}")
                import traceback
                logger.error(traceback.format_exc())
                await update.message.reply_text(
                    f"❌ <b>Yedek IP eklenirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
    
    async def web_handler(self, request):
        """Web sunucu işleyici - VPN Client ve Telegram Bot erişimi"""
        path = request.path
        user_agent = request.headers.get('User-Agent', '')
        client_ip = request.remote
        method = request.method
        
        # Her isteği logla (canlı izleme için)
        logger.info(f"🌐 {method} REQUEST | IP: {client_ip} | User-Agent: {user_agent} | Path: {path}")
        
        # Telegram POST isteklerine her zaman izin ver (bot için gerekli)
        if method == 'POST' and 'telegram' in user_agent.lower():
            logger.info(f"✅ TELEGRAM BOT REQUEST | IP: {client_ip} | Method: POST")
            # Telegram webhook handler - bu kısmı atlayıp normal akışa devam et
            pass
        
        # GET istekleri için User-Agent kontrolü
        elif method == 'GET':
            # İzinli User-Agent listesi kontrolü
            allowed_agents = [
                'go-http-client', 'ktor-client'
            ]
            
            user_agent_lower = user_agent.lower()
            is_allowed = any(agent in user_agent_lower for agent in allowed_agents)
            
            if not is_allowed:
                logger.info(f"🚨 UNAUTHORIZED USER-AGENT | IP: {client_ip} | User-Agent: {user_agent} | Path: {path} | Status: 403")
                error_message = (
                    "Men seni göryan :) aşakda görkezilen we sizin halayan VPN programmanyza "
                    "açary dolylygyna kopyalap goyun hem-de açaryn dine 1 ulanyjy üçin niyetlenendigini unutman\n\n"
                    "Outline"
                )
                return web.Response(status=403, text=error_message, content_type='text/plain', charset='utf-8')
        
        # Yeni format: /vip-user/KEY_ID/UDID
        if path.startswith('/vip-user/'):
            path_parts = path.strip('/').split('/')
            
            # URL format kontrolü: /vip-user/KEY_ID/UDID
            if len(path_parts) != 3:
                logger.info(f"❌ INVALID FORMAT | IP: {client_ip} | User-Agent: {user_agent} | Path: {path} | Status: 404")
                return web.Response(status=404, text="Invalid URL format")
            
            key_id = path_parts[1]  # VIP_USER1
            provided_udid = path_parts[2]  # 34RT-65YT-34R3-8U6T
            
            if key_id in self.database['keys']:
                key_data = self.database['keys'][key_id]
                
                # UDID kontrolü
                stored_udid = key_data.get('udid')
                if not stored_udid or stored_udid != provided_udid:
                    logger.info(f"🚨 UDID MISMATCH | Key: {key_id} | IP: {client_ip} | User-Agent: {user_agent} | Provided: {provided_udid} | Stored: {stored_udid} | Status: 403")
                    return web.Response(status=403, text="Invalid UDID")
                
                # Anahtar süresi kontrolü
                created_at = key_data['created_at']
                duration = key_data['duration']
                
                # Süre hesaplama
                if self.is_key_expired(created_at, duration):
                    logger.info(f"🚫 EXPIRED | Key: {key_id} | IP: {client_ip} | User-Agent: {user_agent} | Duration: {duration} | Status: 410")
                    
                    # Süresi dolan anahtarı otomatik sil
                    try:
                        from_master_key = key_data.get('from_master_key', False)
                        outline_key_id = key_data.get('outline_key_id')
                        key_port = key_data.get('port')  # Port bilgisi
                        
                        # Master key'den oluşturulmadıysa Outline API'den sil
                        if outline_key_id and not from_master_key:
                            delete_success = await self.delete_outline_key(outline_key_id, port=key_port)
                            if delete_success:
                                logger.info(f"✅ Expired key removed from Outline: {outline_key_id}")
                            else:
                                logger.warning(f"⚠️ Failed to remove from Outline: {outline_key_id}")
                        elif from_master_key:
                            logger.info(f"🔑 Expired master key - skipping Outline API deletion: {key_id}")
                        
                        port = key_data['port']
                        del self.database['keys'][key_id]
                        self.database['stats']['total_keys'] -= 1
                        self.save_database()
                        
                        logger.info(f"🗑️ Auto-deleted expired key: {key_id[:12]}... (Port {port} released)")
                        
                    except Exception as e:
                        logger.error(f"❌ Error auto-deleting expired key {key_id}: {e}")
                    
                    return web.Response(status=410, text="Key expired and automatically removed")
                
                # İstek sayısını artır
                key_data['requests'] += 1
                self.database['stats']['requests'][key_id] = time.time()
                self.save_database()
                
                # Detaylı başarılı erişim logu
                logger.info(f"✅ SUCCESS | Key: {key_id} | UDID: {provided_udid[:8]}... | IP: {client_ip} | User-Agent: {user_agent} | Request: #{key_data['requests']} | Status: 200")
                
                # SS URL'i döndür
                yaml_content = key_data.get('yaml_content') or ''
                # yaml_content yoksa default_yaml_content'e fallback yap (mod geçişlerinde güvence)
                if not yaml_content:
                    yaml_content = (self.config.get('default_yaml_content') or '').strip()
                if yaml_content:
                    return web.Response(text=yaml_content, content_type='text/plain', charset='utf-8')
                ss_url = key_data.get('ss_url', '')
                if not ss_url:
                    logger.warning(f"⚠️ Key {key_id} has no yaml_content and no ss_url")
                    return web.Response(status=404, text="Key content not available")
                return web.Response(text=ss_url)
            else:
                logger.info(f"❌ KEY NOT FOUND | Key: {key_id} | IP: {client_ip} | User-Agent: {user_agent} | Status: 404")
                return web.Response(status=404, text="Key not found")
        
        return web.Response(status=404, text="Not found")
    
    def is_key_expired(self, created_at: float, duration: str) -> bool:
        """Anahtar süresi dolmuş mu?"""
        try:
            expire_time = self._compute_expire_time(created_at, duration)
            return time.time() > expire_time
        except:
            return False
    
    def validate_duration_format(self, duration: str) -> bool:
        """Süre formatını doğrula - Sadece h, d, y karakterleri kabul edilir"""
        import re
        
        # Süre formatı: sayı + (h|d|y)
        # Örnekler: 1h, 24h, 7d, 30d, 1y, 2y
        pattern = r'^\d+[hdy]$'
        
        if not re.match(pattern, duration):
            return False
        
        # Sayısal değeri kontrol et
        unit = duration[-1]  # Son karakter (h, d, y)
        number_part = duration[:-1]  # Sayı kısmı
        
        try:
            num = int(number_part)
            if num <= 0:
                return False
                
            # Makul sınırlar koy
            if unit == 'h' and (num < 1 or num > 8760):  # 1 saat - 1 yıl (365*24)
                return False
            elif unit == 'd' and (num < 1 or num > 365):  # 1 gün - 1 yıl
                return False
            elif unit == 'y' and (num < 1 or num > 10):   # 1 yıl - 10 yıl
                return False
                
            return True
            
        except ValueError:
            return False
    
    def get_remaining_time(self, created_at: float, duration: str) -> str:
        """Kalan süreyi hesapla"""
        try:
            expire_time = self._compute_expire_time(created_at, duration)
            remaining_seconds = expire_time - time.time()
            
            if remaining_seconds <= 0:
                return "Süresi dolmuş"
            
            days = int(remaining_seconds // (24 * 3600))
            hours = int((remaining_seconds % (24 * 3600)) // 3600)
            
            if days > 0:
                return f"{days} gün {hours} saat"
            else:
                return f"{hours} saat"
                
        except:
            return "Bilinmiyor"

    def _compute_expire_time(self, created_at: float, duration: str) -> float:
        """Süreye göre bitiş zamanını (timestamp) hesapla"""
        if duration.endswith('d'):
            days = int(duration[:-1])
            return created_at + (days * 24 * 3600)
        if duration.endswith('y'):
            years = int(duration[:-1])
            return created_at + (years * 365 * 24 * 3600)
        if duration.endswith('h'):
            hours = int(duration[:-1])
            return created_at + (hours * 3600)
        # Varsayılan: 30 gün
        return created_at + (30 * 24 * 3600)

    def _extract_port_from_ss_url(self, ss_url: str) -> Optional[int]:
        """ss:// URL içinden port'u çıkarmaya çalış"""
        if not ss_url:
            return None
        import re
        match = re.search(r'@[^:]+:(\d+)', ss_url)
        if match:
            return self._to_int_port(match.group(1))
        return None

    async def _reserve_port(self, preferred_port: Optional[int] = None) -> int:
        """Port havuzundan kilitli şekilde port ayır (reserved_ports'e ekler)"""
        async with self.port_lock:
            # Tercih edilen port uygunsa onu seç
            if preferred_port is not None and preferred_port not in self.used_ports and preferred_port not in self.reserved_ports:
                port = preferred_port
            else:
                port = self.get_available_port()
            self.reserved_ports.add(port)
            logger.debug(f"🔒 Port rezerve edildi: {port}")
            return port

    def _release_reserved_port(self, port: Optional[int]):
        """Rezerv portu serbest bırak"""
        port_int = self._to_int_port(port)
        if port_int is None:
            return
        if hasattr(self, 'reserved_ports') and port_int in self.reserved_ports:
            self.reserved_ports.discard(port_int)
            logger.debug(f"🔓 Port rezervasyonu bırakıldı: {port_int}")

    def _reconcile_ports_with_ss_urls(self):
        """Kayıtlı port ile ss_url portunu hizala; uyumsuzsa ss_url portunu kaydet"""
        try:
            changed = 0
            for key_id, key_data in list(self.database.get('keys', {}).items()):
                if key_data.get('from_master_key'):
                    continue  # master mod port havuzunu etkilemez
                stored_port = self._to_int_port(key_data.get('port'))
                parsed_port = self._extract_port_from_ss_url(key_data.get('ss_url', ''))
                if parsed_port and (stored_port is None or stored_port != parsed_port):
                    key_data['port'] = parsed_port
                    changed += 1
                elif stored_port is None and parsed_port is None:
                    # Hiç port yoksa ss_url'den elde edilemedi; ileride port seçimi için placeholder bırak
                    key_data['port'] = None
            if changed > 0:
                self.save_database()
                # Kullanılan port setini yeniden oluştur
                self._sync_used_ports_from_database()
                logger.info(f"✅ Portlar ss_url ile senkronize edildi: {changed} anahtar güncellendi")
        except Exception as e:
            logger.warning(f"⚠️ Port senkronizasyonu sırasında hata: {e}")
    
    async def start_web_server(self):
        """Web sunucusunu başlat"""
        self.web_app = web.Application()
        self.web_app.router.add_get('/vip-user/{key_id}/{udid}', self.web_handler)
        
        runner = web.AppRunner(self.web_app)
        await runner.setup()
        
        site = web.TCPSite(runner, '127.0.0.1', 8444)
        await site.start()
        
        logger.info("Web server started on port 8444")
    
    async def auto_backup_task(self):
        """İlk başlatma yedeği ve her 3 saatte bir otomatik yedek"""
        # Bot polling başlayana kadar bekle (race condition önleme)
        await asyncio.sleep(30)
        while True:
            try:
                import os
                
                logger.info("💾 Auto backup: Creating backup...")
                
                # Yedek dizini oluştur
                backup_dir = "/opt/outline-telegram-bot/backups"
                os.makedirs(backup_dir, exist_ok=True)
                
                # Yedek dosya adı
                timestamp = int(time.time())
                backup_filename = f"backup_{timestamp}.json"
                backup_path = os.path.join(backup_dir, backup_filename)
                
                # Veritabanını yedekle
                backup_data = {
                    'timestamp': timestamp,
                    'created_at': datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S'),
                    'database': self.database,
                    'config': {
                        'outline_apis': self.config['outline_apis'],
                        'language': self.config.get('language', 'TR')
                    }
                }
                
                with open(backup_path, 'w') as f:
                    json.dump(backup_data, f, indent=2)
                
                file_size = os.path.getsize(backup_path) / 1024  # KB
                
                # Telegram'a gönder
                caption = (
                    f"💾 <b>Otomatik Yedek</b>\n\n"
                    f"🕐 <b>Tarih:</b> {datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S')}\n"
                    f"📊 <b>Boyut:</b> {file_size:.2f} KB\n\n"
                    f"💾 <b>İçerik:</b>\n"
                    f"• Anahtarlar: {len(self.database['keys'])} adet\n"
                    f"• API'ler: {len(self.config['outline_apis'])} adet\n"
                    f"• Yedek IP'ler: {len(self.database.get('backup_ips', {}))} adet"
                )
                
                developer_id = int(self.config['developer_id'])
                
                with open(backup_path, 'rb') as f:
                    await self.app.bot.send_document(
                        chat_id=developer_id,
                        document=f,
                        filename=backup_filename,
                        caption=caption,
                        parse_mode='HTML'
                    )
                
                # Sunucudan sil
                os.remove(backup_path)
                
                logger.info(f"✅ Auto backup sent and deleted: {backup_filename}")
                
            except Exception as e:
                logger.error(f"❌ Auto backup error: {e}")
            
            # 3 saat bekle (10800 saniye)
            await asyncio.sleep(10800)
    
    async def cleanup_expired_keys(self):
        """Süresi dolan anahtarları otomatik sil - Geliştirilmiş"""
        cleanup_count = 0
        
        while True:
            try:
                expired_keys = []
                current_time = time.time()
                
                # Tüm anahtarları kontrol et
                for key_id, key_data in self.database['keys'].items():
                    created_at = key_data['created_at']
                    duration = key_data['duration']
                    
                    if self.is_key_expired(created_at, duration):
                        expired_keys.append((key_id, key_data))
                
                # Süresi dolan anahtarları sil
                deleted_ports = []
                for key_id, key_data in expired_keys:
                    try:
                        # Outline sunucusundan sil
                        outline_key_id = key_data.get('outline_key_id')
                        key_port = key_data.get('port')  # Port bilgisi
                        if outline_key_id:
                            delete_success = await self.delete_outline_key(outline_key_id, port=key_port)
                            if not delete_success:
                                logger.warning(f"Failed to delete from Outline: {outline_key_id}")
                        
                        # Veritabanından sil
                        port = key_data['port']
                        del self.database['keys'][key_id]
                        deleted_ports.append(port)
                        
                        logger.info(f"🗑️ Expired key auto-deleted: {key_id[:12]}... (Port {port})")
                        
                    except Exception as e:
                        logger.error(f"❌ Error deleting expired key {key_id}: {e}")
                
                # İstatistikleri güncelle
                if expired_keys:
                    self.database['stats']['total_keys'] -= len(expired_keys)
                    self.save_database()
                    cleanup_count += len(expired_keys)
                    
                    logger.info(f"✅ Cleaned up {len(expired_keys)} expired keys. Total cleaned: {cleanup_count}")
                    logger.info(f"🔓 Released ports: {', '.join(map(str, deleted_ports))}")
                
                # Her saat temizlik yap (3600 saniye)
                await asyncio.sleep(3600)
                
            except Exception as e:
                logger.error(f"❌ Error in cleanup task: {e}")
                # Hata durumunda 30 dakika bekle
                await asyncio.sleep(1800)

    async def document_handler(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Dosya (Document) işleyici - Yedek geri yükleme"""
        user_id = update.effective_user.id
        if not self.is_authorized(user_id):
            return
        
        document = update.message.document
        filename = document.file_name
        state = context.user_data.get('state')

        # Backup + YAML yükleme akışı
        if state == 'waiting_restore_yaml_upload':
            if not (filename.lower().endswith('.yaml') or filename.lower().endswith('.yml')):
                await update.message.reply_text(
                    "❌ <b>Geçersiz dosya!</b>\n\n"
                    "Lütfen <code>.yaml</code> veya <code>.yml</code> uzantılı YAML dosyası gönderin.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                return

            try:
                import os
                import shutil

                backup_path = context.user_data.get('backup_path')
                backup_data = context.user_data.get('backup_data')
                backup_filename = context.user_data.get('backup_filename', 'backup_*.json')

                if not backup_path or not backup_data:
                    await update.message.reply_text(
                        "❌ <b>Yedek bilgisi bulunamadı!</b>\n\n"
                        "Lütfen backup dosyasını tekrar gönderin.",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return

                processing_msg = await update.message.reply_text(
                    "⏳ <b>YAML ile geri yükleme yapılıyor...</b>",
                    parse_mode='HTML'
                )

                # YAML dosyasını indir
                file = await context.bot.get_file(document.file_id)
                yaml_path = f"/tmp/{int(time.time())}_{filename}"
                await file.download_to_drive(yaml_path)

                with open(yaml_path, 'r', encoding='utf-8') as f:
                    yaml_content = f.read().strip()

                if not yaml_content:
                    await processing_msg.edit_text(
                        "❌ <b>YAML dosyası boş!</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return

                # Mevcut veritabanını güvenlik için yedekle (varsa)
                current_backup_path = f"{self.config['database']['path']}.before_restore.{int(time.time())}"
                if os.path.exists(self.config['database']['path']):
                    shutil.copy(self.config['database']['path'], current_backup_path)

                # Backup verisini geri yükle
                self.database = backup_data['database']
                if 'backup_ips' not in self.database:
                    self.database['backup_ips'] = {}

                # Tüm anahtarlara YAML uygula
                restored_keys = 0
                for key_id in self.database.get('keys', {}):
                    self.database['keys'][key_id]['yaml_content'] = yaml_content
                    restored_keys += 1

                self.save_database()
                self._sync_used_ports_from_database()

                # Bot config'i YAML moduna al
                self.config['default_yaml_content'] = yaml_content
                self.config['outline_apis'] = []
                self.set_connection_mode('yaml')

                # Geçici dosyaları temizle
                try:
                    if os.path.exists(backup_path):
                        os.remove(backup_path)
                    if os.path.exists(yaml_path):
                        os.remove(yaml_path)
                except Exception:
                    pass

                context.user_data.clear()

                restored_backup_ips = len(self.database.get('backup_ips', {}))
                await processing_msg.edit_text(
                    f"✅ <b>YAML ile yedek başarıyla geri yüklendi!</b>\n\n"
                    f"📁 <b>Backup:</b> <code>{backup_filename}</code>\n"
                    f"📄 <b>YAML:</b> <code>{filename}</code>\n\n"
                    f"♻️ <b>Geri Yüklenen:</b>\n"
                    f"• Anahtarlar: <code>{restored_keys}</code> adet\n"
                    f"• Yedek IP'ler: <code>{restored_backup_ips}</code> adet\n\n"
                    f"⚙️ <b>Mod:</b> YAML\n"
                    + (f"🔒 Eski veritabanı yedeklendi:\n<code>{current_backup_path}</code>" if os.path.exists(current_backup_path) else "ℹ️ Temiz kurulum — önceki veritabanı yok."),  # noqa
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                return

            except Exception as e:
                logger.error(f"❌ Error restoring backup with yaml: {e}")
                import traceback
                logger.error(traceback.format_exc())
                await update.message.reply_text(
                    f"❌ <b>YAML ile geri yükleme hatası!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return

        # Yaml yükleme akışı
        if state == 'waiting_yaml_upload':
            if not (filename.lower().endswith('.yaml') or filename.lower().endswith('.yml')):
                await update.message.reply_text(
                    "❌ <b>Geçersiz dosya!</b>\n\n"
                    "Lütfen <code>.yaml</code> veya <code>.yml</code> uzantılı dosya gönderin.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                return

            try:
                processing_msg = await update.message.reply_text("⏳ <b>Yaml dosyası işleniyor...</b>", parse_mode='HTML')

                file = await context.bot.get_file(document.file_id)
                yaml_path = f"/tmp/{int(time.time())}_{filename}"
                await file.download_to_drive(yaml_path)

                with open(yaml_path, 'r', encoding='utf-8') as f:
                    yaml_content = f.read().strip()

                if not yaml_content:
                    await processing_msg.edit_text(
                        "❌ <b>Yaml dosyası boş!</b>",
                        parse_mode='HTML',
                        reply_markup=self.get_back_to_menu_keyboard()
                    )
                    context.user_data.clear()
                    return

                # Gelecekte oluşturulacak anahtarlar için varsayılan YAML
                self.config['default_yaml_content'] = yaml_content
                # Eski API'leri tamamen temizle (YAML modunda API olmamalı)
                self.config['outline_apis'] = []
                self.set_connection_mode('yaml')
                self.save_config()

                # Mevcut tüm anahtarlara uygula
                updated_count = 0
                for key_id in self.database.get('keys', {}):
                    self.database['keys'][key_id]['yaml_content'] = yaml_content
                    updated_count += 1
                self.save_database()

                try:
                    import os
                    os.remove(yaml_path)
                except Exception:
                    pass

                await processing_msg.edit_text(
                    f"✅ <b>Yaml başarıyla eklendi!</b>\n\n"
                    f"📄 <b>Dosya:</b> <code>{filename}</code>\n"
                    f"📦 <b>Güncellenen mevcut anahtar:</b> <code>{updated_count}</code>\n"
                    f"🔮 <b>Yeni anahtarlar:</b> Otomatik bu YAML ile oluşturulacak.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return

            except Exception as e:
                logger.error(f"❌ Error processing yaml file: {e}")
                import traceback
                logger.error(traceback.format_exc())
                await update.message.reply_text(
                    f"❌ <b>Yaml dosyası işlenirken hata!</b>\n\n"
                    f"🔍 Hata: <code>{str(e)}</code>",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                context.user_data.clear()
                return
        
        # Sadece backup JSON dosyalarını kabul et
        if not (filename.startswith('backup_') and filename.endswith('.json')):
            await update.message.reply_text(
                f"❌ <b>Geçersiz dosya!</b>\n\n"
                f"Sadece <code>backup_*.json</code> dosyaları kabul edilir.\n\n"
                f"Dosya adı: <code>{filename}</code>",
                parse_mode='HTML',
                reply_markup=self.get_back_to_menu_keyboard()
            )
            return
        
        try:
            import os
            import shutil
            
            # İşleniyor mesajı
            processing_msg = await update.message.reply_text("⏳ <b>Yedek dosyası kontrol ediliyor...</b>", parse_mode='HTML')
            
            # Dosyayı indir
            file = await context.bot.get_file(document.file_id)
            backup_path = f"/tmp/{filename}"
            await file.download_to_drive(backup_path)
            
            # JSON'u oku ve doğrula
            with open(backup_path, 'r') as f:
                backup_data = json.load(f)
            
            # Yedek formatını kontrol et
            if 'database' not in backup_data or 'config' not in backup_data:
                os.remove(backup_path)
                await processing_msg.edit_text(
                    f"❌ <b>Geçersiz yedek formatı!</b>\n\n"
                    f"Bu dosya geçerli bir yedek dosyası değil.",
                    parse_mode='HTML',
                    reply_markup=self.get_back_to_menu_keyboard()
                )
                return
            
            # Backup bilgilerini context'e kaydet
            context.user_data['backup_path'] = backup_path
            context.user_data['backup_data'] = backup_data
            context.user_data['backup_filename'] = filename
            
            # İstatistikler
            backup_keys = len(backup_data['database']['keys'])
            backup_apis = backup_data['config'].get('outline_apis', [])
            backup_api_count = len(backup_apis)
            backup_backup_ips = len(backup_data['database'].get('backup_ips', {}))
            
            # API seçim menüsü
            selection_text = (
                f"♻️ <b>Yedek Geri Yükleme - API Seçimi</b>\n\n"
                f"📁 <b>Dosya:</b> <code>{filename}</code>\n"
                f"🕐 <b>Yedek Tarihi:</b> {backup_data.get('created_at', 'Bilinmeyen')}\n\n"
                f"📦 <b>Yedek İçeriği:</b>\n"
                f"• Anahtarlar: <code>{backup_keys}</code> adet\n"
                f"• API'ler: <code>{backup_api_count}</code> adet\n"
                f"• Yedek IP'ler: <code>{backup_backup_ips}</code> adet\n\n"
            )
            
            # Backup'daki API'leri göster
            if backup_apis:
                selection_text += f"🖥️ <b>Yedekteki API'ler:</b>\n"
                for api in backup_apis:
                    api_id = api.get('id', 'Bilinmiyen')
                    api_name = api.get('name', 'Bilinmiyen')
                    api_ip = self.get_ip_from_api_url(api['api']['apiUrl'])
                    selection_text += f"• {api_name} ({api_id}) - {api_ip}\n"
                selection_text += "\n"
            
            selection_text += (
                f"❓ <b>Anahtarlar nasıl oluşturulsun?</b>\n\n"
                f"<b>1️⃣ Mevcut API'den Oluştur:</b>\n"
                f"   Backup'daki API'leri kullan\n"
                f"   (Anahtarlar yedekteki API ayarlarıyla oluşturulur)\n\n"
                f"<b>2️⃣ Yeni API Ekle:</b>\n"
                f"   Yeni bir API ekleyip oradan oluştur\n"
                f"   (Önce API ekleyeceksiniz, sonra anahtarlar oluşturulacak)\n\n"
                f"<b>3️⃣ YAML Dosya ile Yükle:</b>\n"
                f"   API kullanmadan yedek verilerini yükle\n"
                f"   (Sonraki adımda YAML dosyası göndereceksiniz)"
            )
            
            keyboard = [
                [InlineKeyboardButton("✅ Mevcut API'den Oluştur", callback_data="restore_with_backup_api")],
                [InlineKeyboardButton("➕ Yeni API Ekle", callback_data="restore_with_new_api")],
                [InlineKeyboardButton("📄 YAML Dosya ile Yükle", callback_data="restore_with_yaml_file")],
                [InlineKeyboardButton("❌ İptal", callback_data="cancel_restore")]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await processing_msg.edit_text(selection_text, parse_mode='HTML', reply_markup=reply_markup)
            
        except json.JSONDecodeError:
            await update.message.reply_text(
                f"❌ <b>JSON okuma hatası!</b>\n\n"
                f"Dosya bozuk veya geçersiz.",
                parse_mode='HTML',
                reply_markup=self.get_back_to_menu_keyboard()
            )
        except Exception as e:
            logger.error(f"❌ Error processing backup file: {e}")
            import traceback
            logger.error(traceback.format_exc())
            await update.message.reply_text(
                f"❌ <b>Yedek dosyası işlenirken hata!</b>\n\n"
                f"🔍 Hata: <code>{str(e)}</code>",
                parse_mode='HTML',
                reply_markup=self.get_back_to_menu_keyboard()
            )

    async def run(self):
        """Bot'u çalıştır"""
        # Web sunucusunu başlat (tek seferlik)
        await self.start_web_server()
        
        # Telegram bağlantısı için retry döngüsü
        retry_count = 0
        while True:
            # Her denemede app'i yeniden oluştur
            proxy_url = self.config.get('telegram_proxy') or ''
            if proxy_url:
                request = HTTPXRequest(proxy=proxy_url, connect_timeout=30, read_timeout=30)
                self.app = Application.builder().token(self.config['bot_token']).request(request).build()
            else:
                self.app = Application.builder().token(self.config['bot_token']).build()
            
            # Handler'ları ekle
            self.app.add_handler(CommandHandler("start", self.start_command))
            self.app.add_handler(CallbackQueryHandler(self.button_handler))
            self.app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, self.message_handler))
            self.app.add_handler(MessageHandler(filters.Document.ALL, self.document_handler))
            
            try:
                async with self.app:
                    # App başarıyla initialize edildi - görevleri şimdi başlat
                    cleanup_task = asyncio.create_task(self.cleanup_expired_keys())
                    backup_task = asyncio.create_task(self.auto_backup_task())
                    
                    await self.app.start()
                    await self.app.updater.start_polling()
                    
                    # Sonsuza kadar çalış
                    try:
                        await asyncio.Event().wait()
                    except KeyboardInterrupt:
                        logger.info("Bot durduriliyor...")
                        cleanup_task.cancel()
                        backup_task.cancel()
                    finally:
                        await self.app.updater.stop()
                        await self.app.stop()
                break  # Normal çıkış
            except (TimedOut, NetworkError) as e:
                retry_count += 1
                wait_time = min(120, 10 * retry_count)
                logger.warning(f"⚠️ Telegram bağlantı hatası ({retry_count}. deneme): {e} — {wait_time}s sonra yeniden denenecek...")
                await asyncio.sleep(wait_time)

if __name__ == "__main__":
    try:
        logger.info("🤖 Outline Telegram Bot başlatılıyor...")
        config_path = "/etc/outline-bot/config.json"
        
        if not os.path.exists(config_path):
            logger.error(f"❌ Config dosyası bulunamadı: {config_path}")
            exit(1)
        
        bot = OutlineBot(config_path)
        logger.info("✅ Bot başarıyla yüklendi")
        asyncio.run(bot.run())
    except KeyboardInterrupt:
        logger.info("🛑 Bot kullanıcı tarafından durduruldu")
        exit(0)
    except FileNotFoundError as e:
        logger.error(f"❌ Dosya bulunamadı: {e}")
        exit(1)
    except json.JSONDecodeError as e:
        logger.error(f"❌ Config dosyasında JSON hatası: {e}")
        exit(1)
    except Exception as e:
        logger.error(f"❌ Bot başlatma hatası: {type(e).__name__}: {e}")
        logger.error(traceback.format_exc())
        exit(1)
PYTHON_EOF
    
    chmod +x "$INSTALL_DIR/bot.py"
    success "Bot kodu oluşturuldu"
}

# Python gereksinimleri
install_python_requirements() {
    info "Python gereksinimleri kuruluyor..."
    
    cat > "$INSTALL_DIR/requirements.txt" << EOF
python-telegram-bot==20.7
aiohttp==3.9.1
aiofiles==23.2.1
cryptography==41.0.7
pyopenssl==23.3.0
EOF
    
    # Virtual environment oluştur
    info "Python virtual environment oluşturuluyor..."
    if ! python3 -m venv "$INSTALL_DIR/venv"; then
        warning "İlk denemede venv oluşturulamadı, Python venv bağımlılıkları kurulup tekrar denenecek..."
        python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        apt update
        apt install -y python3-venv python${python_version}-venv python3-distutils || \
        apt install -y python${python_version}-venv python3-venv || \
        error "Python venv paketleri kurulamadı"

        if ! python3 -m venv "$INSTALL_DIR/venv"; then
            error "Virtual environment oluşturulamadı! python3-venv / python${python_version}-venv paketi eksik olabilir."
        fi
    fi
    
    # Virtual environment'ı aktifleştir ve pip'i güncelle
    source "$INSTALL_DIR/venv/bin/activate"
    
    # Pip'i güncelle
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
    
    # Gereksinimleri kur
    if ! "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"; then
        error "Python paketleri kurulamadı! İnternet bağlantısını kontrol edin."
    fi
    
    # Virtual environment'dan çık
    deactivate 2>/dev/null || true
    
    success "Python gereksinimleri kuruldu"
}

# Systemd servisi
create_systemd_service() {
    info "Systemd servisi oluşturuluyor..."
    
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=Outline VPN Telegram Bot
After=network.target nginx.service
Wants=network.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/bot.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Güvenlik ayarları
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR /var/log /etc/outline-bot
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

# Kaynak sınırları
MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    success "Systemd servisi oluşturuldu"
}

# Servisi başlat
start_services() {
    info "Servisler başlatılıyor..."
    
    # Nginx'i yeniden başlat
    systemctl restart nginx
    
    # Bot servisini başlat
    systemctl start "$SERVICE_NAME"
    
    sleep 3
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "Bot servisi başarıyla başlatıldı"
    else
        error "Bot servisi başlatılamadı"
    fi
}

# Durum kontrolü
check_status() {
    echo
    echo -e "${PURPLE}📊 SİSTEM DURUMU${NC}"
    echo "══════════════════════════════════════════"
    
    # Servis durumu
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "Bot Servisi: ${GREEN}Çalışıyor ✅${NC}"
    else
        echo -e "Bot Servisi: ${RED}Durdu ❌${NC}"
    fi
    
    # Nginx durumu
    if systemctl is-active --quiet nginx; then
        echo -e "Nginx: ${GREEN}Çalışıyor ✅${NC}"
    else
        echo -e "Nginx: ${RED}Durdu ❌${NC}"
    fi
    
    # SSL durumu
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        echo -e "SSL Sertifikası: ${GREEN}Mevcut ✅${NC}"
    else
        echo -e "SSL Sertifikası: ${RED}Yok ❌${NC}"
    fi
    
    echo -e "Domain: ${GREEN}$DOMAIN${NC}"
    echo -e "Dil: ${GREEN}$LANGUAGE${NC}"
    
    echo
    echo -e "${YELLOW}💡 Yararlı Komutlar:${NC}"
    echo "  Bot durumu: systemctl status $SERVICE_NAME"
    echo "  Bot logları: journalctl -u $SERVICE_NAME -f"
    echo "  Nginx durumu: systemctl status nginx"
    echo "  SSL yenile (manuel): certbot renew --force-renewal"
    echo "  SSL otomatik yenileme durumu: systemctl status certbot.timer"
    echo "  SSL sertifika bilgisi: certbot certificates"
}

# Kaldırma
uninstall() {
    echo -e "${RED}🗑️  OUTLINE TELEGRAM BOT KALDIRILIYOR${NC}"
    
    # Servisleri durdur
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
    # Dosyaları sil
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    rm -rf "$INSTALL_DIR"
    rm -rf "$(dirname "$CONFIG_FILE")"
    rm -f "$NGINX_CONFIG" "$NGINX_ENABLED"
    
    systemctl daemon-reload
    systemctl restart nginx
    
    success "Outline Telegram Bot kaldırıldı"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 📋 CHANGELOG & FEATURES
# ═══════════════════════════════════════════════════════════════════════════════
#
# 🆕 VERSION 2.1 - ENHANCED FEATURES:
# ✅ Sabit 444 port kullanımı (Outline standart)
# ✅ Anahtar silme: Sıra numarası ile işlem
# ✅ Süresi dolan anahtarların otomatik silinmesi
# ✅ Ana menü yenileme - /start benzeri davranış
# ✅ Anahtarlar chatte görünür kalır
# ✅ Gelişmiş loglama ve hata yönetimi
# ✅ "Menüyü Yenile" butonu
# ✅ Yedek IP sistemi ve yönlendirme
#
# 🔧 TECHNICAL IMPROVEMENTS:
# ✅ Outline API entegrasyonu (444 port)
# ✅ SSL/Nginx otomasyonu
# ✅ Python3-venv dinamik kurulum
# ✅ Systemd servis yönetimi
# ✅ Sadece Outline Client erişimi
# ✅ Çoklu dil desteği (TR/RU)
# ✅ Veritabanı ve istatistik sistemi
# ✅ Çoklu API desteği
#
# ═══════════════════════════════════════════════════════════════════════════════

# Ana fonksiyon
main() {
    print_banner
    
    case "${1:-}" in
        "uninstall")
            check_root
            uninstall
            exit 0
            ;;
        "status")
            check_status
            exit 0
            ;;
        "fix-config")
            # Config dosyasını düzelt
            echo -e "${YELLOW}🔧 Config dosyası düzeltiliyor...${NC}"
            python3 -c "
import json
import os
cfg_file = '/etc/outline-bot/config.json'
if os.path.exists(cfg_file):
    cfg = json.load(open(cfg_file))
    cfg['language'] = cfg.get('language') if cfg.get('language') in ['TR', 'RU'] else 'TR'
    json.dump(cfg, open(cfg_file, 'w'), indent=2, ensure_ascii=False)
    print('✅ Config düzeltildi')
else:
    print('❌ Config dosyası bulunamadı')
"
            systemctl restart outline-telegram-bot 2>/dev/null || true
            exit 0
            ;;
    esac
    
    # Normal kurulum
    set -e  # Hata durumunda hemen çık
    
    trap 'error "Kurulum başarısız oldu. Lütfen logları kontrol edin."' ERR
    
    check_root
    check_requirements
    get_user_config
    create_directories
    create_config
    setup_ssl
    setup_nginx
    create_bot_code
    install_python_requirements
    create_systemd_service
    start_services
    
    sleep 3
    
    # Bot servisi başarılı başladı mı kontrol et
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warning "Bot servisi hemen başlamadı, 10 saniye daha bekle..."
        sleep 10
    fi
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        check_status
        
        echo
        echo -e "${GREEN}🎉 KURULUM TAMAMLANDI!${NC}"
        echo
        echo -e "${CYAN}Outline VPN Telegram Bot başarıyla kuruldu!${NC}"
        echo -e "🌐 Domain: ${GREEN}https://$DOMAIN${NC}"
        echo -e "🤖 Bot Token: ${GREEN}Yapılandırıldı${NC}"
        echo -e "🔐 SSL: ${GREEN}Aktif${NC}"
        echo -e "🌍 Dil: ${GREEN}$LANGUAGE${NC}"
        echo
        echo -e "${YELLOW}Bot'u kullanmaya başlayabilirsiniz:${NC}"
        echo "  Telegram'da /start yazın"
        echo
        echo -e "${YELLOW}Logları izlemek için:${NC}"
        echo "  journalctl -u $SERVICE_NAME -f"
        echo
        echo -e "${YELLOW}Konfigürasyonu kontrol etmek için:${NC}"
        echo "  cat /etc/outline-bot/config.json"
    else
        error "Bot servisi başlatılamadı. Logları kontrol et: journalctl -u $SERVICE_NAME"
    fi
}

main "$@"
