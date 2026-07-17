terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true
}

# Só usado pro lxc-ollama: "device_passthrough" (repassar a GPU pro container)
# só pode ser configurado por root@pam - não existe "mapping" pra isso como
# tem pra PCI de VM. Escopo mínimo: só esse um recurso usa esse provider.
provider "proxmox" {
  alias     = "root"
  endpoint  = var.proxmox_api_url
  username  = "root@pam"
  password  = var.proxmox_root_password
  insecure  = true
}

locals {
  # terraform apply roda no PowerShell (Windows), mas o ansible-playbook só
  # existe na WSL - convertemos o path do módulo (C:/Users/...) pro formato
  # que a WSL enxerga (/mnt/c/Users/...) pra poder chamar "wsl bash run.sh".
  ansible_dir_win = replace(abspath("${path.module}/../ansible"), "\\", "/")
  ansible_dir_wsl = "/mnt/${lower(substr(local.ansible_dir_win, 0, 1))}${substr(local.ansible_dir_win, 2, length(local.ansible_dir_win) - 2)}"

  # Mesma conversão, pra chave SSH usada pelo Ansible nos LXCs.
  lxc_ssh_key_win = replace(abspath(local_sensitive_file.lxc_ssh_private_key.filename), "\\", "/")
  lxc_ssh_key_wsl = "/mnt/${lower(substr(local.lxc_ssh_key_win, 0, 1))}${substr(local.lxc_ssh_key_win, 2, length(local.lxc_ssh_key_win) - 2)}"

  # Devices repassados pro lxc-ollama (device passthrough, não PCI passthrough
  # - o driver NVIDIA fica instalado no host, o container só recebe os nodes).
  gpu_devices = ["/dev/nvidia0", "/dev/nvidiactl", "/dev/nvidia-uvm", "/dev/nvidia-uvm-tools"]
}

# Chave gerada pra SSH nos LXCs - o template padrão do Proxmox tem
# "PermitRootLogin prohibit-password" no sshd (bloqueia senha, permite chave),
# então autenticar como root por senha (como fizemos na vm-docker) não funciona
# aqui.
resource "tls_private_key" "lxc_ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "lxc_ssh_private_key" {
  content         = tls_private_key.lxc_ssh.private_key_openssh
  filename        = "${path.module}/.ssh/lxc_ed25519"
  file_permission = "0600"
}

#############################################
# vm-docker: VM de Docker pros seus projetos + Portainer
#############################################

resource "proxmox_virtual_environment_vm" "vm_docker" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  timeout_clone  = 2400
  timeout_create = 2400

  clone {
    vm_id = 9000 # ID do template gerado pelo script de bootstrap
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.vm_storage_pool
    interface    = "scsi0"
    size         = tonumber(replace(var.disk_size, "G", ""))
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.vm_storage_pool

    user_account {
      username = var.vm_ssh_username
      password = var.vm_ssh_password
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }
}

locals {
  vm_docker_ipv4_all = [
    for ip in flatten(proxmox_virtual_environment_vm.vm_docker.ipv4_addresses) : ip
    if ip != "127.0.0.1"
  ]
  vm_docker_ip = try(local.vm_docker_ipv4_all[0], "")
}

# Instala Docker + Portainer + Open WebUI na vm-docker (Open WebUI aponta pro
# Ollama rodando no lxc-ollama, pela rede). Reaplicar isso não recria a VM, só
# reroda o playbook (idempotente via community.docker).
resource "terraform_data" "vm_docker_stack" {
  triggers_replace = [
    proxmox_virtual_environment_vm.vm_docker.id,
    filemd5("${path.module}/../ansible/vm-docker.yml"),
  ]

  provisioner "local-exec" {
    command = "wsl bash ${local.ansible_dir_wsl}/run.sh vm-docker.yml ${local.vm_docker_ip} ${var.vm_ssh_username} ${var.vm_ssh_password} ollama_url=http://${local.ollama_ip}:11434"
  }

  depends_on = [proxmox_virtual_environment_vm.vm_docker, proxmox_virtual_environment_container.ollama]
}

output "vm_ipv4" {
  value = proxmox_virtual_environment_vm.vm_docker.ipv4_addresses
}

#############################################
# Template LXC (Ubuntu) usado pelo lxc-ollama e lxc-postgres
#############################################

