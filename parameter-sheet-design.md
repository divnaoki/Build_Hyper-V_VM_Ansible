---
project: hyperv-vm-build
doc: parameter-sheet-design
status: draft
created: 2026-06-25
---

# パラメータシート定義 / 代入値自動登録設定（vm_build）

対象: Conductor「仮想マシン構築」。複数具体値変数 **VAR_vm**（1レコード=1VM）を **バンドルON** の
パラメータシートで管理し、各Movementは `loop: VAR_vm` で全VMを処理する。

本書は今回追加した **Disk設定（set_vm_disk）の項目**を中心に、VAR_vm 全体の中での位置づけを示す。

---

## 1. パラメータシート概要

| 項目 | 値 |
|------|----|
| メニューグループ | 仮想マシン構築 |
| メニュー名 | VM構築パラメータ（vm_build_params） |
| バンドル | **ON**（1レコード=1VM。繰り返し入力） |
| 紐づくPlaybook変数 | `VAR_vm`（複数具体値変数 / リスト型・要素=連想配列） |
| 代入順序 | レコードの並び順 = `loop: VAR_vm` の順 |

> Exastroの「複数具体値変数」は、バンドルONのパラメータシート1行が VAR_vm の1要素（item）に対応する。
> 各列が item.<member> に展開される。

---

## 2. 項目定義（VAR_vm メンバー）

凡例: 🆕＝今回 set_vm_disk で追加 / （既存）＝import_template_vm 等で定義済み

| # | 項目名（画面表示） | Playbook変数（代入先） | 入力タイプ | 必須 | 制約・桁 | 既定/例 | 説明 |
|---|--------------------|------------------------|-----------|------|----------|---------|------|
| 1 | VM名 | `VAR_vm.name` | 文字列 | ○ | 1–64 / `^[A-Za-z0-9_-]+$` | vm01 | 作成するVM名 |
| 2 | OS種別 | `VAR_vm.os_type` | プルダウン | ○ | `windows` / `rhel` | windows | ゲスト内処理の分岐に使用 |
| 3 | テンプレートパス | `VAR_vm.template_path` | 文字列 | ○ | UNC/ローカルパス | `D:\Templates\WS2022\Virtual Machines` | .vmcxの1つ上フォルダ |
| 4 | vCPU数 | `VAR_vm.cpu_count` | 数値 | ○ | 1–（ホスト上限） | 4 | set_vm_cpu |
| 5 | 起動メモリ(MB) | `VAR_vm.memory_startup_mb` | 数値 | ○ | 512以上 | 4096 | set_vm_memory |
| 6 | 動的メモリ | `VAR_vm.memory_dynamic` | プルダウン(真偽) | ○ | `true`/`false` | false | true時は7,8必須 |
| 7 | 最小メモリ(MB) | `VAR_vm.memory_min_mb` | 数値 | △ | 動的時のみ必須 | 2048 | set_vm_memory |
| 8 | 最大メモリ(MB) | `VAR_vm.memory_max_mb` | 数値 | △ | 動的時のみ必須 | 8192 | set_vm_memory |
| 9 | **OSディスクサイズ(GB)** 🆕 | `VAR_vm.os_disk_size_gb` | 数値 | ○ | テンプレート現サイズ以上の整数 | 100 | **set_vm_disk**。目標VHDXサイズ。現サイズ未満のときのみ拡張（縮小不可） |
| 10 | **OSドライブレター** 🆕 | `VAR_vm.os_disk_drive_letter` | 文字列 | △ | 1文字 / `^[C-Zc-z]$` | C | **set_vm_disk**。ゲスト内拡張対象（Windowsのみ）。既定 `C` |
| 11 | 仮想スイッチ名 | `VAR_vm.switch_name` | 文字列 | ○ | – | vSwitch01 | configure_vm_network ※ |
| 13 | セキュアブート | `VAR_vm.secure_boot` | プルダウン | ○ | `on`/`off`/`rhel` | on | configure_vm_firmware |
| 14 | ゲスト管理ユーザー | `VAR_vm.guest_admin_user` | 文字列 | ○ | – | Administrator | PowerShell Direct（set_vm_disk等） |
| 15 | ゲスト管理パスワード | `VAR_vm.guest_admin_password` | **パスワード** | ○ | 機密(no_log) | ******** | PowerShell Direct（set_vm_disk等） |
| 16 | ゲストIPアドレス | `VAR_vm.guest_ip_address` | 文字列 | △ | Windowsのみ | 192.168.10.21 | configure_vm_network |
| 17 | サブネットプレフィックス | `VAR_vm.guest_subnet_prefix` | 数値 | △ | 0–32 | 24 | configure_vm_network |
| 18 | デフォルトGW | `VAR_vm.guest_default_gateway` | 文字列 | △ | Windowsのみ | 192.168.10.1 | configure_vm_network |
| 19 | DNSサーバー | `VAR_vm.guest_dns_servers` | 文字列(カンマ区切り) | △ | Windowsのみ | 192.168.10.1 | configure_vm_network。Playbook側で list 化 |

