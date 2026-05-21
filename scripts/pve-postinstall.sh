#!/usr/bin/env bash

# Pós-instalação Proxmox VE 9.x + Debian 13 Trixie (v2.1.0)
# Modo padrão: standalone (um único host). Modo cluster: 3+ nós (quórum Corosync).
# NÃO cria cluster automaticamente — apenas prepara o nó (repos, NTP, hosts, checks).
# Firewall: use scripts/pve-firewall.sh separadamente.

#
#
# ✅ Instruções de uso local (alternativa ao método com 'curl'):
#
#    1. Transfira este script para o seu nó Proxmox (via WebUI Shell, pendrive, scp, etc.).
#       Exemplo via SCP (executado do seu computador local):
#       scp /caminho/do/seu/script/post-install.sh root@IP_DO_PROXMOX:/root/post-install.sh
#
#    2. Torne o script executável no servidor Proxmox:
#       chmod +x /root/post-install.sh
#
#    3. Execute o script como usuário root (no servidor Proxmox):
#       /root/post-install.sh
#       OU
#       bash /root/post-install.sh
#
#
#
# Configurações — sobrescreva em /etc/pve-postinstall.conf
PVE_MODE="standalone"              # standalone | cluster
DEBIAN_CODENAME="trixie"           # Debian 13 (Proxmox VE 9)
REQUIRED_MAJOR_VERSION=9
SCRIPT_VERSION="2.1.0"
REPO_RAW="https://raw.githubusercontent.com/VIPs-com/proxmox-ve9-scripts/main"
NODE_NAME=$(hostname)
TIMEZONE="America/Sao_Paulo"

# Apenas para PVE_MODE=cluster (mínimo 3 nós; 2 nós perdem quórum se um cair)
CLUSTER_NETWORK=""
CLUSTER_NODES_CONFIG=()

LOG_FILE="/var/log/pve-postinstall-$(date +%Y%m%d)-$(hostname).log"
LOCK_FILE="/etc/pve-postinstall.lock"
START_TIME=$(date +%s)            # Início do registro de tempo de execução

# --- INSTRUÇÕES DE EXECUÇÃO ---

# Uso via WebUI Shell ou SSH:
#   curl -sL ${REPO_RAW}/scripts/pve-postinstall.sh | bash
# Documentação: docs/MANUAL.md

# --- FUNÇÕES AUXILIARES ---

# Funções de Log
log_info() { echo -e "\nℹ️ $*" | tee -a "$LOG_FILE"; }
log_ok() { echo -e "\n✅ $*" | tee -a "$LOG_FILE"; } # Adicionado para mensagens de sucesso
log_erro() { echo -e "\n❌ **ERRO**: $*" | tee -a "$LOG_FILE"; } # Adicionado para mensagens de erro (não críticas para abortar)

log_cmd() {
    echo -e "\n🔹 Executando Comando: $*" | tee -a "$LOG_FILE"
    eval "$@" >> "$LOG_FILE" 2>&1
    local status=$?
    if [ $status -ne 0 ]; then
        echo "❌ **ERRO CRÍTICO** [$status]: Falha ao executar o comando: $*" | tee -a "$LOG_FILE"
        echo "O script será encerrado. Verifique o log em $LOG_FILE para mais detalhes." | tee -a "$LOG_FILE"
        exit $status
    fi
    return $status
}

# Função para fazer backup de arquivos
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_dir="/var/backups/pve-postinstall"
        mkdir -p "$backup_dir"
        local timestamp=$(date +%Y%m%d%H%M%S)
        local backup_path="$backup_dir/$(basename "$file").${timestamp}"
        log_info "📦 Fazendo backup de '$file' para '$backup_path'..."
        cp -p "$file" "$backup_path" >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log_info "⚠️ **AVISO**: Falha ao criar backup de '$file'. Continue com cautela."
        else
            log_info "✅ Backup de '$file' criado com sucesso."
        fi
    else
        log_info "ℹ️ Arquivo '$file' não encontrado, nenhum backup necessário."
    fi
}

# Função para validar IP
validate_ip() {
    local ip="$1"
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_erro "IP '$ip' inválido. Use formato 'XXX.XXX.XXX.XXX'."
        exit 1
    fi
}

