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
| **import_template_vm** | sysprep済みテンプレートのエクスポート(`Virtual Machines`フォルダ)から `Import-VM -Copy -GenerateNewId` でVMを複製作成しリネーム。VMごとに専用フォルダ(`C:\VMs\<VM名>`)へVHD/構成を配置。テンプレートはC(OS/固定)・D(データ/可変)の2ディスクをマウント済み前提で、インポート後にVHDXファイル名をVM名基準へリネーム（C=`<VM名>.vhdx` / D=`<VM名>_data.vhdx`。Gen2はOSディスクを先頭ブートに再設定）。新規ディスク作成やサイズ変更は行わない。同名VMが存在する場合はスキップ（冪等）。 | `ansible.windows.win_find` / `win_shell` |
| **set_vm_cpu** | vCPU数を設定する。 | `microsoft.hyperv.hv_processor` |
| **set_vm_memory** | メモリを設定する。`memory_dynamic` により動的メモリ（startup/min/max）／静的メモリ（startupのみ）を切替。 | `microsoft.hyperv.hv_memory` |
| **set_vm_disk** | OSディスクを拡張する。ホスト側で `hv_vhd` によりVHDXを拡張し、ゲスト内で PowerShell Direct によりOSパーティションを最大まで拡張する（Windowsのみ）。 | `microsoft.hyperv.hv_vhd` / `ansible.windows.win_shell` |
| **start_vm** | VMを起動し、`Running` になるまで待機する。 | `microsoft.hyperv.hv_vm_state` |
| **configure_guest_network** | ゲストOSに**固定3LAN**（サーバ/管理/バックアップ）のIPアドレスを設定する。LAN=仮想スイッチ1:1（**VLAN不使用**）で、各LANの仮想NICは**テンプレートで追加・スイッチ接続済み**前提。LAN種別→スイッチ名は defaults の `switch_map` で解決し、その接続先スイッチの既存vNICをMACで特定して、ゲスト内でそのNICに各LANのIP（`segments[0].{sv,mgmt,bk}_lan_ip/prefix`）を設定する。**サーバLAN（sv_lan）のみ** `segments[0].sv_lan_gateway` でデフォルトゲートウェイを設定（他LANは空白）。接続は PowerShell Direct。 | `ansible.windows.win_shell`（PowerShell Direct） |
| **create_admin_user** | ゲスト内に**ローカル管理者ユーザー**（`admin_user_name`）を作成し、**Administrators グループ**（既定SID `S-1-5-32-544` で解決）へ所属させる。`Get-LocalUser`/`Get-LocalGroupMember` で存在・所属を確認し、無い場合のみ `New-LocalUser`/`Add-LocalGroupMember` を実行（冪等）。接続は PowerShell Direct（`item.os_family == 'WindowsServer'` のみ）。 | `ansible.windows.win_shell`（PowerShell Direct） |

> 実行順序（Conductor相当）: `import_template_vm` → `set_vm_cpu` → `set_vm_memory` →
> （ファームウェア/時刻同期）→ `start_vm` → `set_vm_disk` → `configure_guest_network` → `create_admin_user`
> ※ `set_vm_disk` / `configure_guest_network` / `create_admin_user` のゲスト内設定はVM起動が前提のため、`start_vm` の後に実行します。

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
ansible-playbook -i inventory.ini test_configure_guest_network.yml # 固定3LAN IP設定（起動後）
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
#   segments: [ { sv_lan_ip, sv_lan_prefix, sv_lan_gateway, mgmt_lan_ip, mgmt_lan_prefix, bk_lan_ip, bk_lan_prefix } ]  ← 固定3LAN（配列先頭[0]・固定キー）
#     ※ sv_lan_gateway はサーバLAN専用のデフォルトゲートウェイ（空/未指定なら設定しない）。mgmt_lan/bk_lan はゲートウェイ無し（空白）
#   ※ LAN種別→スイッチ名は defaults の switch_map（sv_lan/mgmt_lan/bk_lan）で解決（環境固定・代入値ではない）
# create_admin_user: name / os_family / admin_user_name / admin_user_password / guest_admin_user / guest_admin_password
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

