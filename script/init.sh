#!/bin/bash

set -e

#############################################
# CONFIGURAÇÃO
#############################################

TF_USER="terraform"
TF_TOKEN_NAME="HomeLabDevelopment"
NODE=$(hostname)
TEMPLATE_ID=9000
TEMPLATE_NAME="ubuntu-2404-template"
STORAGE="local-lvm"
IMAGE_NAME="noble-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/${IMAGE_NAME}"
IMAGE_PATH="/var/lib/vz/template/iso/${IMAGE_NAME}"
DISK_SIZE="20G"

# Ubuntu Cloud Init
CLOUD_USER="ubuntu"
CLOUD_PASSWORD="Ubuntu@123"

# Driver NVIDIA no host (pra LXC com GPU acessar via device passthrough,
# sem precisar de VFIO/PCI passthrough numa VM inteira)
ENABLE_GPU_HOST_DRIVER=true   # false pra pular essa parte

# Instalação nova do Proxmox dispara um apt-get update/upgrade em background
# (pve-daily-update) logo depois do boot, que segura o lock do dpkg por um
# tempo - sem isso, o apt-get daqui do script falha com "Could not get lock".
wait_for_apt_lock() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [ "${waited}" -eq 0 ]; then
            echo "Aguardando outro processo (apt/dpkg) liberar o lock..."
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

#############################################
# CHECK ROOT
#############################################

if [ "$EUID" -ne 0 ]; then
    echo "Execute como root"
    exit 1
fi

echo "================================"
echo " HomeLab Proxmox Bootstrap"
echo " Node: ${NODE}"
echo "================================"

REBOOT_REQUIRED=false

#############################################
# REPOSITORIOS APT (instalação nova vem com os enterprise
# habilitados - exigem assinatura paga, dão 401 sem ela)
#############################################

echo "[0/10] Ajustando repositórios APT"

for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources \
         /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    if [ -f "${f}" ]; then
        echo "Desabilitando ${f}"
        mv "${f}" "${f}.disabled"
    fi
done

PVE_NOSUB="/etc/apt/sources.list.d/pve-no-subscription.sources"
if [ ! -f "${PVE_NOSUB}" ]; then
    echo "Habilitando o repositório pve-no-subscription"
    cat > "${PVE_NOSUB}" << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

#############################################
# DEPENDENCIAS
#############################################

echo "[1/10] Instalando dependencias"
wait_for_apt_lock
apt-get update
apt-get install -y wget curl jq whois htop

#############################################
# DRIVER NVIDIA NO HOST
#############################################

if [ "${ENABLE_GPU_HOST_DRIVER}" = "true" ]; then
    echo "[2/10] Instalando driver NVIDIA no host"

    if ! lspci -nn | grep -qi nvidia; then
        echo "AVISO: nenhuma GPU NVIDIA encontrada via lspci. Pulando instalação do driver."
    else
        # O driver "nvidia-driver" do repo do Debian (550.163.01, mesmo via
        # trixie-backports) é velho demais pro kernel do PVE9 - não compila
        # (in_irq()/__vm_flags não existem mais nessa API). Por isso instala
        # via .run oficial da NVIDIA, versão bem mais nova. Precisa ser a
        # MESMA versão configurada em nvidia_driver_version no terraform,
        # porque o lxc-ollama instala essa mesma versão (--no-kernel-module)
        # pra bater com o módulo de kernel daqui.
        NVIDIA_DRIVER_VERSION="595.58.03"

        # pve-headers (headers do kernel pve atualmente em uso) + ferramentas
        # de build, necessários pro instalador compilar o módulo de kernel.
        # "pve-headers" é só um meta-pacote transicional - o nome real mudou
        # pra "proxmox-headers-*" no PVE9. Instala o meta (resolve pro kernel
        # em uso) e também os headers específicos do kernel rodando, se existirem.
        wait_for_apt_lock
        apt-get install -y pve-headers "proxmox-headers-$(uname -r)" build-essential dkms || apt-get install -y pve-headers build-essential dkms

        if [ ! -f "/usr/bin/nvidia-smi" ] || ! nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | grep -qx "${NVIDIA_DRIVER_VERSION}"; then
            if lsmod | grep -q '^nouveau'; then
                # O driver open-source nouveau, carregado por padrão, é
                # incompatível com o driver da NVIDIA e trava a instalação -
                # precisa ser desabilitado e o host reiniciado antes de
                # instalar. Deixa isso pronto e reboot marcado; o driver
                # em si só entra numa próxima execução deste script,
                # depois do reboot (o resto do script - token, template -
                # continua normalmente nesta execução).
                echo "AVISO: driver nouveau em uso - desabilitando e marcando reboot necessário."
                cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
                update-initramfs -u -k all
                REBOOT_REQUIRED=true
            else
                RUNFILE="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
                [ -f "/root/${RUNFILE}" ] || wget -O "/root/${RUNFILE}" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/${RUNFILE}"
                chmod +x "/root/${RUNFILE}"
                # Não deixa uma falha aqui (set -e) derrubar o resto do script
                # (token/template não dependem da GPU).
                "/root/${RUNFILE}" --silent --dkms --no-questions || echo "AVISO: instalação do driver NVIDIA falhou - veja /var/log/nvidia-installer.log"
            fi
        fi

        nvidia-smi || true

        if [ -f "/usr/bin/nvidia-smi" ] && nvidia-smi >/dev/null 2>&1; then
            # Os /dev/nvidia* só são criados quando algo aciona o driver (ex:
            # rodar nvidia-smi) - depois de um reboot do host eles não existem
            # ainda quando os LXCs sobem, então o device_passthrough do
            # lxc-ollama falha silenciosamente (container sobe, mas sem GPU).
            # Esse serviço roda nvidia-smi no boot, antes dos guests, garantindo
            # que os device nodes já existam quando o container iniciar.
            cat > /etc/systemd/system/nvidia-device-nodes.service << 'EOF'
