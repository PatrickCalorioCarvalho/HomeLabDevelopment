#!/usr/bin/env bash
# Chamado pelos terraform_data.* (terraform/main.tf) via:
#   wsl bash run.sh <playbook> <ip> <usuario> <senha-ou-caminho-da-chave> [chave=valor ...]
#
# O 4º argumento pode ser uma senha OU o caminho de uma chave privada SSH -
# detecta sozinho (se existe como arquivo, usa chave; senão, senha). Precisa
# disso porque a vm-ia aceita senha, mas os LXCs (template padrão do Proxmox)
# têm "PermitRootLogin prohibit-password" no sshd - só chave funciona.
#
# Existe pra evitar aninhar aspas entre cmd.exe -> wsl.exe -> bash -c, que é
# frágil e quebra fácil. Por isso cada "chave=valor" extra é um argumento
# separado (sem espaço dentro de cada um), sem precisar de aspas em lugar
# nenhum da cadeia Windows -> WSL -> bash.
set -euo pipefail
cd "$(dirname "$0")"

playbook="$1"; shift
vm_ip="$1"; shift
vm_user="$1"; shift
auth="$1"; shift

if [ -f "${auth}" ]; then
    # /mnt/c/... (DrvFs) não guarda permissões Unix de verdade - chmod 600 no
    # Terraform não pega, e o ssh recusa a chave ("bad permissions"). Copia
    # pro filesystem nativo da WSL (/tmp), onde chmod funciona de verdade.
    # Nome inclui o IP porque terraform_data de recursos diferentes (ex:
    # ollama_stack e postgres_stack) rodam em paralelo e usam a MESMA chave -
    # sem isso, os dois brigam pelo mesmo arquivo em /tmp ao mesmo tempo.
    key_copy="/tmp/$(basename "${auth}")-${vm_ip}"
    rm -f "${key_copy}"
    cp "${auth}" "${key_copy}"
    chmod 600 "${key_copy}"
    auth_args=(--private-key "${key_copy}")
else
    auth_args=(-e "ansible_password=${auth}")
fi

extra_args=()
for kv in "$@"; do
    extra_args+=(-e "${kv}")
done

ansible-galaxy collection install -r requirements.yml

ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "${vm_ip}," \
  -u "${vm_user}" \
  "${auth_args[@]}" \
  "${extra_args[@]}" \
  "${playbook}"