### configure_guest_network（固定3LAN：サーバ/管理/バックアップ）
- **前提**: LANと仮想スイッチは**1:1**（**VLANは使用しない**）。各LANの仮想NICは
  **テンプレート作成時に追加・スイッチ接続済み**であること。本ロールは vNICの作成・スイッチ接続は
  **行わない**（既存vNICにIPを設定するのみ）。
- **IPは Exastro 代入値**（`segments[0]` の固定キー：`sv_lan_ip`/`sv_lan_prefix`/`sv_lan_gateway`/`mgmt_lan_ip`/
  `mgmt_lan_prefix`/`bk_lan_ip`/`bk_lan_prefix`）で定義する。可変長配列ではなく固定3LANの単一要素。
- **LAN種別→接続先スイッチ名は defaults の `switch_map`**（`sv_lan`/`mgmt_lan`/`bk_lan`）で解決する
  （環境固定・代入値ではない）。そのスイッチに接続された既存vNIC（`Get-VMNetworkAdapter` の `SwitchName`）
  をホスト側で特定してMACを取得し、ゲスト内でMAC一致のNICにIPを設定する。
- **NICの識別はMACで行う**（接続先スイッチはゲストOSから見えないため。ホスト側でswitch_map→vNIC→MACを解決してゲストに渡す）。
- **1スイッチ1vNIC前提**。同一スイッチに複数vNICが接続されている場合は構成不正として fail する
  （黙って誤ったNICに設定しない）。
- **デフォルトゲートウェイはサーバLAN（sv_lan）のみ設定する**（2026-07-23・オーナー指示）。
  代入値 `segments[0].sv_lan_gateway` を目標ゲートウェイとし、**管理LAN（mgmt_lan）/ バックアップLAN（bk_lan）は空白**
  （ゲートウェイを設定しない）。デフォルトゲートウェイは sv_lan に一本化する。
  - `sv_lan_gateway` は**文字列として扱い**（[int]変換はしない。prefix=0事件と同種の「$null→0 で静かに不正値」を回避）、
    **空/未指定なら「設定しない」に倒す**（エラーにしない）。
  - **冪等性は IP変更とは独立**に担保する。当該IFの既定ルート（`Get-NetRoute 0.0.0.0/0`）の NextHop が目標と一致していれば
    何もしない（changed=false）。不一致/未設定なら既存 0.0.0.0/0 を除去して目標ゲートウェイで再追加する
    （IPが既に一致していても初回はゲートウェイが設定される）。
  - mgmt_lan/bk_lan は「空白」を保証するため、当該IFに既定ルートが残っていれば除去する（無ければ no-op で冪等）。
  - **永続化**: 既定ルートは `ActiveStore`（即時反映）と `PersistentStore`（再起動後も残す）の**両ストア**に登録する。
    New-NetRoute の既定は ActiveStore のみ（非永続）で、IPは永続なため「再起動後にIPは残るが既定ゲートウェイだけ消える」
    非対称障害を避けるため。mgmt/bk の空白化も両ストアから 0.0.0.0/0 を除去して再起動後も空白を保証する。
    冪等判定は「ActiveStore の NextHop が目標一致 かつ PersistentStore にも同一ルートあり」で no-op。
  - ※ **DNS・ホスト名は設定しない**。
- ホストから各VMへ各LANで疎通確認するには、ホスト側にも各スイッチの管理OS vNICが必要
  （Internalスイッチなら既定で作成される。Privateスイッチはホストから疎通不可）。VM内・VM同士の通信だけなら不要。
- ゲスト内設定のみのため `start_vm` の後（VM稼働中）に実行する。

