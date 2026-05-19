#!/bin/sh
set -e

# --- 1. VARIABLE DETECTION & TARGET DOMAIN ---
# If behind a Reverse Proxy, Caddy MUST listen on port 80 only
if [ "$REVERSE_PROXY" = "yes" ]; then
    echo "[ INFO ] Reverse Proxy Mode Active. Forcing Caddy to listen on port :80..."
    DOMAIN_TARGET=":80"
    
    # Add configuration so Caddy trusts IP headers from Traefik/NPM
    TRUSTED_PROXIES_BLOCK="servers {
        trusted_proxies static private_ranges
    }"
else
    DOMAIN_TARGET=${NC_DOMAIN:-:80}
    TRUSTED_PROXIES_BLOCK=""
fi

# Determine Caddy Domain Block format (If OnlyOffice exists)
if [ -n "$ONLYOFFICE_HOST" ]; then
    CADDY_DOMAINS="${DOMAIN_TARGET}, http://${NC_HOST}"
    echo "[ INFO ] ONLYOFFICE Detected: Caddy Domains set to -> $CADDY_DOMAINS"
else
    CADDY_DOMAINS="${DOMAIN_TARGET}"
    echo "[ INFO ] Target Domain set to -> $CADDY_DOMAINS"
fi


# --- 2. CADDYFILE INITIALIZATION ---
CADDYFILE="/etc/caddy/Caddyfile"
echo "[ INFO ] Preparing Caddyfile..."

## generate Caddyfile
cat <<EOF > "$CADDYFILE"
{
    frankenphp {
        num_threads 4
    }
    order php_server before file_server
    
    # Conditional block to trust Reverse Proxy IPs
    ${TRUSTED_PROXIES_BLOCK}
}