[Unit]
Description=Cria os device nodes /dev/nvidia* no boot (antes dos LXCs subirem)
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable nvidia-device-nodes.service
        fi

        # nvtop: monitor de GPU em tempo real, estilo htop (uso, memória,
        # processos usando a placa).
        wait_for_apt_lock
        apt-get install -y nvtop
    fi
else
    echo "[2/10] ENABLE_GPU_HOST_DRIVER=false, pulando driver NVIDIA"
fi

#############################################
# CRIA USUARIO TERRAFORM
#############################################

echo "[3/10] Criando usuário Terraform"
if ! pveum user list | grep -q "${TF_USER}@pve"; then
    pveum user add ${TF_USER}@pve
else
    echo "Usuário já existe"
fi

#############################################
# ROLE TERRAFORM
#############################################

echo "[4/10] Criando Role TerraformAdmin"
if ! pveum role list | grep -q TerraformAdmin; then
pveum role add TerraformAdmin \
-privs "VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.Migrate VM.PowerMgmt VM.Console Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Mapping.Use Sys.Audit Sys.Console Sys.Modify SDN.Use"
else
    # Role já existe (reexecução do script) - garante que os privs mais novos
    # também estejam aplicados.
    pveum role modify TerraformAdmin \
    -privs "VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.Migrate VM.PowerMgmt VM.Console Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Mapping.Use Sys.Audit Sys.Console Sys.Modify SDN.Use"
fi

#############################################
# PERMISSÃO
#############################################

echo "[5/10] Aplicando permissão"
pveum aclmod / -user ${TF_USER}@pve -role TerraformAdmin

#############################################
# API TOKEN
#############################################

echo "[6/10] Criando API Token"
TOKEN_OUTPUT=$(pveum user token add ${TF_USER}@pve ${TF_TOKEN_NAME} --privsep=0 --output-format json 2>/dev/null || true)

#############################################
# HABILITA SNIPPETS/VZTMPL NO STORAGE "local"
#############################################

echo "[7/10] Habilitando content types no storage local"
pvesm set local --content iso,vztmpl,backup,snippets >/dev/null 2>&1 || true

#############################################
# DOWNLOAD UBUNTU CLOUD IMAGE
#############################################

echo "[8/10] Baixando Ubuntu Cloud Image"
mkdir -p /var/lib/vz/template/iso
if [ ! -f "${IMAGE_PATH}" ]; then
    wget -O ${IMAGE_PATH} ${IMAGE_URL}
else
    echo "Imagem já existe"
fi

#############################################
# CLOUD INIT CONFIG
#############################################

echo "[9/10] Criando configuração Cloud-Init"

mkdir -p /var/lib/vz/snippets

cat > /var/lib/vz/snippets/ubuntu-vendor-data.yaml <<EOF

#cloud-config

hostname: ubuntu-template
manage_etc_hosts: true
package_update: true
package_upgrade: true
ssh_pwauth: true