### create_admin_user（ローカル管理者ユーザー作成）
- ゲスト内に **ローカル管理者ユーザー**（`item.admin_user_name`）を作成し、**Administrators グループ**へ所属させる。
  接続は **PowerShell Direct**（`Invoke-Command -VMName`。os_config/local_user の直接WinRM＋win_user とは別方式）。
  VM構築段階ではゲストのネットワーク/WinRMが未構成のため、他の vm_build ゲスト内ロールと同じVMバス経由で実施する。
- **ブートストラップ認証**は テンプレート組込 Administrator（`guest_admin_user`/`guest_admin_password`）を使用する
  （作成する新規ユーザーとは別物）。
- **冪等**: `Get-LocalUser` で存在確認 → 無ければ `New-LocalUser`（`PasswordNeverExpires`。`UserMayNotChangePassword` は付けない）。
  `Get-LocalGroupMember` で Administrators 所属確認 → 未所属なら `Add-LocalGroupMember`。実際に作成/追加した場合のみ changed=true。
- **Administrators グループは既定SID `S-1-5-32-544` で解決**する（英語ロケール前提だがロケール差に強くするため）。
- **失敗検知**: 作成/追加を要求したのに after でユーザー未作成/未所属なら assert で fail（黙って成功扱いにしない）。
  before/after（ユーザー存在・所属）と changed をエビデンス出力（**パスワードは出力しない**）。
- **機密**: 資格情報・ユーザーパスワードを含むタスクは `no_log: true`。
- **運用制約**: `admin_user_name` / `admin_user_password` に**単一引用符 `'` を使わない**こと
  （`win_shell` の PowerShell リテラル `'xxx'` へ埋め込むため、`'` を含むと文字列が壊れる。既存ロール共通の制約）。
- **失敗理由の可視化**: ゲスト内処理は try/catch で握り、失敗時は返却JSONの `error` に例外メッセージを載せて
  no_log 無しの assert/debug で表示する（New-LocalUser のパスワードポリシー違反等を隠蔽しない。パスワードは出力しない）。
- `item.os_family == 'WindowsServer'` のときのみ実行（RHEL等はskip）。ゲスト内設定のため `start_vm` の後に実行する。

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
| **local_user** | ローカルユーザの**存在確認→分岐**作成。`Get-LocalUser`/`Get-LocalGroupMember`（Administrators は SID `S-1-5-32-544` で解決）で before 取得→ 未存在なら `win_user`（`update_password: on_create`）で作成＋Administrators所属、存在＋未所属なら `win_group_membership` で所属のみ追加、所属済みは変更なし（冪等）。 | `win_shell` / `win_user` / `win_group_membership` |
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
- `local_user` は**存在確認→分岐**フロー。作成タスク（`win_user`）のみ `no_log` で保護し `update_password: on_create` で**既存ユーザーのパスワードを毎回上書きしない**。所属追加は `win_group_membership`（パスワード非関与）。before/after・assert・debug はパスワードを含まず可視化。
  - 実機検証項目（**環境起動時に要実施**）: ①新規ユーザー→作成＋Administrators所属で `changed=true` ②既存＋未所属→**所属追加のみ** `changed=true`（パスワード不変）③既存＋所属済み→`changed=false` ④再実行で全体 `changed=false`。
- `disable_ipv6`/`memory_dump` は反映に再起動が必要。
- 個別の `test_disable_ipv6.yml` / `test_memory_dump.yml` は `finalize_reboot` を含まないため、`reboot_required` を立てても再起動されない（**個別検証では手動で再起動**）。一括反映は `site.yml` を使う。
- パラメータシート設計は `os-config-parameter-sheet-design.md` を参照。
- git管理外: `os_config/inventory.ini` / 各 `roles/*/group_vars/main.yml`（`.gitignore` の `**/inventory.ini`・`**/group_vars/main.yml` で既にカバー）。