# --- Block Domain --- 
${CADDY_DOMAINS} {
    root * /var/www/html
    encode zstd br gzip
    
    # Security Headers
    header {
        Strict-Transport-Security "max-age=15768000;"
        X-XSS-Protection "1; mode=block"
        X-Download-Options "noopen"
        Referrer-Policy "no-referrer"
    }

    # Static Cache
    @static {
        path *.css *.js *.svg *.gif *.png *.html *.ttf *.woff *.woff2 *.ico *.jpg *.jpeg *.map
    }
    header @static Cache-Control "max-age=15778463"

    # Deny Sensitive Folders
    @forbidden {
        path /build/* /tests/* /config/* /lib/* /3rdparty/* /templates/* /data/* /.ht* /.user.ini /autotest* /occ* /issue* /indie* /db_* /console*
    }
    respond @forbidden 403

    # Redirect Rules
    redir /.well-known/carddav /remote.php/dav 301
    redir /.well-known/caldav /remote.php/dav 301
    redir /.well-known/webfinger /index.php/.well-known/webfinger 301
    redir /.well-known/nodeinfo /index.php/.well-known/nodeinfo 301

    # Main Routing
    rewrite /index.php/* /{path}
    try_files {path} {path}/index.php /index.php{uri}

    php_server {
        resolve_root_symlink
        env PATH /bin
        env modHeadersAvailable true
        env front_controller_active true
    }
EOF

# --- Add Notify Push Condition ---
if [ -n "$NOTIFY_PUSH_HOST" ]; then
    echo "[ INFO ] Activating Caddy block for notify_push ($NOTIFY_PUSH_HOST)..."
    cat <<EOF >> "$CADDYFILE"
    
    handle_path /push/* {
        reverse_proxy http://${NOTIFY_PUSH_HOST}:7867 {
            header_up X-Forwarded-Host {host}
        }
    }
EOF
fi

# --- Add OnlyOffice Condition ---
if [ -n "$ONLYOFFICE_HOST" ]; then
    echo "[ INFO ] Activating Caddy block for ONLYOFFICE ($ONLYOFFICE_HOST)..."
    cat <<EOF >> "$CADDYFILE"
    
    handle_path /ds-vpath/* {
        reverse_proxy http://${ONLYOFFICE_HOST}:80 {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Port 443
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Prefix /ds-vpath
        }
    }
EOF
fi

# --- Close Caddyfile ---
cat <<EOF >> "$CADDYFILE"
    file_server
}
EOF

echo "[ OK ] Caddyfile successfully generated!"


# --- 3. NEXTCLOUD DOWNLOAD & UPGRADE PROCESS ---
NEED_UPGRADE=false

if [ ! -f "/var/www/html/version.php" ]; then
    echo "[ INFO ] Copying Nextcloud to /var/www/html folder for the first time..."
    # Copy files using rsync
    rsync -a /usr/src/nextcloud/ /var/www/html/
    mkdir -p /var/www/html/data
    chown -R www-data:www-data /var/www/html
else
    # Compare version.php to detect if an upgrade is needed
    if ! cmp -s /usr/src/nextcloud/version.php /var/www/html/version.php; then
        echo "[ INFO ] Version difference detected. Preparing for upgrade..."
        
        echo "[ INFO ] Cleaning up old core files to prevent EXTRA_FILE and class conflicts..."
        # 1. Hapus seluruh folder sistem lama hingga akar agar tidak ada file sisa (EXTRA_FILE)
        rm -rf /var/www/html/core \
               /var/www/html/dist \
               /var/www/html/lib \
               /var/www/html/3rdparty \
               /var/www/html/ocs \
               /var/www/html/ocs-provider \
               /var/www/html/updater

        echo "[ INFO ] Cleaning up old default apps without touching custom apps..."
        # 2. Hapus HANYA aplikasi bawaan lama (core apps) dari folder apps/
        # Menggunakan perulangan untuk mencocokkan aplikasi dari /usr/src agar custom apps aman
        for core_app in /usr/src/nextcloud/apps/*; do
            app_name=$(basename "$core_app")
            rm -rf "/var/www/html/apps/$app_name"
        done
        
        echo "[ INFO ] Syncing new Nextcloud files..."
        # 3. Sinkronisasi versi baru ke dalam direktori yang sudah bersih
        rsync -a --exclude 'data' --exclude 'config/config.php' /usr/src/nextcloud/ /var/www/html/
        chown -R www-data:www-data /var/www/html
        NEED_UPGRADE=true
    else
        echo "[ OK ] Nextcloud version is up to date."
    fi
fi

# --- 4. AUTO-INSTALL OR UPGRADE ---
if [ ! -f "/var/www/html/config/config.php" ] || ! grep -q "'installed' => true" /var/www/html/config/config.php; then
    echo "Waiting for database to be ready (15 seconds)..."
    sleep 15
    echo "Running automated Nextcloud installation..."
    
    # Set default database to mysql
    DB_TYPE=${DB_TYPE:-mysql}

    echo "[ INFO ] Start installing Nextcloud with database: $DB_TYPE"

    # TURN OFF AUTO-EXIT 
    set +e
    INSTALL_SUCCESS=0

    if [ "$DB_TYPE" = "pgsql" ]; then
        echo "Connecting to PostgreSQL at ${DB_HOST}..."
        su-exec www-data php /var/www/html/occ maintenance:install \
            --database="pgsql" \
            --database-host="${DB_HOST}" \
            --database-name="${DB_NAME}" \
            --database-user="${DB_USER}" \
            --database-pass="${DB_PASSWORD}" \
            --admin-user="${ADMIN_USER:-admin}" \
            --admin-pass="${ADMIN_PASSWORD:-admin}" \
            --no-interaction
        INSTALL_SUCCESS=$?

    elif [ "$DB_TYPE" = "sqlite" ]; then
        echo "Using SQLite (Local database)..."
        su-exec www-data php /var/www/html/occ maintenance:install \
            --database="sqlite" \
            --database-name="${DB_NAME:-nextcloud}" \
            --admin-user="${ADMIN_USER:-admin}" \
            --admin-pass="${ADMIN_PASSWORD:-admin}" \
            --no-interaction
        INSTALL_SUCCESS=$?

    else
        echo "Connecting to MySQL/MariaDB on ${DB_HOST}..."
        su-exec www-data php /var/www/html/occ maintenance:install \
            --database="mysql" \
            --database-host="${DB_HOST}" \
            --database-name="${DB_NAME}" \
            --database-user="${DB_USER}" \
            --database-pass="${DB_PASSWORD}" \
            --admin-user="${ADMIN_USER:-admin}" \
            --admin-pass="${ADMIN_PASSWORD:-admin}" \
            --no-interaction
        INSTALL_SUCCESS=$?
    fi

    # HIDUPKAN KEMBALI AUTO-EXIT
    set -e

    # Cek apakah instalasi sukses atau gagal
    if [ $INSTALL_SUCCESS -ne 0 ]; then
        echo "================================================================"
        echo "[ ERROR FATAL ] Nextcloud installation failed!"
        echo "Penyebab: Database mungkin sudah terisi data lama, atau kredensial salah."
        echo "Solusi: Jika ini adalah instalasi baru, HAPUS volume database MariaDB"
        echo "        dan mulai ulang container (docker compose down -v && docker compose up -d)."
        echo "Container akan dibuat tertidur (sleep) untuk mencegah restart-loop..."
        echo "================================================================"
        sleep infinity
    fi

elif [ "$NEED_UPGRADE" = true ]; then
    echo "Waiting for database to be ready before upgrading (15 seconds)..."
    sleep 15
    
    echo "[ INFO ] Forcing disk sync to prevent I/O delay reading..."
    # Memaksa sistem operasi menulis tuntas semua antrean file rsync ke dalam disk fisik
    sync
    sleep 20
    
    echo "[ INFO ] Executing occ upgrade command..."
    su-exec www-data php /var/www/html/occ upgrade --no-interaction
    su-exec www-data php /var/www/html/occ maintenance:mode --off
    echo "[ OK ] Nextcloud upgrade completed successfully!"
fi
# --- 5. APPLICATION CONFIGURATION (Via Database only) ---

# Install ONLYOFFICE Apps
if [ -n "$ONLYOFFICE_HOST" ]; then
    echo "Preparing ONLYOFFICE database configuration..."
    su-exec www-data php /var/www/html/occ app:install onlyoffice || true
    su-exec www-data php /var/www/html/occ config:app:set onlyoffice DocumentServerUrl --value="/ds-vpath/"
    su-exec www-data php /var/www/html/occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://${ONLYOFFICE_HOST}/"
    su-exec www-data php /var/www/html/occ config:app:set onlyoffice StorageUrl --value="http://$NC_HOST/"
    su-exec www-data php /var/www/html/occ config:app:set onlyoffice verify_peer_off --value="true"
    su-exec www-data php /var/www/html/occ config:app:set onlyoffice jwt_secret --value="${JWT_SECRET}"
    
    # CAUTION: Use a unique index number (e.g., 99) to avoid conflicting with the public domain index in your main script.
    su-exec www-data php /var/www/html/occ config:system:set trusted_domains 99 --value="${ONLYOFFICE_HOST}"
fi

# Install NOTIFY_PUSH Apps
if [ -n "$NOTIFY_PUSH_HOST" ]; then
    echo "Preparing Notify Push database configuration..."
    su-exec www-data php /var/www/html/occ app:install notify_push || true
    # Fix: Inject URL directly to app config, NOT running 'setup' test ping mode
    su-exec www-data php /var/www/html/occ config:app:set notify_push base_endpoint --value="https://${DOMAIN_TARGET}/push"
fi

# --- 7. ADDITIONAL FEATURE: FULL-TEXT SEARCH (ELASTICSEARCH) ---
if [ -n "$ELASTICSEARCH_HOST" ]; then
    echo "Preparing Full-Text Search integration (Elasticsearch)..."

    # Install and enable 3 mandatory Nextcloud FTS apps
    su-exec www-data php /var/www/html/occ app:enable fulltextsearch --force || true
    su-exec www-data php /var/www/html/occ app:enable fulltextsearch_elasticsearch --force || true
    su-exec www-data php /var/www/html/occ app:enable files_fulltextsearch --force || true

    # Set Elasticsearch as the primary search platform
    su-exec www-data php /var/www/html/occ config:app:set fulltextsearch search_platform --value="OCA\FullTextSearch_Elasticsearch\Platform\ElasticSearchPlatform"

    # Point Nextcloud to the Elasticsearch container
    su-exec www-data php /var/www/html/occ config:app:set fulltextsearch_elasticsearch elastic_host --value="${ELASTICSEARCH_HOST}"
    su-exec www-data php /var/www/html/occ config:app:set fulltextsearch_elasticsearch elastic_index --value="nextcloud_index"
fi

# --- 8. Redis Configuration (if REDIS_HOST variable exists) ---
if [ -n "$REDIS_HOST" ]; then
    echo "[ INFO ] Configure Redis for Distributed Cache & File Locking..."
    su-exec www-data php /var/www/html/occ config:system:set redis host --value="${REDIS_HOST}"
    su-exec www-data php /var/www/html/occ config:system:set redis password --value="${REDIS_PASSWORD}"
    su-exec www-data php /var/www/html/occ config:system:set redis port --value="6379"
    su-exec www-data php /var/www/html/occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
    su-exec www-data php /var/www/html/occ config:system:set memcache.local --value="\OC\Memcache\APCu"
    su-exec www-data php /var/www/html/occ config:system:set memcache.distributed --value="\OC\Memcache\Redis"
else
    echo "[ INFO ] Redis undetected. Activating APCu for Local Cache..."
    
    # 1. Set APCu as local memory cache
    su-exec www-data php /var/www/html/occ config:system:set memcache.local --value="\OC\Memcache\APCu"
    
    # 2. Clean up Redis on database
    su-exec www-data php /var/www/html/occ config:system:delete memcache.distributed 2>/dev/null || true
    su-exec www-data php /var/www/html/occ config:system:delete memcache.locking 2>/dev/null || true
    su-exec www-data php /var/www/html/occ config:system:delete redis 2>/dev/null || true
fi

# --- 9. DOMAIN SYNCHRONIZATION & OPTIMIZATION (Every Start) ---
PUBLIC_IPV4=$(curl -s -4 icanhazip.com 2>/dev/null)
PUBLIC_IPV6=$(curl -s -6 icanhazip.com 2>/dev/null)
GATEWAY_IPV4=$(ip -4 route show default | awk '{print $3}')
GATEWAY_IPV6=$(ip -6 route show default | awk '{print $3}')
PROXY_INDEX=0
DOMAIN_INDEX=0

echo "[ OK ] IPv4: $PUBLIC_IPV4 GATEWAY: $GATEWAY_IPV4"
echo "[ OK ] IPv6: $PUBLIC_IPV6 GATEWAY: $GATEWAY_IPV6"
echo "Adjusting configuration with environment variables..."

# 1. Clean the :80 suffix from the domain
CLEAN_DOMAIN=$(echo "$NC_DOMAIN" | sed 's/:80//g')

# --- DOMAIN & REVERSE PROXY CONDITION BLOCK ---
if [ "$REVERSE_PROXY" = "yes" ]; then
    echo "[ INFO ] Reverse Proxy Mode Active. Adjusting Overwrite Protocol..."
    
    # Insert clean domain into trusted_domains
    su-exec www-data php /var/www/html/occ config:system:set trusted_domains $DOMAIN_INDEX --value="${CLEAN_DOMAIN}"
    DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
    
    # Logic if using custom forward port (e.g., accessed via https://domain.com:8443)
    if [ -n "$PORT_FORWARD" ]; then
        echo "[ INFO ] Custom Forward Port detected: $PORT_FORWARD"
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="https://${CLEAN_DOMAIN}:${PORT_FORWARD}"
        # Nextcloud needs overwritehost if external port differs from internal proxy port
        su-exec www-data php /var/www/html/occ config:system:set overwritehost --value="${CLEAN_DOMAIN}:${PORT_FORWARD}"
    else
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="https://${CLEAN_DOMAIN}"
        # Delete overwritehost from database if previously existed (to revert to normal)
        su-exec www-data php /var/www/html/occ config:system:delete overwritehost 2>/dev/null || true
    fi
    
    # Force Nextcloud to render links as HTTPS
    su-exec www-data php /var/www/html/occ config:system:set overwriteprotocol --value="https"

elif [ "$NC_DOMAIN" = ":80" ]; then
    echo "[ INFO ] Local IP/HTTP Mode detected."
    
    if [ -n "$PORT_FORWARD" ]; then
        # Jika menggunakan PORT FORWARDING (Misal: 8080)
        su-exec www-data php /var/www/html/occ config:system:set trusted_domains $DOMAIN_INDEX --value="${PUBLIC_IPV4}:${PORT_FORWARD}"
        DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
        
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="http://${PUBLIC_IPV4}:${PORT_FORWARD}"
        # Set overwritehost agar Nextcloud merender internal link dengan port eksternal
        su-exec www-data php /var/www/html/occ config:system:set overwritehost --value="${PUBLIC_IPV4}:${PORT_FORWARD}"
    else
        # Jika menggunakan standard port 80
        su-exec www-data php /var/www/html/occ config:system:set trusted_domains $DOMAIN_INDEX --value="${PUBLIC_IPV4}${NC_DOMAIN}"
        DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
        
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="http://${PUBLIC_IPV4}${NC_DOMAIN}"
        su-exec www-data php /var/www/html/occ config:system:delete overwritehost 2>/dev/null || true
    fi
    
    su-exec www-data php /var/www/html/occ config:system:set overwriteprotocol --value="http"

else
    echo "[ INFO ] Standalone HTTPS Mode."
    
    su-exec www-data php /var/www/html/occ config:system:set trusted_domains $DOMAIN_INDEX --value="${CLEAN_DOMAIN}"
    DOMAIN_INDEX=$((DOMAIN_INDEX + 1))
    
    if [ -n "$PORT_FORWARD" ]; then
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="https://${CLEAN_DOMAIN}:${PORT_FORWARD}"
    else
        su-exec www-data php /var/www/html/occ config:system:set overwrite.cli.url --value="https://${CLEAN_DOMAIN}"
    fi
    
    su-exec www-data php /var/www/html/occ config:system:set overwriteprotocol --value="https"
fi

# Insert Internal Container Host into Trusted Domains
su-exec www-data php /var/www/html/occ config:system:set trusted_domains $DOMAIN_INDEX --value="${NC_HOST}"

# --- TRUSTED PROXIES BLOCK ---
su-exec www-data php /var/www/html/occ config:system:set trusted_proxies $PROXY_INDEX --value="${PUBLIC_IPV4}"
PROXY_INDEX=$((PROXY_INDEX + 1))

if [ -n "$PUBLIC_IPV6" ]; then
    su-exec www-data php /var/www/html/occ config:system:set trusted_proxies $PROXY_INDEX --value="${PUBLIC_IPV6}"
    PROXY_INDEX=$((PROXY_INDEX + 1))
fi

su-exec www-data php /var/www/html/occ config:system:set trusted_proxies $PROXY_INDEX --value="${GATEWAY_IPV4}/12"
PROXY_INDEX=$((PROXY_INDEX + 1))

# use GATEWAY_IPV6 (and ensure variable is not empty)
if [ -n "$GATEWAY_IPV6" ]; then
    su-exec www-data php /var/www/html/occ config:system:set trusted_proxies $PROXY_INDEX --value="${GATEWAY_IPV6}/64"
    # PROXY_INDEX=$((PROXY_INDEX + 1)) # Uncomment if there are other proxies below
fi

# perform mimetype migration
su-exec www-data php /var/www/html/occ maintenance:repair --include-expensive
su-exec www-data php /var/www/html/occ config:system:set maintenance_window_start --value="1"
su-exec www-data php /var/www/html/occ config:system:set default_phone_region --value="${PHONE_REGION}"
su-exec www-data php /var/www/html/occ config:system:set serverid --value="${SERVER_ID}"


# --- 10. FINAL PERMISSIONS & START ---
echo "Fixing file permissions..."
chown -R www-data:www-data /var/www/html
chown -R www-data:www-data /config
chown -R www-data:www-data /data

echo "Starting FrankenPHP as www-data user..."
# FrankenPHP is run via su-exec so the process doesn't run as root
exec su-exec www-data frankenphp run --config /etc/caddy/Caddyfile
