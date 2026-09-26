#!/bin/bash
set -e

echo
echo "========================================"
echo " Ubuntu 24.04 PRoot Web Stack Installer"
echo "========================================"
echo

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] This script must run as root inside Ubuntu."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

echo "[OK] Running as root."

# ========================================
# 1. Update
# ========================================

echo
echo "[1/10] Updating package lists..."

apt-get update

# ========================================
# 2. Basic tools
# ========================================

echo
echo "[2/10] Installing basic tools..."

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    unzip \
    nano

# ========================================
# 3. PHP common
# ========================================

echo
echo "[3/10] Installing PHP 8.3 common..."

apt-get install -y php8.3-common || true

# ========================================
# 4. Fix ucf / ucfr for PRoot
# ========================================

echo
echo "[4/10] Fixing ucf / ucfr for PRoot..."

if [ -f /usr/bin/ucf ]; then

    if [ ! -f /usr/bin/ucf.bak ]; then
        cp /usr/bin/ucf /usr/bin/ucf.bak
    fi

    sed -i '569,574s/^/# /' /usr/bin/ucf

    echo "[OK] ucf patched."

else
    echo "[WARN] /usr/bin/ucf not found."
fi


if [ -f /usr/bin/ucfr ]; then

    if [ ! -f /usr/bin/ucfr.bak ]; then
        cp /usr/bin/ucfr /usr/bin/ucfr.bak
    fi

    sed -i '307,312s/^/# /' /usr/bin/ucfr

    echo "[OK] ucfr patched."

else
    echo "[WARN] /usr/bin/ucfr not found."
fi

# ========================================
# 5. Fix PHP maintenance helper
# ========================================

echo
echo "[5/10] Fixing PHP maintenance helper..."

HELPER="/usr/lib/php/php-maintscript-helper"

if [ -f "$HELPER" ]; then

    if [ ! -f "${HELPER}.bak" ]; then
        cp "$HELPER" "${HELPER}.bak"
    fi

    sed -i \
        's/\[ -x "\/usr\/sbin\/php\$CMD" \]/[ -f "\/usr\/sbin\/php$CMD" ]/' \
        "$HELPER"

    sed -i \
        's/\[ -x "\/usr\/sbin\/phpquery" \]/[ -f "\/usr\/sbin\/phpquery" ]/' \
        "$HELPER"

    echo "[OK] php-maintscript-helper patched."

else
    echo "[WARN] php-maintscript-helper not found."
fi

# ========================================
# 6. Configure PHP common
# ========================================

echo
echo "[6/10] Configuring PHP 8.3 common..."

dpkg --configure php8.3-common

# ========================================
# 7. PHP CLI + extensions
# ========================================

echo
echo "[7/10] Installing PHP 8.3 CLI and extensions..."

apt-get install -y \
    php8.3-cli \
    php-curl \
    php-mbstring \
    php-xml \
    php-zip

# ========================================
# 8. Enable PHP CLI + FPM modules
# ========================================

echo
echo "[8/10] Enabling PHP modules..."

mkdir -p /etc/php/8.3/cli/conf.d
mkdir -p /etc/php/8.3/fpm/conf.d

# CURL
if [ -f /etc/php/8.3/mods-available/curl.ini ]; then

    ln -sf \
        /etc/php/8.3/mods-available/curl.ini \
        /etc/php/8.3/cli/conf.d/20-curl.ini

    ln -sf \
        /etc/php/8.3/mods-available/curl.ini \
        /etc/php/8.3/fpm/conf.d/20-curl.ini

fi

# MBSTRING
if [ -f /etc/php/8.3/mods-available/mbstring.ini ]; then

    ln -sf \
        /etc/php/8.3/mods-available/mbstring.ini \
        /etc/php/8.3/cli/conf.d/20-mbstring.ini

    ln -sf \
        /etc/php/8.3/mods-available/mbstring.ini \
        /etc/php/8.3/fpm/conf.d/20-mbstring.ini

fi

# XML
if [ -f /etc/php/8.3/mods-available/xml.ini ]; then

    ln -sf \
        /etc/php/8.3/mods-available/xml.ini \
        /etc/php/8.3/cli/conf.d/20-xml.ini

    ln -sf \
        /etc/php/8.3/mods-available/xml.ini \
        /etc/php/8.3/fpm/conf.d/20-xml.ini

fi

# ZIP
if [ -f /etc/php/8.3/mods-available/zip.ini ]; then

    ln -sf \
        /etc/php/8.3/mods-available/zip.ini \
        /etc/php/8.3/cli/conf.d/20-zip.ini

    ln -sf \
        /etc/php/8.3/mods-available/zip.ini \
        /etc/php/8.3/fpm/conf.d/20-zip.ini

fi

echo "[OK] PHP modules enabled."

# ========================================
# 9. Standalone tmpfiles
# ========================================

echo
echo "[9/10] Installing standalone tmpfiles..."

apt-get install -y systemd-standalone-tmpfiles

# ========================================
# 10. PHP-FPM + Nginx
# ========================================

echo
echo "[10/10] Installing PHP-FPM..."

apt-get install -y \
    php8.3-fpm \
    php-fpm

echo
echo "Installing Nginx..."

apt-get install -y nginx

# ========================================
# Final check
# ========================================

echo
echo "========================================"
echo " Final check"
echo "========================================"

echo
echo "[PHP]"
php -v

echo
echo "[PHP modules]"

php -m | grep -E \
    'curl|mbstring|xml|zip|libxml' || true

echo
echo "[Required functions]"

php -r '
echo "curl_init:         ";
var_dump(function_exists("curl_init"));

echo "file_get_contents: ";
var_dump(function_exists("file_get_contents"));

echo "json_decode:       ";
var_dump(function_exists("json_decode"));

echo "mbstring:          ";
var_dump(extension_loaded("mbstring"));
'

echo
echo "[PHP-FPM]"

php-fpm8.3 -v

echo
echo "[PHP-FPM modules]"

php-fpm8.3 -i | grep -E \
    'Additional .ini files parsed|mbstring|curl' | head -20 || true

echo
echo "[Nginx]"

nginx -v

echo
echo "[Package status]"

dpkg --audit

echo
echo "========================================"
echo " Installation finished"
echo "========================================"
echo
echo "PHP 8.3       : installed"
echo "PHP-CURL      : installed"
echo "PHP-MBSTRING  : installed"
echo "PHP-XML       : installed"
echo "PHP-ZIP       : installed"
echo "PHP-FPM       : installed"
echo "Nginx         : installed"
echo
echo "systemd       : NOT USED"
echo
echo "PHP-FPM/Nginx are NOT started automatically."
echo
echo "Start PHP-FPM:"
echo "  mkdir -p /run/php && php-fpm8.3 -D"
echo
echo "Start Nginx:"
echo "  nginx"
echo
echo "========================================"
echo