#!/bin/bash
set -e

# Eliminar un posible server.pid residual
mkdir -p tmp/pids
rm -f tmp/pids/server.pid

# Asegurar permisos de docker.sock si está montado
if [ -S /var/run/docker.sock ]; then
  chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

# Configurar Bundler para no exigir grupos innecesarios
export BUNDLE_WITHOUT="development:test"

if [ -z "$DATABASE_URL" ]; then
  echo "DATABASE_URL is not set. Skipping database connection wait."
else
  echo "Waiting for database connection..."
  MAX_RETRIES=30
  RETRY_COUNT=0

  check_db() {
    bundle exec ruby -r "./config/environment" -e '
      begin
        ActiveRecord::Base.connection_pool.with_connection do |conn|
          conn.execute("SELECT 1")
        end
        exit 0
      rescue => e
        warn "DB Connection Error: #{e.class}: #{e.message}"
        exit 1
      end
    '
  }

  while ! check_db; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
      echo "WARNING: Could not connect to database after $MAX_RETRIES attempts. Continuing startup..."
      break
    fi
    echo "Database not ready yet (attempt $RETRY_COUNT/$MAX_RETRIES), retrying in 2s..."
    sleep 2
  done

  if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    echo "Database connection established!"
    echo "Running database migrations..."
    bundle exec rake db:migrate || echo "Warning: db:migrate encountered an issue, proceeding anyway."
  fi
fi

# Ejecutar el comando principal (Puma / Sidekiq / etc.)
exec "$@"