> 本書の主対象は **#9・#10（🆕 Disk）**。それ以外は既存項目の参考掲載。
>
> ※ **VLANは使用しない方針に変更（2026-07-07）**。旧 #12「VLAN ID」項目は削除。
> ※ **configure_guest_network を固定3LAN構成に変更（2026-07-10）**。ネットワーク関連（#11・#16〜#19）は
> 以下に置き換わる（gateway / dns / ホスト名設定は廃止）:
> - **代入値（Exastro Legacy Role）**: `VAR_vm.segments[0]` の固定キー
>   `sv_lan_ip` / `sv_lan_prefix` / `mgmt_lan_ip` / `mgmt_lan_prefix` / `bk_lan_ip` / `bk_lan_prefix`。
> - **環境固定（代入値ではない）**: LAN種別→仮想スイッチ名は defaults の `switch_map`
>   （`sv_lan` / `mgmt_lan` / `bk_lan`）で定義。旧 #11「仮想スイッチ名」は代入値から外れる。
> - vNICは switch_map のスイッチ名で特定（MAC突き合わせ）。旧 #18「デフォルトGW」・#19「DNS」は不使用。

---

## 3. 代入値自動登録設定（set_vm_disk 追加分）

バンドルONのため、1レコードの各列が VAR_vm の対応メンバーへ代入される。今回の追加マッピング:

| パラメータシート項目 | 代入先（Playbook変数） | 代入方式 | 備考 |
|----------------------|------------------------|----------|------|
| OSディスクサイズ(GB) | `VAR_vm[n].os_disk_size_gb` | 値代入（数値） | n=レコード行＝loop順 |
| OSドライブレター | `VAR_vm[n].os_disk_drive_letter` | 値代入（文字列） | 空欄時は既定 `C` を運用で補完 |

> 代入順序（バンドル）はレコードの並び順。import_template_vm から start_vm までの全Movementが
> 同一 VAR_vm を参照するため、**1行に当該VMの全項目（CPU/メモリ/ディスク/NW…）を揃えて入力**する。

---

## 4. 入力バリデーション指針（Disk分）

- `os_disk_size_gb`：整数・正の値。**テンプレートVHDXの現行サイズ以上**であること（未満なら hv_vhd が拡張せず、
  ゲスト内 blocked 検知でassert失敗になり得る点を運用注意として明記）。
- `os_disk_drive_letter`：1文字（C〜Z）。`os_type=rhel` の行では未使用（ゲスト内拡張をスキップするため任意）。

---

## 5. 反映時の作業メモ

- 既存の VAR_vm 構造（`import_template_vm/defaults/main.yml` のコメント参考レコード）にも
  `os_disk_size_gb` / `os_disk_drive_letter` の2メンバーを追記しておくこと（構造の一元管理）。
- 正式な項目定義（型・桁・正規表現）は Exastro パラメータシート作成画面の仕様に合わせて微調整する。
- 本書は詳細設計書（表形式中心）へ統合する前提のドラフト。PMレビュー対象。

## 残課題 / PM確認事項
- [ ] DNSサーバー(#19)のカンマ区切り→list化はPlaybook側 split を想定（既存設計の確認）。本Disk案件の範囲外。
- [ ] os_disk_size_gb のバリデーション（テンプレート現サイズ以上）を画面側で担保するか、Playbook側assertのみとするか。