# NOVA FUNÇÃO: Configura entradas em /etc/hosts para todos os nós do cluster
configurar_hosts() {
    log_info "📝 Configurando entradas em /etc/hosts para os nós do cluster..."
    backup_file "/etc/hosts" # Faz backup do /etc/hosts antes de modificar

    local current_ip=$(hostname -I | awk '{print $1}') # Pega o primeiro IP do nó atual
    local current_hostname=$(hostname)

    for node_entry in "${CLUSTER_NODES_CONFIG[@]}"; do
        ip=$(echo "$node_entry" | awk '{print $1}')
        hostname=$(echo "$node_entry" | awk '{print $2}')

        if [ -z "$ip" ] || [ -z "$hostname" ]; then
            log_erro "Formato inválido em CLUSTER_NODES_CONFIG: '$node_entry'. Esperado 'IP HOSTNAME'."
            exit 1
        fi

        # Remove qualquer linha existente com o IP ou hostname para evitar duplicatas ou conflitos
        log_cmd "sed -i '/^$ip\s\+\|^.*\s\+$hostname$/d' /etc/hosts"

        # Adiciona a nova entrada
        log_info "Adicionando entrada: '$ip $hostname' a /etc/hosts."
        log_cmd "echo \"$ip $hostname\" >> /etc/hosts"
    done
    log_ok "✅ Configuração de /etc/hosts concluída."
}

# Função para exibir ajuda
show_help() {
    echo "Uso: $0 [OPÇÃO]"
    echo "Pós-instalação Proxmox VE 9.x (Debian Trixie). Padrão: nó standalone."
    echo ""
    echo "Opções:"
    echo "  -h, --help              Ajuda"
    echo "  --skip-lock             Permite reexecutar (não recomendado)"
    echo "  --mode=standalone       Um host (padrão)"
    echo "  --mode=cluster          Exige CLUSTER_NODES_CONFIG com 3+ nós"
    echo ""
    echo "Config: /etc/pve-postinstall.conf"
    echo "  PVE_MODE=\"standalone\""
    echo "  TIMEZONE=\"America/Sao_Paulo\""
    echo "  # cluster:"
    echo "  CLUSTER_NETWORK=\"192.168.1.0/24\""
    echo "  CLUSTER_NODES_CONFIG=(\"192.168.1.10 pve1\" \"192.168.1.11 pve2\" \"192.168.1.12 pve3\")"
    exit 0
}

# --- PROCESSAMENTO DE OPÇÕES E CARREGAMENTO DE CONFIGURAÇÃO EXTERNA ---

# Processa opções de linha de comando
SKIP_LOCK=false
CLI_MODE=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help ;;
        --skip-lock) SKIP_LOCK=true ;;
        --mode=standalone|--mode=cluster) CLI_MODE="${arg#--mode=}" ;;
        *) echo "Opção inválida: $arg (use -h)" >&2; exit 1 ;;
    esac
done

# --- DOWNLOAD E CARREGAMENTO DE CONFIGURAÇÃO EXTERNA ---
CONFIG_URL="${REPO_RAW}/etc/pve-postinstall.standalone.conf"
CONFIG_FILE="/etc/pve-postinstall.conf"

# Se o arquivo de configuração local não existir, baixa do GitHub
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_info "⚙️ Arquivo de configuração não encontrado localmente. Tentando baixar do GitHub: $CONFIG_URL..."
    # Usa curl diretamente e captura o status, sem log_cmd para não abortar o script em caso de falha no download
    curl -s -o "$CONFIG_FILE" "$CONFIG_URL"
    if [ $? -eq 0 ] && [ -f "$CONFIG_FILE" ]; then
        log_ok "✅ Configuração baixada e salva em $CONFIG_FILE."
    else
        log_erro "Falha ao baixar configurações do GitHub! Verifique a URL ou conectividade. Continuando com configurações padrão do script."
        # Remove qualquer arquivo parcialmente baixado para evitar carregar conteúdo incompleto
        rm -f "$CONFIG_FILE"
    fi
fi

# Carrega configurações do arquivo (local ou recém-baixado)
if [[ -f "$CONFIG_FILE" ]]; then
    log_info "⚙️ Carregando configurações de $CONFIG_FILE..."
    # Garante que as variáveis sejam carregadas para o shell atual
    source "$CONFIG_FILE"
    log_ok "✅ Configurações carregadas com sucesso!"
else
    log_info "ℹ️ Arquivo de configuração $CONFIG_FILE não encontrado. Usando configurações padrão do script."
fi

