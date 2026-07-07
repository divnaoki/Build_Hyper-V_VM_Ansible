# Hyper-V 仮想マシン構築 (vm_build)

Hyper-V ホスト上に、テンプレートVHDから仮想マシンを構築・設定するための Ansible ロール群です。
Exastro IT Automation の Ansible Legacy Role での実行を想定していますが、検証用の Playbook で
スタンドアロンにも実行できます。

---

## ディレクトリ構成

```
hyperv-vm-build/
├── README.md
├── playbooks/
│   ├── packages/vm_build/          # 本体（ロール群＋検証用Playbook）
│   │   ├── ansible.cfg
│   │   ├── inventory.ini           # ★git管理外（接続情報。下記参照）
│   │   ├── requirements.yml        # 依存コレクション
│   │   ├── roles/
│   │   │   ├── import_template_vm/
│   │   │   ├── set_vm_cpu/
│   │   │   ├── set_vm_memory/
│   │   │   ├── set_vm_disk/
│   │   │   ├── start_vm/
│   │   │   └── configure_guest_network/
│   │   │       └── group_vars/main.yml  # ★git管理外（検証値。下記参照）
│   │   └── test_*.yml              # 検証用Playbook
│   └── provisioning/               # 検証環境(AWS EC2)の構築・スナップショット運用
│       ├── group_vars/all.yml      # ★git管理外（AWS設定。下記参照）
│       └── *.yml
```

---

## ロール一覧

各ロールは `tasks/main.yml` が `include_tasks` で `<処理名>.yml` を読み込み、変数は `defaults/main.yml`
（実行時は Exastro パラメータシートの複数具体値変数 `VAR_vm` で上書き）という構成です。
`VAR_vm` は「1レコード = 1VM」のリストで、各ロールは `loop: VAR_vm` で全VMを処理します。

| ロール | 説明 | 主な使用モジュール |
|--------|------|--------------------|
| **import_template_vm** | sysprep済みテンプレートのエクスポート(`Virtual Machines`フォルダ)から `Import-VM -Copy -GenerateNewId` でVMを複製作成しリネーム。VMごとに専用フォルダ(`C:\VMs\<VM名>`)へVHD/構成を配置し、複数VM展開時のVHDX名衝突を回避。同名VMが存在する場合はスキップ（冪等）。 | `ansible.windows.win_find` / `win_shell` |
| **set_vm_cpu** | vCPU数を設定する。 | `microsoft.hyperv.hv_processor` |
| **set_vm_memory** | メモリを設定する。`memory_dynamic` により動的メモリ（startup/min/max）／静的メモリ（startupのみ）を切替。 | `microsoft.hyperv.hv_memory` |
| **set_vm_disk** | OSディスクを拡張する。ホスト側で `hv_vhd` によりVHDXを拡張し、ゲスト内で PowerShell Direct によりOSパーティションを最大まで拡張する（Windowsのみ）。 | `microsoft.hyperv.hv_vhd` / `ansible.windows.win_shell` |
| **start_vm** | VMを起動し、`Running` になるまで待機する。 | `microsoft.hyperv.hv_vm_state` |
| **configure_guest_network** | ゲストOSに**複数セグメント**のIPアドレスとホスト名を設定する。セグメント=仮想スイッチ1:1（**VLAN不使用**）で、各セグメントの仮想NICは**テンプレートで追加・スイッチ接続済み**前提。`segments[].switch_name`に一致する接続先スイッチの既存vNICをMACで特定し、ゲスト内でそのNICに各セグメントのIPを設定、ホスト名をVM名に変更する（変更時は再起動）。接続は PowerShell Direct。Windowsのみ。 | `ansible.windows.win_shell`（PowerShell Direct） |

> 実行順序（Conductor相当）: `import_template_vm` → `set_vm_cpu` → `set_vm_memory` →
> （ファームウェア/時刻同期）→ `start_vm` → `set_vm_disk` → `configure_guest_network`
> ※ `set_vm_disk` / `configure_guest_network` のゲスト内設定はVM起動が前提のため、`start_vm` の後に実行します。

---

## 検証用 Playbook の実行方法

### 1. 事前準備

