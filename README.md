# Automação de Implantação Multi-Inquilino do Supabase

Este repositório contém um conjunto de scripts e configurações para automatizar a implantação de múltiplas instâncias isoladas do Supabase, geridas por um Nginx Reverse Proxy central.

## Arquitetura

A arquitetura utiliza um Nginx Reverse Proxy como ponto de entrada para todo o tráfego, encaminhando os pedidos para a instância Supabase correta com base no subdomínio. Cada instância opera na sua própria rede Docker, garantindo o isolamento de rede, configuração e dados.

## Configuração Inicial (Execução Única)

1.  **Clone o Repositório**:
    ```bash
    git clone [https://github.com/seu-usuario/seu-repositorio.git](https://github.com/seu-usuario/seu-repositorio.git)
    cd supabase-multi-tenant
    ```

2.  **Crie a Rede Compartilhada**:
    ```bash
    docker network create nginx-proxy-net
    ```

3.  **Inicie o Nginx Reverse Proxy**:
    ```bash
    cd nginx-proxy/
    docker compose up -d
    ```

## Fluxo de Trabalho de Implantação

### 1. Criar a Instância Supabase

Execute o script `criar_instancia.sh` com o nome do projeto.

```bash
cd scripts/
./criar_instancia.sh [nome_do_projeto]
```

### 2. Publicar a Instância
Após configurar os seus registros de DNS para apontarem para o IP do seu servidor, execute o script 

publicar_instancia.sh.

Bash

cd scripts/
# Certifique-se de que a variável EMAIL_CERTBOT no script está correta
./publicar_instancia.sh [nome_do_projeto] [dominio_base]