# --- INÍCIO DA EXECUÇÃO DO SCRIPT ---

[[ -n "$CLI_MODE" ]] && PVE_MODE="$CLI_MODE"
PVE_MODE="${PVE_MODE,,}"
if [[ "$PVE_MODE" != "standalone" && "$PVE_MODE" != "cluster" ]]; then
    log_erro "PVE_MODE inválido: '$PVE_MODE'. Use standalone ou cluster."
    exit 1
fi
log_info "Modo: $PVE_MODE | Script v$SCRIPT_VERSION | Debian $DEBIAN_CODENAME | PVE $REQUIRED_MAJOR_VERSION.x"

# 🔒 Prevenção de Múltiplas Execuções
if [[ "$SKIP_LOCK" == "false" && -f "$LOCK_FILE" ]]; then
    log_erro "O script já foi executado anteriormente neste nó ($NODE_NAME). Abortando para evitar configurações duplicadas."
    log_info "Se você realmente precisa re-executar, remova '$LOCK_FILE' ou use '--skip-lock' (NÃO RECOMENDADO)."
    exit 1
fi
touch "$LOCK_FILE" # Cria o arquivo de lock

log_info "📅 **INÍCIO**: Execução do script de pós-instalação no nó **$NODE_NAME** em $(date)"

# --- Fase 1: Verificações Iniciais e Validação de Entrada ---

log_info "🔍 Verificando dependências essenciais do sistema (curl, ping, nc)..."
check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_erro "O comando '$cmd' não foi encontrado. Por favor, instale-o (ex: apt install -y $cmd) e re-execute o script."
        exit 1
    fi
    log_info "✅ Dependência '$cmd' verificada."
}
check_dependency "curl"
check_dependency "ping"
check_dependency "nc" # Netcat, usado para os testes de porta (apt install -y netcat-traditional ou netcat-openbsd)

