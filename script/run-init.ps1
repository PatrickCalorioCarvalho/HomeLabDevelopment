param(
    [string]$ProxmoxIp = "192.168.18.29"
)

$ErrorActionPreference = "Stop"

$tfvarsPath = Join-Path $PSScriptRoot "..\terraform\terraform.tfvars"

scp ".\init.sh" "root@${ProxmoxIp}:/root/"
if (-not $?) { throw "Falha no scp do init.sh" }

ssh "root@${ProxmoxIp}" "chmod +x /root/init.sh && /root/init.sh" | Tee-Object -Variable capturedLines
$fullOutput = ($capturedLines -join "`n")

if ($fullOutput -notmatch "(?s)##HOMELAB_TFVARS_START##(.*?)##HOMELAB_TFVARS_END##") {
    Write-Warning "Nao encontrei o bloco de variaveis na saida do init.sh - terraform.tfvars NAO foi atualizado."
    exit 1
}

$block = $Matches[1]
$vars = @{}
foreach ($line in ($block -split "`n")) {
    if ($line -match "^\s*([a-zA-Z_]+)=(.*)$") {
        $vars[$Matches[1]] = $Matches[2].Trim()
    }
}

function Set-TfVar {
    param([string]$Path, [string]$Key, [string]$Value)
    $line = "$Key = `"$Value`""
    $pattern = "^\s*$Key\s*="
    $content = if (Test-Path $Path) { @(Get-Content $Path) } else { @() }
    $found = $false
    $newContent = @(foreach ($l in $content) {
        if ($l -match $pattern) { $found = $true; $line } else { $l }
    })
    if (-not $found) { $newContent += $line }
    Set-Content -Path $Path -Value $newContent -Encoding utf8
}

Set-TfVar -Path $tfvarsPath -Key "proxmox_api_url" -Value "https://${ProxmoxIp}:8006/"
Set-TfVar -Path $tfvarsPath -Key "proxmox_node" -Value $vars["proxmox_node"]
Set-TfVar -Path $tfvarsPath -Key "proxmox_api_token_id" -Value $vars["proxmox_api_token_id"]

Write-Host ""
if ($vars.ContainsKey("proxmox_api_token_secret")) {
    Set-TfVar -Path $tfvarsPath -Key "proxmox_api_token_secret" -Value $vars["proxmox_api_token_secret"]
    Write-Host "terraform.tfvars atualizado: proxmox_api_url, proxmox_node, proxmox_api_token_id, proxmox_api_token_secret." -ForegroundColor Green
} else {
    Write-Warning "O token ja existia no Proxmox (secret nao e reexibido). proxmox_api_url/node/token_id foram atualizados, mas proxmox_api_token_secret NAO - confira se o valor atual em terraform.tfvars ainda e valido."
}

function Add-TfVarIfMissing {
    param([string]$Path, [string]$Key, [string]$Placeholder)
    $pattern = "^\s*$Key\s*="
    $content = if (Test-Path $Path) { @(Get-Content $Path) } else { @() }
    if (-not ($content -match $pattern)) {
        Add-Content -Path $Path -Value "$Key = `"$Placeholder`"" -Encoding utf8
    }
}

$manualKeys = @("proxmox_root_password", "vm_ssh_password", "ollama_lxc_password", "postgres_lxc_password", "postgres_password")
foreach ($key in $manualKeys) {
    Add-TfVarIfMissing -Path $tfvarsPath -Key $key -Placeholder "<ALTERAR>"
}

$pending = @(Get-Content $tfvarsPath) | Where-Object { $_ -match '"<ALTERAR>"' }
if ($pending.Count -gt 0) {
    Write-Host ""
    Write-Warning "Falta editar terraform.tfvars - substitua os valores <ALTERAR>:"
    $pending | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