```bash
cd playbooks/packages/vm_build

# 依存コレクションのインストール
ansible-galaxy collection install -r requirements.yml
```

接続情報（`inventory.ini`）と各ロールの検証値（`roles/<role>/group_vars/main.yml`）は
**git管理外**です。下記「git管理から外すファイルと設定内容」を参照して用意してください。

### 2. 実行（推奨順）

```bash
ansible-playbook -i inventory.ini test_import_template_vm.yml   # テンプレからVM作成
ansible-playbook -i inventory.ini test_set_vm_cpu.yml           # vCPU設定
ansible-playbook -i inventory.ini test_set_vm_memory.yml        # メモリ設定
ansible-playbook -i inventory.ini test_start_vm.yml                 # VM起動
ansible-playbook -i inventory.ini test_set_vm_disk.yml             # OSディスク拡張（起動後）
ansible-playbook -i inventory.ini test_configure_guest_network.yml # IP・ホスト名設定（起動後）
```

各 `test_*.yml` は `vars_files` で対応する `roles/<role>/group_vars/main.yml` を読み込みます
（`group_vars` はロール配下に置いても自動ロードされないため、検証Playbook側で明示的に読み込んでいます）。

### 3. 検証環境(AWS EC2)の構築（任意）

Hyper-V 検証ホスト自体を AWS のベアメタルEC2上に構築する Playbook を `playbooks/provisioning/` に用意しています。

```bash
cd playbooks/provisioning
ansible-galaxy collection install -r requirements.yml   # amazon.aws
pip install boto3 botocore

ansible-playbook provision_ec2_hyperv.yml        # EC2(WS2022/ベアメタル)構築＋WinRM有効化
ansible-playbook create_snapshot_ami.yml         # 設定後の状態をAMI(スナップショット)化
ansible-playbook provision_from_snapshot.yml     # スナップショットから復元起動
ansible-playbook terminate_ec2_hyperv.yml        # インスタンス削除（時間課金停止）
ansible-playbook delete_snapshot_ami.yml         # スナップショット削除（保管課金停止）
```

---

## git管理から外すファイルと設定内容

以下のファイルは**認証情報・環境固有値を含むため `.gitignore` で除外**しています。
クローン後、各自で以下の内容を用意してください。

### ① `playbooks/packages/vm_build/inventory.ini`
Hyper-Vホスト（WinRM接続）への接続情報。

```ini
[hyperv_hosts]
hyperv01 ansible_host=<Hyper-VホストのIP>

[hyperv_hosts:vars]
ansible_user=Administrator
ansible_password=<Administratorのパスワード>
ansible_connection=winrm
ansible_port=5986
ansible_winrm_transport=ntlm
ansible_winrm_server_cert_validation=ignore
```

### ② `playbooks/packages/vm_build/roles/<role>/group_vars/main.yml`
各ロールの検証値（`VAR_vm`）。ロールごとに必要なメンバーが異なります。

```yaml
# import_template_vm: name / template_path
VAR_vm:
  - name: testvm01
    os_type: windows
    template_path: "C:\\path\\to\\template\\Virtual Machines"  # .vmcxの1つ上のフォルダ

# set_vm_cpu: name / cpu_count
# set_vm_memory: name / memory_startup_mb / memory_dynamic / memory_min_mb / memory_max_mb
# set_vm_disk: name / os_type / os_disk_size_gb / os_disk_drive_letter / guest_admin_user / guest_admin_password
# start_vm: name
# configure_guest_network: name / os_type / guest_admin_user / guest_admin_password /
#   segments: [ { name, switch_name, ip, prefix, gateway, dns } , ... ]   ← 複数セグメント（スイッチ1:1）をリストで定義
```

### ③ `playbooks/provisioning/group_vars/all.yml`
AWS検証環境の設定。

```yaml
aws_region: ap-northeast-1
ami_name_pattern: "Windows_Server-2022-English-Full-Base-*"
key_name: <キーペア名>
vpc_id: <VPC ID>
vpc_subnet_id: <サブネットID>
my_ip_cidr: <自分のグローバルIP>/32   # RDP/WinRM許可元
instance_type: m5zn.metal             # ベアメタル必須（後述）
instance_name: hyperv-host-2025
sg_name: hyperv-host-sg
root_volume_gb: 300
snapshot_image_id: ""                 # スナップショット復元時に設定
```

