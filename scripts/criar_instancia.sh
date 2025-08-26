#!/bin/bash
set -e

MOLDE_DIR="../supabase-mold"
PROJETOS_DIR="/srv/supabase-projects"

if [ -z "$1" ]; then
  echo "ERRO: Forneça um nome para o novo projeto."
  exit 1
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJETOS_DIR/$PROJECT_NAME"

echo "--- INICIANDO CRIAÇÃO DA INSTÂNCIA: $PROJECT_NAME ---"

echo "[PASSO 1/5] Limpando ambiente anterior (se existir)..."
if [ -d "$PROJECT_DIR" ]; then
  cd "$PROJECT_DIR" && docker compose --project-name "$PROJECT_NAME" down -v --remove-orphans > /dev/null 2>&1 || true
  cd "$PROJETOS_DIR"
fi
docker volume rm ${PROJECT_NAME}_db-config ${PROJECT_NAME}_db-data > /dev/null 2>&1 || true
rm -rf "$PROJECT_DIR"

echo "[PASSO 2/5] Criando diretório e copiando arquivos do molde..."
mkdir -p "$PROJECT_DIR"
cp -r "$MOLDE_DIR/." "$PROJECT_DIR/"
cd "$PROJECT_DIR"
cp .env.example .env

echo "[PASSO 3/5] Gerando e configurando segredos e URLs..."
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
DASHBOARD_PASSWORD=$(openssl rand -hex 16)

generate_jwt() {
  local role_payload="$1"
  local secret="$2"
  header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  payload=$(echo -n "$role_payload" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  signature=$(echo -n "$header.$payload" | openssl dgst -sha256 -hmac "$secret" -binary | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  echo "$header.$payload.$signature"
}

ANON_PAYLOAD='{"role":"anon","iss":"supabase","iat":1640995200,"exp":1798684800}'
SERVICE_ROLE_PAYLOAD='{"role":"service_role","iss":"supabase","iat":1640995200,"exp":1798684800}'
ANON_KEY=$(generate_jwt "$ANON_PAYLOAD" "$JWT_SECRET")
SERVICE_ROLE_KEY=$(generate_jwt "$SERVICE_ROLE_PAYLOAD" "$JWT_SECRET")

sed -i "s#POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${POSTGRES_PASSWORD}#" .env
sed -i "s#JWT_SECRET=.*#JWT_SECRET=${JWT_SECRET}#" .env
sed -i "s#DASHBOARD_PASSWORD=.*#DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}#" .env
sed -i "s#ANON_KEY=.*#ANON_KEY=${ANON_KEY}#" .env
sed -i "s#SERVICE_ROLE_KEY=.*#SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}#" .env
sed -i "s#SITE_URL=.*#SITE_URL=http://test.localhost#" .env
sed -i "s#API_EXTERNAL_URL=.*#API_EXTERNAL_URL=http://test.localhost:8000#" .env
sed -i "s#SUPABASE_PUBLIC_URL=.*#SUPABASE_PUBLIC_URL=http://test.localhost#" .env

echo "Configuração do .env concluída."

echo "[PASSO 4/5] Iniciando a instância '$PROJECT_NAME'..."
docker compose --project-name "$PROJECT_NAME" up -d

echo "[PASSO 5/5] Aguardando estabilização dos serviços (até 120 segundos)..."
for i in {1..12}; do
    # CORREÇÃO: Adicionado `tail -n +2` para ignorar a linha de cabeçalho do `docker ps`
    UNHEALTHY_COUNT=$(docker ps -a --filter "name=$PROJECT_NAME" | tail -n +2 | grep -v -E "Up|healthy|running" | wc -l)

    if [ "$UNHEALTHY_COUNT" -eq 0 ]; then
        echo "------------------------------------------------------------"
        echo "VEREDITO: SUCESSO ✅"
        docker ps --filter "name=$PROJECT_NAME"
        echo "------------------------------------------------------------"
        # Opcional: Descomente as linhas abaixo se quiser que o teste se auto-destrua após o sucesso
        # echo "Limpando o ambiente de teste..."
        # docker compose --project-name "$PROJECT_NAME" down -v
        # cd ..
        # rm -rf "$PROJECT_DIR"
        # echo "--- TESTE DE VALIDAÇÃO CONCLUÍDO ---"
        exit 0
    fi
    echo "Ainda há contêineres instáveis. Aguardando 10 segundos..."
    sleep 10
done

echo "------------------------------------------------------------"
echo "VEREDITO: FALHA ❌"
docker ps -a --filter "name=$PROJECT_NAME"
exit 1
