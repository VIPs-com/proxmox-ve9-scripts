# Proxmox VE 9 — Scripts de homelab

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%209.x-orange)](https://www.proxmox.com/)
[![Debian](https://img.shields.io/badge/Debian-13%20Trixie-red)](https://www.debian.org/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Repositório: **[VIPs-com/proxmox-ve9-scripts](https://github.com/VIPs-com/proxmox-ve9-scripts)** (antigo: `proxmox-scripts`, redireciona)

Kit Bash para **diagnosticar**, **configurar após a instalação** e **aplicar firewall** em Proxmox VE 9.x (Debian 13 Trixie). Pensado para **um host standalone**; cluster com **3+ nós** é opcional.

📖 **Manual completo:** [docs/MANUAL.md](docs/MANUAL.md)

---

## O que cada script faz (resumo)

| Script | Função em uma frase |
|--------|---------------------|
| [`utils/pve-diagnostico.sh`](utils/pve-diagnostico.sh) | Relatório de rede, DNS, firewall, discos SMART/ZFS e serviços — **não altera** o sistema. |
| [`scripts/pve-postinstall.sh`](scripts/pve-postinstall.sh) | Repos no-subscription, NTP, upgrade, WebUI sem “nag”, SSH opcional — **não cria cluster**. |
| [`scripts/pve-firewall.sh`](scripts/pve-firewall.sh) | Regras em `host.fw` / `cluster.fw` com backup e validação. |

**Não existe** script que instala Proxmox ou monta cluster sozinho. Unir nós continua na WebUI (Create / Join).

---

## Uso rápido (curl)

Substitua a URL se renomear o repositório no GitHub.

```bash
apt update && apt install -y curl wget iproute2 dnsutils iputils-ping netcat-openbsd smartmontools zfsutils-linux

# 1 — Diagnóstico (recomendado antes)
bash <(curl -s https://raw.githubusercontent.com/VIPs-com/proxmox-ve9-scripts/main/utils/pve-diagnostico.sh)

# 2 — Pós-instalação (standalone, padrão)
bash <(curl -s https://raw.githubusercontent.com/VIPs-com/proxmox-ve9-scripts/main/scripts/pve-postinstall.sh)

# 3 — Firewall (opcional)
bash <(curl -s https://raw.githubusercontent.com/VIPs-com/proxmox-ve9-scripts/main/scripts/pve-firewall.sh)
```

**Cluster futuro (3 máquinas):** veja [docs/MANUAL.md §5](docs/MANUAL.md#5-cluster-opcional-3-nós).

---

## Configuração local

| Arquivo no repositório | Copiar para o host |
|------------------------|-------------------|
| [`etc/pve-postinstall.conf`](etc/pve-postinstall.conf) | `/etc/pve-postinstall.conf` |
| [`etc/pve-postinstall.cluster.conf.example`](etc/pve-postinstall.cluster.conf.example) | base para cluster |
| [`etc/pve-firewall.conf.example`](etc/pve-firewall.conf.example) | `/etc/pve-firewall.conf` |

---

## Atualização 2026

- **Diagnóstico:** útil sempre que a WebUI ou rede falham.
- **Pós-instalação:** evita repetir repos, NTP e upgrade em todo nó novo.
- **Firewall:** documenta portas 8006, 22, 5404–5405, 2224 num lugar só.

O que **não** faz sentido manter era o foco em PVE 8 + Aurora/Luna (2 nós) — isso foi removido na faxina de 2026.

---

## Licença

MIT © VIPs-com