---

## 注意点

### テンプレート / sysprep

**sysprep を実行する前に、回復パーティションを削除する**こと。
回復パーティションがCドライブの直後に残っていると、`set_vm_disk` でのOSディスク拡張が阻害される
（Cの直後が塞がれ、その先に未割当があっても拡張できない）。テンプレート段階で削除しておく。

#### 1. 回復パーティションの削除（diskpart）

テンプレートVM内で実施する。

1. **コマンドプロンプトを管理者として起動する**
   スタートメニューで「cmd」と入力 →「コマンドプロンプト」を右クリック →「管理者として実行」。
2. **diskpart を起動する**
   ```
   diskpart
   ```
3. **ディスクの一覧を表示する**
   ```
   list disk
   ```
4. **対象のディスクを選択する**（OSが入っているディスク。例: ディスク0）
   ```
   select disk 0
   ```
   ※「ディスク 0 が選択されました。」と表示されることを確認。
5. **パーティションの一覧を表示する**
   ```
   list partition
   ```
6. **削除する回復パーティションを選択する**（種類が「回復」の番号。例: パーティション3）
   ```
   select partition 3
   ```
   ※ 容量などを目安に、**間違った番号を選ばないよう確実に見極める**こと。
7. **パーティションを強制削除する**（保護パーティションのため override が必要）
   ```
   delete partition override
   ```
   ※「DiskPart は選択されたパーティションを正常に削除しました。」と表示されれば完了。
8. **diskpart を終了する**
   ```
   exit
   ```

> 削除した領域は「未割り当て」になる。テンプレートでは未割り当てのままでよい
> （実際のOSディスク拡張は `set_vm_disk` ロールが自動で行う）。
> 手動で拡張する場合は「ディスクの管理」ツールで対象ドライブを右クリック →「ボリュームの拡張」。
> ※未割り当て領域が拡張したいドライブの**右側に隣接**している必要がある。

#### 2. sysprep の実行

```
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm
```

#### 3. エクスポート

- VMが停止したら、その状態のVHDX/構成を **`Virtual Machines` フォルダごとエクスポート/コピー**してテンプレート置き場に配置する。
- `import_template_vm` の `template_path` は `.vmcx` の**1つ上の `Virtual Machines` フォルダ**を指定する。

### set_vm_disk（OSディスク拡張）
- **Generation 2 / SCSI 接続前提**（VM起動中のオンラインVHDX拡張を利用）。Gen1/IDEは未対応。
- ゲスト内拡張は **Windowsのみ**（PowerShell Direct使用。RHELはVHDX拡張のみ）。
- **回復パーティションがCドライブの直後にあると、Cを拡張できない**（その先に未割当があっても不可）。
  テンプレート作成時にCを最大化しておくか、回復パーティションの配置を見直すこと。
- 拡張の成否判定は **`after >= before`（縮小していなければOK）**。GPT予備領域等で目標サイズちょうどには
  届かないため、目標サイズ厳密一致では判定しない。

### configure_guest_network（複数セグメント）
- **前提**: セグメントと仮想スイッチは**1:1**（**VLANは使用しない**）。各セグメントの仮想NICは
  **テンプレート作成時に追加・スイッチ接続済み**であること。本ロールは vNICの作成・スイッチ接続は
  **行わない**（既存vNICにIPを設定するのみ）。
- 各セグメントの**`segments[].switch_name` に一致する接続先スイッチの既存vNICをホスト側で特定**
  （`Get-VMNetworkAdapter` の `SwitchName`）してMACを取得し、ゲスト内でMAC一致のNICにIPを設定する。
  `segments[]` をリストで定義する。
- **NICの識別はMACで行う**（接続先スイッチはゲストOSから見えないため。ホスト側でswitch_name→vNIC→MACを解決してゲストに渡す）。
- **1スイッチ1vNIC前提**。同一スイッチに複数vNICが接続されている場合は構成不正として fail する
  （黙って誤ったNICに設定しない）。
