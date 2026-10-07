# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.3.7

# -------------------------------------------------------------
# Stage 1: Build & Gems (Compilación de dependencias nativas)
# -------------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim AS builder

WORKDIR /app

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    git \
    pkg-config \
    libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./

RUN gem install bundler -v 2.5.22 && \
    bundle install --jobs 4 --retry 3 && \
    rm -rf /usr/local/bundle/cache/*.gem \
    && find /usr/local/bundle/gems/ -name "*.c" -delete \
    && find /usr/local/bundle/gems/ -name "*.o" -delete

# -------------------------------------------------------------
# Stage 2: Imagen Final Ligera para Sinatra + Puma
# -------------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim

ENV DEBIAN_FRONTEND=noninteractive \
    RACK_ENV="production" \
    PORT=4567 \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

WORKDIR /app

# Paquetes de runtime y Docker CLI para gestión de contenedores
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    curl \
    git \
    postgresql-client \
    ca-certificates \
    gnupg \
    lsb-release \
    libpq5 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && apt-get purge -y gnupg lsb-release \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Copiar gemas precompiladas desde builder
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Copiar aplicación completa
COPY . .

# Entrypoint script
COPY entrypoint.sh /usr/bin/entrypoint.sh
RUN chmod +x /usr/bin/entrypoint.sh

EXPOSE 4567

ENTRYPOINT ["/usr/bin/entrypoint.sh"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