packages:
  - qemu-guest-agent
  - curl
  - wget
  - git
  - vim
  - unzip
  - htop

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

EOF

#############################################
# REMOVE TEMPLATE ANTIGO
#############################################

echo "Preparando Template"
if qm status ${TEMPLATE_ID} >/dev/null 2>&1; then
    echo "Removendo template antigo"
    qm destroy ${TEMPLATE_ID}
fi

#############################################
# CRIA VM TEMPLATE
#############################################

echo "[10/10] Criando VM Ubuntu Template"

qm create ${TEMPLATE_ID} \
--name ${TEMPLATE_NAME} \
--memory 2048 \
--cores 2 \
--cpu host \
--net0 virtio,bridge=vmbr0

echo "Importando disco"

qm importdisk \
${TEMPLATE_ID} \
${IMAGE_PATH} \
${STORAGE}

qm set ${TEMPLATE_ID} \
--scsihw virtio-scsi-single \
--scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0

# Redimensiona o disco (a cloud image vem pequena, ~2-3GB)
qm resize ${TEMPLATE_ID} scsi0 ${DISK_SIZE}

# Cloud Init Disk
qm set ${TEMPLATE_ID} \
--ide2 ${STORAGE}:cloudinit

# Cloud Init "extra" (pacotes/runcmd) via seção 'vendor' - NÃO conflita com ciuser/cipassword
qm set ${TEMPLATE_ID} \
--cicustom "vendor=local:snippets/ubuntu-vendor-data.yaml"

# Usuário e senha Cloud-Init (agora funciona de verdade, pois a seção 'user' não foi sobrescrita)
qm set ${TEMPLATE_ID} \
--ciuser ${CLOUD_USER} \
--cipassword "${CLOUD_PASSWORD}"

# Rede DHCP IPv4
qm set ${TEMPLATE_ID} \
--ipconfig0 ip=dhcp

# QEMU Guest Agent
qm set ${TEMPLATE_ID} \
--agent enabled=1

# DNS
qm set ${TEMPLATE_ID} \
--nameserver "8.8.8.8"

qm set ${TEMPLATE_ID} \
--boot order=scsi0

qm set ${TEMPLATE_ID} \
--serial0 socket \
--vga serial0

#############################################
# CONVERTE TEMPLATE
#############################################

echo "Convertendo para Template"
qm template ${TEMPLATE_ID}

#############################################
# RESULTADO FINAL
#############################################

echo ""
echo "======================================="
echo " HOMELAB PROXMOX READY"
echo "======================================="
echo "Node: ${NODE}"
echo "Template: ${TEMPLATE_ID} - ${TEMPLATE_NAME}"
echo "Ubuntu Cloud User: ${CLOUD_USER}"
echo "Terraform User: ${TF_USER}@pve"

if [ ! -z "$TOKEN_OUTPUT" ]; then
echo ""
echo "================================="
echo " GUARDE ESSE TOKEN (só aparece uma vez)"
echo "================================="
echo "${TOKEN_OUTPUT}" | jq
else
echo ""
echo "AVISO: token ${TF_TOKEN_NAME} já existia - o secret antigo não pode ser"
echo "reexibido pelo Proxmox. Se terraform.tfvars não tiver um secret valido,"
echo "rode: pveum user token remove ${TF_USER}@pve ${TF_TOKEN_NAME}  e execute este script de novo."
fi

echo ""
echo "Terraform URL: https://${NODE}:8006"
echo "================================="

# Bloco lido pelo run-init.ps1 pra atualizar o terraform.tfvars sozinho -
# evita ter que copiar/colar o token e o node manualmente a cada reinstalação.
echo ""
echo "##HOMELAB_TFVARS_START##"
echo "proxmox_node=${NODE}"
echo "proxmox_api_token_id=${TF_USER}@pve!${TF_TOKEN_NAME}"
if [ ! -z "$TOKEN_OUTPUT" ]; then
    echo "proxmox_api_token_secret=$(echo "${TOKEN_OUTPUT}" | jq -r '.value')"
fi
echo "##HOMELAB_TFVARS_END##"
echo " Finalizado com sucesso"
echo "================================="

if [ "${REBOOT_REQUIRED}" = "true" ]; then
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " REBOOT NECESSÁRIO (limpeza de VFIO e/ou driver NVIDIA novo)"
    echo " Rode: reboot"
    echo " Depois, confirme com: nvidia-smi"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
