#!/bin/bash
set -e

# --- CONFIGURAÇÃO ---
NGINX_DIR="/srv/supabase-projects/nginx"
EMAIL_CERTBOT="seu-email@dominio.com" # <-- IMPORTANTE: Defina o seu email aqui
TEMPO_LIMITE_DNS=300
INTERVALO_DNS=20
# --- FIM DA CONFIGURAÇÃO ---

# Validação de ferramentas
if ! command -v dig &> /dev/null || ! command -v curl &> /dev/null; then
    echo "A instalar ferramentas necessárias (dnsutils, curl)..."
    apt-get update && apt-get install -y dnsutils curl
fi

# Validação de argumentos
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "ERRO: Forneça o nome do projeto e o domínio."
  echo "Uso: $0 <nome_do_projeto> <dominio.com.br>"
  exit 1
fi

PROJECT_NAME="$1"
DOMAIN="$2"
CONF_FILE="$NGINX_DIR/conf.d/${PROJECT_NAME}.conf"
CERT_DIR="/etc/letsencrypt/live/supabase.$DOMAIN"

echo "--- INICIANDO PUBLICAÇÃO DA INSTÂNCIA: $PROJECT_NAME ---"
echo "Domínios: api.$DOMAIN e supabase.$DOMAIN"

# Verifica se o certificado já existe
if docker compose -f "$NGINX_DIR/docker-compose.yml" exec reverse-proxy test -d "$CERT_DIR"; then
    echo "✅ Aviso: O certificado para supabase.$DOMAIN já existe. Pulando a criação do certificado."
    # Garante que a configuração final HTTPS está no lugar
    GOAL="configure_https"
else
    echo "Aviso: O certificado não foi encontrado. Procedendo com a criação..."
    GOAL="create_cert_and_configure_https"
fi

validar_dns() {
    local dominio_a_verificar=$1
    echo "A validar o apontamento de DNS para '$dominio_a_verificar'..."
    # CORREÇÃO: Adicionado '-4' para forçar o uso de IPv4
    IP_SERVIDOR=$(curl -4 -s ifconfig.me)
    tempo_decorrido=0
    while [ $tempo_decorrido -lt $TEMPO_LIMITE_DNS ]; do
        IP_DOMINIO=$(dig +short "$dominio_a_verificar" @1.1.1.1 || echo "falhou")
        echo "  - IP do Servidor: $IP_SERVIDOR"
        echo "  - IP de '$dominio_a_verificar': $IP_DOMINIO"
        if [ "$IP_SERVIDOR" == "$IP_DOMINIO" ]; then
            echo "  ✅ Sucesso: O DNS para '$dominio_a_verificar' está a apontar corretamente."
            return 0
        fi
        echo "  ⏳ Aviso: DNS ainda não propagado. A aguardar $INTERVALO_DNS segundos..."
        sleep $INTERVALO_DNS
        tempo_decorrido=$((tempo_decorrido + INTERVALO_DNS))
    done
    echo "  ❌ ERRO: Tempo limite de $TEMPO_LIMITE_DNS segundos atingido."
    return 1
}

if [ "$GOAL" == "create_cert_and_configure_https" ]; then
    echo "[PASSO 1/5] Criando configuração inicial do Nginx para o desafio do Certbot..."
    cat <<EOF > "$CONF_FILE"
server {
    listen 80;
    server_name api.$DOMAIN supabase.$DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 404;
    }
}
EOF

    echo "[PASSO 2/5] Reiniciando o Nginx para aplicar a nova rota..."
    cd "$NGINX_DIR"
    docker compose restart
    sleep 5

    echo "[PASSO 3/5] A iniciar a validação do DNS..."
    if ! validar_dns "api.$DOMAIN" || ! validar_dns "supabase.$DOMAIN"; then
        echo "ERRO CRÍTICO: A validação do DNS falhou. A abortar."
        exit 1
    fi

    echo "[PASSO 4/5] Gerando certificado SSL com o Certbot..."
    docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d supabase.$DOMAIN -d api.$DOMAIN --email "$EMAIL_CERTBOT" --agree-tos --no-eff-email --quiet
fi

echo "[PASSO 5/5] Atualizando a configuração do Nginx para HTTPS..."
cat <<EOF > "$CONF_FILE"
# Configuração FINAL (com SSL) para o projeto '$PROJECT_NAME'
server {
    listen 80;
    server_name api.$DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name api.$DOMAIN;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    location / {
        proxy_pass http://${PROJECT_NAME}-kong-1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name supabase.$DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name supabase.$DOMAIN;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    location / {
        proxy_pass http://${PROJECT_NAME}-studio-1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
EOF

echo "Reiniciando o Nginx para aplicar a configuração SSL final..."
cd "$NGINX_DIR"
docker compose restart

echo "------------------------------------------------------------"
echo "VEREDITO: SUCESSO ✅"
echo "Instância '$PROJECT_NAME' publicada e acessível em:"
echo "  - Studio: https://supabase.$DOMAIN"
echo "  - API:    https://api.$DOMAIN"
echo "------------------------------------------------------------"
