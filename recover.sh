#!/bin/bash
set -e

PEER_IP="${PEER_IP:-172.20.0.20}"
REPL_USER="repl_user"
REPL_PASS="repl_password"
POSTGRES_PASS="1234"
DATA_DIR="/bitnami/postgresql/data"
CONF_DIR="/opt/bitnami/postgresql/conf"

echo "[Recuperación] Verificando si el nodo par ($PEER_IP) está activo y es el Master..."

is_peer_master=false
# Check TCP reachability using bash dev tcp
if timeout 3 bash -c "exec 3<>/dev/tcp/$PEER_IP/5432" 2>/dev/null; then
    echo "[Recuperación] El nodo par ($PEER_IP) es alcanzable. Consultando el estado de recuperación..."
    recovery_status=$(PGPASSWORD="$POSTGRES_PASS" psql -h "$PEER_IP" -U postgres -d postgres -tA -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
    echo "[Recuperación] El estado de recuperación del nodo par es: $recovery_status"
    if [ "$recovery_status" = "f" ]; then
        is_peer_master=true
    fi
else
    echo "[Recuperación] El nodo par ($PEER_IP) no es alcanzable en el puerto 5432."
fi

if [ "$is_peer_master" = "true" ]; then
    echo "[Recuperación] El Nodo 1 (Master preferido) está activo. Este Nodo 2 será Réplica."
    
    echo "[Recuperación] Limpiando el directorio de datos antiguo..."
    rm -rf "$DATA_DIR"/*
    
    echo "[Recuperación] Clonando datos desde el Nodo 1 usando pg_basebackup..."
    PGPASSWORD="$REPL_PASS" pg_basebackup -h "$PEER_IP" -U "$REPL_USER" -D "$DATA_DIR" -Fp -Xs -P -R
    
    chmod 700 "$DATA_DIR"
    echo "[Recuperación] pg_basebackup completado con éxito. Configurando el modo de replicación como esclavo (slave)."
    
    # Override Bitnami environment variables to force it to start as slave
    export POSTGRESQL_REPLICATION_MODE="slave"
    export POSTGRESQL_MASTER_HOST="$PEER_IP"
    export POSTGRESQL_MASTER_PORT_NUMBER="5432"
else
    echo "[Recuperación] El Nodo 1 no está activo como Master. El Nodo 2 iniciará como Master."
    export POSTGRESQL_REPLICATION_MODE="master"
fi

# Start PostgreSQL in the background to preserve the container's network namespace (PID 1 remains this script)
echo "[Recuperación] Iniciando PostgreSQL en segundo plano..."
/opt/bitnami/scripts/postgresql/entrypoint.sh /opt/bitnami/scripts/postgresql/run.sh &

# Wait for PostgreSQL to initialize
sleep 5

# Supervisor and demotion loop
demoting=false
while true; do
    # 1. Ensure pg_hba.conf always has the replication entry and is reloaded
    if [ -f "$CONF_DIR/pg_hba.conf" ]; then
        if ! grep -q "host replication $REPL_USER" "$CONF_DIR/pg_hba.conf"; then
            echo "[Recuperación] Agregando/preservando la entrada de replicación en pg_hba.conf..."
            echo "host replication $REPL_USER 0.0.0.0/0 md5" >> "$CONF_DIR/pg_hba.conf"
        fi
        # Always attempt reload config (ignores errors if Postgres is not fully up yet)
        PGPASSWORD="$POSTGRES_PASS" pg_ctl reload -D "$DATA_DIR" >/dev/null 2>&1 || true
    fi
    
    # 2. Check if PostgreSQL has crashed unexpectedly
    if ! pg_ctl status -D "$DATA_DIR" >/dev/null 2>&1; then
        if [ "$demoting" = "false" ]; then
            echo "[Recuperación] ¡PostgreSQL se detuvo de forma inesperada! Cerrando contenedor..."
            exit 1
        fi
    fi
    
    # 3. Check if we are running as master, but Node 1 (172.20.0.20) has started as Master
    if [ "$demoting" = "false" ]; then
        local_status=$(PGPASSWORD="$POSTGRES_PASS" psql -U postgres -d postgres -tA -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
        if [ "$local_status" = "f" ]; then
            # We are Master. Check if Node 1 has returned and is Master
            if timeout 2 bash -c "exec 3<>/dev/tcp/$PEER_IP/5432" 2>/dev/null; then
                peer_status=$(PGPASSWORD="$POSTGRES_PASS" psql -h "$PEER_IP" -U postgres -d postgres -tA -c "SELECT pg_is_in_recovery();" 2>/dev/null || echo "error")
                if [ "$peer_status" = "f" ]; then
                    echo "[Recuperación] ¡El Nodo 1 (Master preferido) ha vuelto! Deteniendo PostgreSQL para reiniciar como Réplica en segundo plano..."
                    demoting=true
                    
                    # Stop PostgreSQL locally
                    pg_ctl stop -D "$DATA_DIR" -m immediate || true
                    
                    # Clean and clone from Node 1
                    rm -rf "$DATA_DIR"/*
                    PGPASSWORD="$REPL_PASS" pg_basebackup -h "$PEER_IP" -U "$REPL_USER" -D "$DATA_DIR" -Fp -Xs -P -R
                    chmod 700 "$DATA_DIR"
                    
                    # Configure replication details for restart
                    export POSTGRESQL_REPLICATION_MODE="slave"
                    export POSTGRESQL_MASTER_HOST="$PEER_IP"
                    export POSTGRESQL_MASTER_PORT_NUMBER="5432"
                    
                    echo "[Recuperación] Reiniciando PostgreSQL en modo Réplica en segundo plano..."
                    /opt/bitnami/scripts/postgresql/entrypoint.sh /opt/bitnami/scripts/postgresql/run.sh &
                    
                    # Wait for it to restart
                    sleep 5
                    demoting=false
                fi
            fi
        fi
    fi
    sleep 5
done