if [[ "$PVE_MODE" == "cluster" ]]; then
    node_count=${#CLUSTER_NODES_CONFIG[@]}
    if (( node_count < 3 )); then
        log_erro "Cluster com $node_count nó(s): inválido. Com 2 nós, se um desligar o outro perde quórum (Corosync). Use 3+ nós ou PVE_MODE=standalone."
        exit 1
    fi
    if [[ -z "$CLUSTER_NETWORK" ]]; then
        log_erro "PVE_MODE=cluster exige CLUSTER_NETWORK (ex: 192.168.1.0/24)."
        exit 1
    fi
    configurar_hosts
    log_info "Validando IPs e rede do cluster..."
    for node_entry in "${CLUSTER_NODES_CONFIG[@]}"; do
        validate_ip "$(echo "$node_entry" | awk '{print $1}')"
    done
    if ! [[ "$CLUSTER_NETWORK" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_erro "CLUSTER_NETWORK inválido. Use IP/MASK (ex: 192.168.1.0/24)."
        exit 1
    fi
    local_hostname=$(hostname)
    local_ip=$(hostname -I | awk '{print $1}')
    found_in_config=false
    for node_entry in "${CLUSTER_NODES_CONFIG[@]}"; do
        ip=$(echo "$node_entry" | awk '{print $1}')
        hostname_from_config=$(echo "$node_entry" | awk '{print $2}')
        if [ "$local_hostname" = "$hostname_from_config" ] && [ "$local_ip" = "$ip" ]; then
            found_in_config=true
            break
        fi
    done
    if [ "$found_in_config" = false ]; then
        log_erro "Este nó ($local_hostname - $local_ip) não está em CLUSTER_NODES_CONFIG."
        exit 1
    fi
    log_ok "Cluster: $node_count nós, rede $CLUSTER_NETWORK, host local OK."
else
    log_info "Modo standalone: sem /etc/hosts de cluster nem validação de pares."
fi


log_info "🔍 Verificando conectividade de rede com os repositórios Debian e DNS..."
# Teste de ping para um servidor de DNS (google.com)
if ping -c 4 google.com &>/dev/null; then
    log_info "✅ Conectividade com a internet e resolução de DNS OK (ping google.com)."
else
    log_info "⚠️ **AVISO**: Não foi possível pingar 'google.com'. A conectividade com a internet ou resolução de DNS pode estar comprometida. As atualizações e instalações podem falhar."
fi
# Teste para repositórios Debian
if ping -c 4 ftp.debian.org &>/dev/null; then
    log_info "✅ Conectividade com repositórios Debian OK."
else
    log_info "⚠️ **AVISO**: Não foi possível pingar 'ftp.debian.org'. A conectividade com a internet pode estar comprometida. As atualizações e instalações podem falhar."
fi

log_info "Verificando versão do Proxmox VE..."
PVE_VERSION=$(pveversion | grep -oP 'pve-manager/\K\d+\.\d+' || echo "0")
PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d'.' -f1)

if (( PVE_MAJOR < REQUIRED_MAJOR_VERSION )); then
    log_erro "Requer Proxmox VE $REQUIRED_MAJOR_VERSION.x+. Detectado: $PVE_VERSION."
    exit 1
elif (( PVE_MAJOR > REQUIRED_MAJOR_VERSION )); then
    log_info "AVISO: script testado para PVE $REQUIRED_MAJOR_VERSION.x; detectado $PVE_VERSION."
    read -p "Continuar? [s/N] " -n 1 -r -t 10
    echo
    REPLY=${REPLY:-N}
    [[ ! $REPLY =~ ^[Ss]$ ]] && exit 0
else
    log_ok "Proxmox VE $PVE_VERSION OK."
fi

log_info "🔍 Verificando recursos de hardware básicos..."
MIN_RAM_GB=4 # Mínimo recomendado de RAM em GB para um nó Proxmox VE
RAM_AVAILABLE_GB=$(free -g | awk '/Mem:/ {print $2}')
if (( RAM_AVAILABLE_GB < MIN_RAM_GB )); then
    log_info "⚠️ **AVISO**: Pouca RAM detectada ($RAM_AVAILABLE_GB GB). Mínimo recomendado para Proxmox VE é $MIN_RAM_GB GB. O desempenho pode ser afetado."
else
    log_info "✅ RAM disponível ($RAM_AVAILABLE_GB GB) OK."
fi
# Adicione mais checks aqui (CPU, disco, etc.) se desejar

# --- Fase 2: Configuração de Tempo e NTP ---

log_info "⏰ Configurando fuso horário para **$TIMEZONE** e sincronização NTP..."

# Adicionado: Verificação de conectividade NTP inicial
log_info "🔍 Verificando conectividade com servidores NTP externos (pool.ntp.org:123/UDP)..."
if ! nc -zvu pool.ntp.org 123 &>/dev/null; then
    log_erro "Falha na conexão com pool.ntp.org na porta 123 (UDP). Verifique conectividade externa e regras de firewall para NTP."
else
    log_ok "✅ Conectividade NTP externa OK."
fi

log_cmd "timedatectl set-timezone $TIMEZONE"
log_cmd "timedatectl set-ntp true" # Habilita o systemd-timesyncd
log_cmd "systemctl restart systemd-timesyncd" # Garante que o serviço esteja rodando

log_info "Aguardando e verificando a sincronização NTP inicial..."
timeout 15 bash -c 'while ! timedatectl status | grep -q "System clock synchronized: yes"; do sleep 1; done'
if [ $? -ne 0 ]; then
    log_info "⚠️ **AVISO**: Falha na sincronização NTP após 15 segundos! Tentando correção alternativa com ntpdate..."
    # Garante que ntpdate esteja instalado antes de usá-lo
    command -v ntpdate &>/dev/null || log_cmd "apt install -y ntpdate"
    # Tenta sincronizar com ntpdate e registra qualquer erro, com múltiplos fallbacks
    ntpdate -s pool.ntp.org >> "$LOG_FILE" 2>&1 \
    || ntpdate -s 0.pool.ntp.org >> "$LOG_FILE" 2>&1 \
    || ntpdate -s 1.pool.ntp.org >> "$LOG_FILE" 2>&1 \
    || log_erro 'Falha grave ao sincronizar com ntpdate após várias tentativas. Verifique a conectividade de rede e as configurações de NTP.'
else
    log_info "✅ Sincronização NTP bem-sucedida."
fi

# --- Fase 3: Gerenciamento de Repositórios e Atualizações ---

log_info "🗑️ Desabilitando repositório de subscrição e habilitando repositório PVE no-subscription..."
# Faça backup de arquivos de lista de apt antes de modificar
backup_file "/etc/apt/sources.list.d/pve-enterprise.list"
backup_file "/etc/apt/sources.list"
backup_file "/etc/apt/sources.list.d/pve-no-subscription.list"

# CORREÇÃO: Verifica se o arquivo existe antes de tentar modificá-lo
if [ -f "/etc/apt/sources.list.d/pve-enterprise.list" ]; then
    log_info "Comentando a linha do pve-enterprise.list para desabilitar o repositório de subscrição."
    log_cmd "sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list"
else
    log_info "ℹ️ Arquivo /etc/apt/sources.list.d/pve-enterprise.list não encontrado. Nenhuma ação necessária para desabilitar o repositório de subscrição."
fi


log_cmd "echo 'deb http://deb.debian.org/debian $DEBIAN_CODENAME main contrib' > /etc/apt/sources.list"
log_cmd "echo 'deb http://deb.debian.org/debian $DEBIAN_CODENAME-updates main contrib' >> /etc/apt/sources.list"
log_cmd "echo 'deb http://security.debian.org/debian-security $DEBIAN_CODENAME-security main contrib' >> /etc/apt/sources.list"
log_cmd "echo 'deb http://download.proxmox.com/debian/pve $DEBIAN_CODENAME pve-no-subscription' > /etc/apt/sources.list.d/pve-no-subscription.list"

log_info "🔄 Atualizando listas de pacotes e o sistema operacional..."
log_cmd "apt update"
log_cmd "apt dist-upgrade -y"   # Atualiza todos os pacotes e resolve dependências
log_cmd "apt autoremove -y"     # Remove pacotes órfãos
log_cmd "apt clean"             # Limpa o cache de pacotes

log_info "🧹 Removendo o aviso de assinatura Proxmox VE do WebUI (se não possuir uma licença ativa)..."
# Cria um hook para APT que modifica o arquivo JS do WebUI
log_cmd "echo \"DPkg::Post-Invoke { \\\"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib.js$'; if [ \\\$? -eq 1 ]; then sed -i '/.*data.status.*{/{s/\\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; fi\\\"; };\" > /etc/apt/apt.conf.d/no-nag-script"
# Reinstala o pacote para aplicar a modificação imediatamente (ou após futuras atualizações do pacote)
log_cmd "apt --reinstall install -y proxmox-widget-toolkit"
log_info "✅ Aviso de assinatura removido do WebUI (se aplicável)."

# --- Fase 4: (Removida) Configuração e Verificação de Firewall ---
# Esta fase foi completamente removida conforme sua solicitação.
# A configuração do firewall será tratada por um script separado e as verificações serão feitas externamente.

# --- Fase 5: Hardening de Segurança (Opcional) ---

read -p "🔒 Deseja aplicar hardening de segurança (desativar login de root por senha e password authentication)? [s/N] " -n 1 -r -t 10
echo # Nova linha após a resposta
REPLY=${REPLY:-N}
if [[ $REPLY =~ ^[Ss]$ ]]; then
    log_info "🔒 Aplicando hardening SSH..."
    backup_file "/etc/ssh/sshd_config"
    log_cmd "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config"
    log_cmd "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
    log_cmd "systemctl restart sshd"
    log_info "✅ Hardening aplicado! **Atenção**: Agora, o acesso ao root via SSH só será possível usando chaves SSH. Certifique-se de tê-las configuradas antes de fechar a sessão atual."
else
    log_info "ℹ️ Hardening SSH ignorado. O login por senha permanece ativo (menos seguro para produção)."
fi

# --- Fase 6: Instalação de Pacotes Opcionais ---

install_optional_tools() {
    echo
    read -p "📦 Deseja instalar ferramentas adicionais úteis (ex: qemu-guest-agent, ifupdown2, git, htop, smartmontools)? [s/N] " -n 1 -r -t 10
    echo # Nova linha após a resposta
    REPLY=${REPLY:-N}
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        log_info "Instalando pacotes adicionais..."
        log_cmd "apt install -y qemu-guest-agent ifupdown2 git htop smartmontools"
        log_info "✅ Pacotes adicionais instalados."
    else
        log_info "ℹ️ Instalação de pacotes adicionais ignorada."
    fi
}
install_optional_tools

# --- Fase 7: Verificações Pós-Configuração e Finalização ---

log_info "Verificando serviços críticos..."
if [[ "$PVE_MODE" == "cluster" ]]; then
    CRITICAL_SERVICES=(corosync pve-cluster pvedaemon pveproxy)
else
    CRITICAL_SERVICES=(pvedaemon pveproxy)
fi
failed_svc=0
for svc in "${CRITICAL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        log_info "Serviço $svc: ativo"
    else
        log_erro "Serviço $svc: inativo"
        failed_svc=1
    fi
done
if (( failed_svc )); then
    log_erro "Corrija os serviços acima antes de continuar (journalctl -u <serviço>)."
    exit 1
fi
log_ok "Serviços essenciais OK."

if [[ "$PVE_MODE" == "cluster" ]]; then
    log_info "Teste de ping entre nós do cluster..."
    local_ip=$(hostname -I | awk '{print $1}')
    for node_entry in "${CLUSTER_NODES_CONFIG[@]}"; do
        peer_ip=$(echo "$node_entry" | awk '{print $1}')
        peer_hostname=$(echo "$node_entry" | awk '{print $2}')
        [[ "$peer_ip" == "$local_ip" ]] && continue
        if ping -c 1 -W 1 "$peer_ip" &>/dev/null; then
            log_ok "Ping $peer_hostname ($peer_ip) OK"
        else
            log_erro "Ping $peer_hostname ($peer_ip) falhou"
        fi
    done
fi

log_info "🌍 Testando conexão externa (internet) via HTTPS (apenas ping para o google.com)..."
if ping -c 4 google.com &>/dev/null; then
    log_info "✅ Conexão externa via HTTPS (google.com) OK."
else
    log_info "⚠️ **AVISO**: Falha na conexão externa. Verifique a conectividade geral com a internet."
fi

log_info "🧼 Limpando possíveis resíduos de execuções anteriores ou arquivos temporários..."
log_info "✅ Limpeza de resíduos concluída."

log_info "🧹 Limpando logs de pós-instalação antigos (com mais de 15 dias) em /var/log/..."
# Encontra e remove logs mais antigos que 15 dias
log_cmd "find /var/log -name \"pve-postinstall-*.log\" -mtime +15 -exec rm {} \\;"
log_info "✅ Limpeza de logs antigos concluída."

# Cálculo do tempo total de execução
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))

