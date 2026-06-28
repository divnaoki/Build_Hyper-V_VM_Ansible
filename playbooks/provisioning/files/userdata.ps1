<powershell>
# ===========================================================================
# EC2 userdata（Windows Server 2025）
#  1. Ansible公式 ConfigureRemotingForAnsible.ps1 で WinRM を有効化
#  2. Hyper-V 役割をインストール（ネスト仮想化・検証VM用）→ 再起動
# ===========================================================================
$ErrorActionPreference = "Stop"

# --- 1. Ansible WinRM 有効化（公式スクリプト） ---
# 参照: https://github.com/ansible/ansible-documentation/blob/devel/examples/scripts/ConfigureRemotingForAnsible.ps1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url  = "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
$dest = "$env:windir\Temp\ConfigureRemotingForAnsible.ps1"
(New-Object System.Net.WebClient).DownloadFile($url, $dest)
powershell.exe -ExecutionPolicy Bypass -File $dest -ForceNewSSLCert -Verbose

# --- 2. Hyper-V 役割インストール（検証VM 3台分） ---
# Install-WindowsFeature -Name Hyper-V -IncludeManagementTools

# Hyper-V 有効化の反映に再起動が必要（WinRMリスナーは再起動後も永続）
# Restart-Computer -Force
</powershell>
<persist>true</persist>
