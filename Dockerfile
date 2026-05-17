# Using Alpine-based FrankenPHP base image (Very light and fast)
FROM dunglas/frankenphp:php8-alpine

LABEL maintainer="icalbakhri" \
      website="log.ical.web.id" \
      org.opencontainers.image.authors="icalbakhri" \
      org.opencontainers.image.source="https://github.com/icalbakhri/nextcloud-frankenphp" \
      org.opencontainers.image.vendor="icalbakhri" \
      org.opencontainers.image.title="Nextcloud-FrankenPHP" \
      org.opencontainers.image.description="Nextcloud run with FrankenPHP"


# Argument for Nextcloud version
ARG NEXTCLOUD_VERSION=30.0.0

# 1. Install Alpine built-in system packages required by Nextcloud
# Includes 'su-exec' to execute FrankenPHP as www-data
RUN apk add --no-cache \
    su-exec \
    bash \
    rsync \
    imagemagick \
    ffmpeg \
    samba-client \
    sudo \
    curl \
    tar \
    bzip2

# 2. Install PHP extensions using FrankenPHP's built-in script
# This list includes all mandatory and optional extensions recommended by Nextcloud
RUN install-php-extensions \
    apcu \
    bcmath \
    bz2 \
    exif \
    gd \
    gmp \
    intl \
    ldap \
    memcached \
    opcache \
    pcntl \
    pdo_mysql \
    pdo_pgsql \
    pdo_sqlite \
    redis \
    sysvmsg \
    sysvsem \
    sysvshm \
    imagick \
    zip

# Add custom PHP configuration for Memory Limit and OPcache
RUN echo "memory_limit=512M" > /usr/local/etc/php/conf.d/nextcloud.ini && \
    echo "opcache.interned_strings_buffer=16" >> /usr/local/etc/php/conf.d/nextcloud.ini && \
    echo "opcache.memory_consumption=128" >> /usr/local/etc/php/conf.d/nextcloud.ini

# 3. Download and extract Nextcloud source dynamically
RUN mkdir -p /usr/src/nextcloud && \
    curl -fsSL -o nextcloud.tar.bz2 https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2 && \
    tar -xjf nextcloud.tar.bz2 -C /usr/src/ && \
    rm nextcloud.tar.bz2

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /var/www/html
ENTRYPOINT ["/entrypoint.sh"]
