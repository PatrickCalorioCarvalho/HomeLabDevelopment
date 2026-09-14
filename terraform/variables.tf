variable "proxmox_api_url" {
  type        = string
  description = "Ex: https://192.168.1.10:8006/  (NÃO inclua /api2/json no final, o provider bpg/proxmox já adiciona isso internamente)"
}

variable "proxmox_api_token_id" {
  type      = string
  sensitive = true
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_root_password" {
  description = "Senha do root@pam no Proxmox (API, não SSH) - usada só pra criar o lxc-ollama, porque device_passthrough exige essa autenticação especificamente."
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vm_storage_pool" {
  type    = string
  default = "local-lvm"
}

# Host tem só 4 cores / 15GB RAM no total - os valores default abaixo em
# vm-docker + lxc-ollama + lxc-postgres somados ficam bem abaixo disso, com folga
# pro próprio Proxmox.

#############################################
# vm-docker: VM de Docker pros seus projetos + Portainer
#############################################

variable "vm_name" {
  type    = string
  default = "vm-docker"
}

variable "vm_id" {
  type    = number
  default = 200
}

variable "cores" {
  description = "Nós sem assinatura Proxmox têm um teto de 4 vCPUs por VM."
  type        = number
  default     = 2
}

variable "memory" {
  description = "8192 (8GB) pra caber o SigNoz (sozinho ja pede uns 4GB de Docker) junto com Portainer/Open WebUI/ByteGasto."
  type        = number
  default     = 8192
}

variable "disk_size" {
  type    = string
  default = "60G"
}

variable "vm_ssh_username" {
  description = "Usuário criado via cloud-init na vm-docker, usado pelo Ansible pra configurar Docker/Portainer."
  type        = string
  default     = "ubuntu"
}

variable "vm_ssh_password" {
  description = "Senha desse usuário na vm-docker (não é senha de root nem do token da API)."
  type        = string
  sensitive   = true
}

#############################################
# LXC template (Ubuntu) usado pelo lxc-ollama e lxc-postgres
#############################################

variable "lxc_template_url" {
  description = "URL do template LXC. Se der 404, roda 'pveam update && pveam available' no host pra achar o nome atual do arquivo."
  type        = string
  default     = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

#############################################
# lxc-ollama: Ollama + Open WebUI, com acesso à GPU via device passthrough
#############################################

variable "enable_gpu" {
  description = "Se true, passa os devices /dev/nvidia* pro lxc-ollama (precisa do driver NVIDIA já instalado no host - ver script/init.sh)."
  type        = bool
  default     = true
}

variable "nvidia_driver_version" {
  description = <<-EOT
    Versão EXATA do driver NVIDIA instalado no host (mesma versão, não só a
    major) - dentro do LXC é instalado o mesmo .run da NVIDIA (--no-kernel-module),
    porque o driver dentro do container precisa bater com o módulo de kernel
    do host, senão dá "Driver/library version mismatch" no nvidia-smi.
    Descobre com: ssh root@<host> "cat /proc/driver/nvidia/version"
  EOT
  type        = string
  default     = "595.58.03"
}

variable "ollama_lxc_id" {
  type    = number
  default = 210
}

variable "ollama_lxc_cores" {
  type    = number
  default = 2
}

variable "ollama_lxc_memory" {
  type    = number
  default = 4096
}

variable "ollama_lxc_disk_size" {
  type    = number
  default = 40
}

variable "ollama_lxc_password" {
  description = "Senha do root no lxc-ollama, usada pelo Ansible."
  type        = string
  sensitive   = true
}

#############################################
# lxc-postgres: PostgreSQL, sem GPU
#############################################

variable "postgres_lxc_id" {
  type    = number
  default = 211
}

variable "postgres_lxc_cores" {
  type    = number
  default = 1
}

variable "postgres_lxc_memory" {
  type    = number
  default = 1024
}

variable "postgres_lxc_disk_size" {
  type    = number
  default = 8
}

variable "postgres_lxc_password" {
  description = "Senha do root no lxc-postgres, usada pelo Ansible."
  type        = string
  sensitive   = true
}

variable "postgres_db_name" {
  type    = string
  default = "app"
}

variable "postgres_user" {
  type    = string
  default = "app"
}

variable "postgres_password" {
  description = "Senha do usuário/banco Postgres criado dentro do lxc-postgres (diferente da senha de root do container)."
  type        = string
  sensitive   = true
}
