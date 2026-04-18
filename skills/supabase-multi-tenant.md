# Supabase Multi-Tenant Setup Skill

Configure isolated Supabase tenants for multi-project architecture on a single server.

## Context

When multiple projects need Supabase/PostgreSQL on the same server, each project gets an isolated tenant (schema) with:
- Separate tables per tenant
- Row Level Security (RLS) for data isolation
- Custom port exposure (5435+) to avoid conflicts with native PostgreSQL

## Prerequisites

- Server with Docker and Supabase containers running
- SSH access to both servers (source and target)
- Docker container name for the database (e.g., `docker-db-1`)

## Steps

### Phase 1: Create Tenant Schema

Create isolated schema for the project:

```python
# create_tenant.py
import paramiko

TENANT_ID = 'project_name'  # Use snake_case
TARGET_SERVER = 'TARGET_IP'  # Server hosting Supabase
DB_CONTAINER = 'docker-db-1'
DB_NAME = 'database_name'  # Usually postgres or your database name

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(TARGET_SERVER, username='root', password='PASSWORD', timeout=10)

# 1. Create schema
cmd = f'docker exec {DB_CONTAINER} psql -U postgres -d {DB_NAME} -c "CREATE SCHEMA IF NOT EXISTS {TENANT_ID};"'
client.exec_command(cmd)

# 2. Create tables (example: users, agents, sessions)
cmds = [
    f"""CREATE TABLE IF NOT EXISTS {TENANT_ID}.users (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        email TEXT UNIQUE NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now()
    );""",
    f"GRANT ALL ON {TENANT_ID}.users TO supabase_auth_admin, anon;",
    f"ALTER TABLE {TENANT_ID}.users ENABLE ROW LEVEL SECURITY;",
    f"""CREATE POLICY tenant_isolation ON {TENANT_ID}.users
        FOR ALL TO anon USING (true) WITH CHECK (true);""",
]
# Execute each command...

client.close()
```

### Phase 2: Expose Database on Alternate Port

Native PostgreSQL on port 5432 conflicts with Docker PostgreSQL. Use port 5435+:

```python
# expose_db_port.py
import paramiko

TARGET_SERVER = 'TARGET_IP'
DB_CONTAINER = 'docker-db-1'
COMPOSE_PATH = '/root/supabase/docker/docker-compose.yml'
NEW_PORT = '5435'  # Example: maps 5435:5432

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(TARGET_SERVER, username='root', password='PASSWORD', timeout=10)

# Add port mapping to docker-compose.yml db service section
# Find the command line in docker-compose.yml and add ports after it
cmd = f'''sed -i '/command: \\[ "postgres", "-c", "config_file=\\/etc\\/postgresql\\/postgresql.conf", "-c", "log_min_messages=fatal" \\]/a\\    ports:\\n      - "{NEW_PORT}:5432"' {COMPOSE_PATH}'''
stdin, stdout, stderr = client.exec_command(cmd)

# Restart container to apply changes
cmd2 = f'cd /root/supabase/docker && docker-compose up -d db'
client.exec_command(cmd2)

client.close()
```

### Phase 3: Configure pg_hba.conf for Remote Access

Allow connections from the client server:

```python
# configure_pg_hba.py
import paramiko

TARGET_SERVER = 'TARGET_IP'
DB_CONTAINER = 'docker-db-1'
CLIENT_IP = 'CLIENT_SERVER_IP'  # Server that will connect

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(TARGET_SERVER, username='root', password='PASSWORD', timeout=10)

# Add trust rule for client IP (add BEFORE scram-sha-256 rules)
new_hba_rules = f'''
# Trust for remote client
host all all {CLIENT_IP}/32 trust
'''

# Read current pg_hba.conf, insert trust rule before catch-all
cmd = 'docker exec docker-db-1 cat /etc/postgresql/pg_hba.conf'
stdin, stdout, stderr = client.exec_command(cmd)
current_hba = stdout.read().decode()

# Insert trust rule before the catch-all scram-sha-256 line
new_hba = current_hba.replace(
    'host  all  all  0.0.0.0/0     scram-sha-256',
    f'host all all {CLIENT_IP}/32 trust\nhost  all  all  0.0.0.0/0     scram-sha-256'
)

# Write new pg_hba.conf
cmd2 = f'docker exec -i docker-db-1 sh -c \'cat > /etc/postgresql/pg_hba.conf << "EOFHBA"\n{new_hba}EOFHBA\''
client.exec_command(cmd2)

# Reload PostgreSQL config
cmd3 = 'docker exec docker-db-1 psql -U postgres -c "SELECT pg_reload_conf();"'
client.exec_command(cmd3)

client.close()
```

### Phase 4: Verify Connectivity

Test connection from client server to target:

```bash
# On CLIENT server
psql -h TARGET_IP -p 5435 -U postgres -d postgres -c 'SELECT 1;'
```

### Phase 5: Configure Client Application

Configure the application (e.g., gbrain) to use the remote database:

```bash
export DATABASE_URL="postgresql://postgres:PASSWORD@TARGET_IP:5435/database_name"
export OPENAI_API_KEY="your-openai-key"

# For gbrain:
gbrain init --non-interactive --url $DATABASE_URL
gbrain doctor
```

## Connection Details

| Component | Value |
|-----------|-------|
| Target Server | TARGET_IP |
| Database Port | 5435 (exposed Docker PostgreSQL) |
| Database User | postgres |
| Database Name | postgres or your_database_name |
| Schema | TENANT_ID |

## Troubleshooting

### Connection refused
- Verify Docker container is running: `docker ps | grep db`
- Check port is listening: `ss -tnlp | grep 5435`
- Verify pg_hba.conf was updated: `docker exec docker-db-1 cat /etc/postgresql/pg_hba.conf`

### Authentication failed
- Ensure pg_hba.conf has trust rule for client IP
- Verify rule is BEFORE scram-sha-256 catch-all
- Reload config: `SELECT pg_reload_conf();`

### Port conflict
- Use port 5435+ for Docker PostgreSQL
- Native PostgreSQL typically uses 5432

## Security Notes

- Trust authentication is for internal network connections only
- For production, use scram-sha-256 with proper passwords
- Keep credentials in environment variables, not in scripts
- Consider using SSH tunnels for encrypted connections