resource "proxmox_download_file" "ubuntu_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = var.lxc_template_url
}

#############################################
# lxc-ollama: Ollama nativo (sem Docker), com acesso à GPU via device passthrough
#############################################

resource "proxmox_virtual_environment_container" "ollama" {
  provider = proxmox.root # device_passthrough exige root@pam

  node_name = var.proxmox_node
  vm_id     = var.ollama_lxc_id

  # privilegiado simplifica bastante o acesso aos /dev/nvidia* (evita ter que
  # mapear uid/gid do driver pro namespace de um container não-privilegiado)
  unprivileged = false

  # Containers privilegiados usam por padrão um profile AppArmor sem suporte
  # a cgroup namespace (cgns) - sem isso o systemd 255 (systemd-networkd
  # incluso) falha silenciosamente e a rede nunca sobe. nesting=1 ativa a
  # variante do profile com cgns. Containers não-privilegiados (lxc-postgres)
  # já ganham isso por padrão, por isso não precisam disso.
  features {
    nesting = true
  }

  initialization {
    hostname = "lxc-ollama"

    user_account {
      password = var.ollama_lxc_password
      keys     = [trimspace(tls_private_key.lxc_ssh.public_key_openssh)]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  disk {
    datastore_id = var.vm_storage_pool
    size         = var.ollama_lxc_disk_size
  }

  cpu {
    cores = var.ollama_lxc_cores
  }

  memory {
    dedicated = var.ollama_lxc_memory
  }

  # Só existe se enable_gpu = true, e só passa a função de vídeo (não precisa
  # da GPU pra CUDA/compute, só o driver + esses devices).
  dynamic "device_passthrough" {
    for_each = var.enable_gpu ? local.gpu_devices : []
    content {
      path = device_passthrough.value
    }
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_lxc_template.id
    type             = "ubuntu"
  }
}

locals {
  ollama_ip = try(values(proxmox_virtual_environment_container.ollama.ipv4)[0], "")
}

resource "terraform_data" "ollama_stack" {
  triggers_replace = [
    proxmox_virtual_environment_container.ollama.id,
    filemd5("${path.module}/../ansible/lxc-ollama.yml"),
  ]

  provisioner "local-exec" {
    command = "wsl bash ${local.ansible_dir_wsl}/run.sh lxc-ollama.yml ${local.ollama_ip} root ${local.lxc_ssh_key_wsl} enable_gpu_passthrough=${var.enable_gpu} nvidia_driver_version=${var.nvidia_driver_version}"
  }

  depends_on = [proxmox_virtual_environment_container.ollama]
}

output "ollama_ipv4" {
  value = proxmox_virtual_environment_container.ollama.ipv4
}

#############################################
# lxc-postgres: PostgreSQL, sem GPU
#############################################

resource "proxmox_virtual_environment_container" "postgres" {
  node_name = var.proxmox_node
  vm_id     = var.postgres_lxc_id

  unprivileged = true

  initialization {
    hostname = "lxc-postgres"

    user_account {
      password = var.postgres_lxc_password
      keys     = [trimspace(tls_private_key.lxc_ssh.public_key_openssh)]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  disk {
    datastore_id = var.vm_storage_pool
    size         = var.postgres_lxc_disk_size
  }

  cpu {
    cores = var.postgres_lxc_cores
  }

  memory {
    dedicated = var.postgres_lxc_memory
  }

  operating_system {
    template_file_id = proxmox_download_file.ubuntu_lxc_template.id
    type             = "ubuntu"
  }
}

locals {
  postgres_ip = try(values(proxmox_virtual_environment_container.postgres.ipv4)[0], "")
}

resource "terraform_data" "postgres_stack" {
  triggers_replace = [
    proxmox_virtual_environment_container.postgres.id,
    filemd5("${path.module}/../ansible/lxc-postgres.yml"),
  ]

  provisioner "local-exec" {
    command = "wsl bash ${local.ansible_dir_wsl}/run.sh lxc-postgres.yml ${local.postgres_ip} root ${local.lxc_ssh_key_wsl} postgres_db_name=${var.postgres_db_name} postgres_user=${var.postgres_user} postgres_password=${var.postgres_password}"
  }

  depends_on = [proxmox_virtual_environment_container.postgres]
}

output "postgres_ipv4" {
  value = proxmox_virtual_environment_container.postgres.ipv4
}
