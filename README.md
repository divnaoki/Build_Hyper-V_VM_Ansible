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
│   │   │   └── start_vm/
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

> 実行順序（Conductor相当）: `import_template_vm` → `set_vm_cpu` → `set_vm_memory` →
> （ネットワーク/ファームウェア/時刻同期）→ `start_vm` → `set_vm_disk`
> ※ `set_vm_disk` のゲスト内拡張はVM起動が前提のため、`start_vm` の後に実行します。

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
ansible-playbook -i inventory.ini test_start_vm.yml             # VM起動
ansible-playbook -i inventory.ini test_set_vm_disk.yml          # OSディスク拡張（起動後）
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
```