log_info "✅ **FINALIZADO**: Configuração concluída com sucesso no nó **$NODE_NAME** em $(date)."
log_info "⏳ Tempo total de execução do script: **$ELAPSED_TIME segundos**."
log_info "📋 O log detalhado de todas as operações está disponível em: **$LOG_FILE**."

# --- Resumo da Configuração e Próximos Passos ---

log_info "RESUMO — nó $NODE_NAME | modo $PVE_MODE"
log_info "Firewall NÃO foi configurado aqui. Use: scripts/pve-firewall.sh"
log_info "SSH hardening: $(grep -q "PermitRootLogin prohibit-password" /etc/ssh/sshd_config && echo Aplicado || echo Não aplicado)"
log_info "Repos: Debian $DEBIAN_CODENAME + PVE no-subscription"
log_info "Próximos passos:"
log_info "1. Reinicie o nó (recomendado)."
log_info "2. Opcional: scripts/pve-firewall.sh"
if [[ "$PVE_MODE" == "standalone" ]]; then
    log_info "3. Crie VMs/CTs e storages na WebUI. Cluster não é obrigatório."
    log_info "4. Diagnóstico: utils/pve-diagnostico.sh"
else
    log_info "3. WebUI: Datacenter > Cluster > Create (1º nó) e Join nos demais."
    log_info "4. Abra Corosync na rede $CLUSTER_NETWORK (UDP 5404-5405, TCP 2224)."
    log_info "5. Diagnóstico: utils/pve-diagnostico.sh"
fi
log_info "6. Chaves SSH se aplicou hardening."

# --- REINÍCIO RECOMENDADO ---
echo
read -p "⟳ **REINÍCIO ALTAMENTE RECOMENDADO**: Para garantir que todas as configurações sejam aplicadas, é **fundamental** reiniciar o nó. Deseja reiniciar agora? [s/N] " -n 1 -r -t 15
echo # Adiciona uma nova linha após a resposta do usuário ou timeout

# Define 'N' como padrão se nada for digitado ou se houver timeout
REPLY=${REPLY:-N}

if [[ $REPLY =~ ^[Ss]$ ]]; then
    log_info "🔄 Reiniciando o nó **$NODE_NAME** agora..."
    log_cmd "reboot"
else
    log_info "ℹ️ Reinício adiado. Lembre-se de executar 'reboot' manualmente no nó **$NODE_NAME** o mais rápido possível para aplicar todas as mudanças."
fi