- **デフォルトゲートウェイは1セグメントのみ**に設定する（複数GWは経路が不定になり通信が不安定化する）。
- ホストから各VMへ各セグメントで疎通確認するには、ホスト側にも各スイッチの管理OS vNICが必要
  （Internalスイッチなら既定で作成される。Privateスイッチはホストから疎通不可）。VM内・VM同士の通信だけなら不要。
- ゲスト内設定のみのため `start_vm` の後（VM稼働中）に実行する。

### AWS検証環境（provisioning）
- **Hyper-Vのネスト仮想化はベアメタル(`.metal`)インスタンスでのみ可能**。料金が高く起動も遅い（10〜20分）。
  使用後は `terminate_ec2_hyperv.yml` で必ず削除すること。
- **Windows Server 2025 はBootMode=uefi固定で、東京リージョンのx86ベアメタル(legacy-bios)では起動不可**。
  そのため検証ホストは **Windows Server 2022（legacy-bios）** を使用する。
- EC2 の Administrator パスワードはキーペアで復号して取得する
  （`aws ec2 get-password-data --instance-id <id> --priv-launch-key <pem>`）。
- **Hyper-Vの External 仮想スイッチはプライマリNICを奪い、ホストごとネットワーク不通になる**ことがある
  （AMI化→復元で特に発生）。検証では **Internal/Private 仮想スイッチ**を推奨。外部接続が必要な場合は
  セカンダリENIの追加やホストNAT等の設計が必要。

---

## OS設定パッケージ（os_config）

構築済みの Windows Server 2022 ゲストに対する**OS初期設定**を行うパッケージ。
`vm_build`（Hyper-Vホスト経由）と異なり、**各VMへ直接WinRM接続**する（Exastro標準）。
配置: `playbooks/packages/os_config/`。

### ロール一覧（実行順）

| ロール | 説明 | 主な使用モジュール |
|--------|------|--------------------|
| **time_sync** | タイムゾーン＋NTP（w32time）による時刻同期 | `win_timezone` / `win_service` / `win_command` |
| **windows_feature** | 役割と機能のインストール/削除 | `win_feature` |
| **local_user** | ローカルユーザ作成（既定 Administrators グループに追加） | `win_user` |
| **disable_ipv6** | IPv6無効化（`DisableComponents` レジストリ DWORD作成） | `win_regedit` |
| **memory_dump** | カーネルメモリダンプ設定（`CrashControl`） | `win_regedit` |
| **windows_firewall** | ファイアウォール プロファイル＋ルール | `win_firewall` / `win_firewall_rule` |
| **service_config** | サービス起動種別設定（`disabled`、不可なら `manual` にフォールバック） | `win_service` |
| **finalize_reboot** | 末尾で1回だけ再起動（`reboot_required` 集約） | `win_reboot` |

> 再起動が必要な変更（feature/ipv6/dump）は各ロールが `reboot_required` を立て、末尾の `finalize_reboot` で1回だけ再起動する。

### 検証実行
```bash
cd playbooks/packages/os_config
ansible-galaxy collection install -r requirements.yml
# inventory.ini（各VMの管理IP/Administrator/WinRM）と各 roles/*/group_vars/main.yml を用意
ansible-playbook -i inventory.ini test_time_sync.yml      # 個別ロール検証
ansible-playbook -i inventory.ini site.yml                # 全ロール＋末尾再起動
```

### 注意点
- **接続は各VMへ直接WinRM**。EC2検証では対象VMがInternalスイッチで隔離されるため、**Hyper-Vホスト上でansibleを実行**するか、ホストを踏み台にして到達させる。
- `service_config` は `disabled` にできないサービスを自動的に `manual` にフォールバックする（block/rescue）。
- `local_user` のパスワードは `no_log` で保護。`disable_ipv6`/`memory_dump` は反映に再起動が必要。
- 個別の `test_disable_ipv6.yml` / `test_memory_dump.yml` は `finalize_reboot` を含まないため、`reboot_required` を立てても再起動されない（**個別検証では手動で再起動**）。一括反映は `site.yml` を使う。
- パラメータシート設計は `os-config-parameter-sheet-design.md` を参照。
- git管理外: `os_config/inventory.ini` / 各 `roles/*/group_vars/main.yml`（`.gitignore` の `**/inventory.ini`・`**/group_vars/main.yml` で既にカバー）。
