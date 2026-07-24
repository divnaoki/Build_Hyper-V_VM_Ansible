---
project: hyperv-vm-build
doc: os-config-parameter-sheet-design
status: draft
created: 2026-06-30
---

# パラメータシート定義 / 代入値自動登録設定（os_config パッケージ）

対象: Windows Server 2022 のOS初期設定。各対象サーバへ**直接WinRM接続**で実行する。
Exastroの「機器一覧」に各VMを登録し、メニューグループ「OS設定」配下の各メニューで値を管理する。
リスト系（役割機能/ユーザ/Firewallルール/サービス）は **バンドルON**（1メニュー内に複数レコード）。

---

## メニュー一覧

| # | メニュー | Playbook変数 | バンドル | 対応ロール |
|---|----------|--------------|----------|-----------|
| 1 | 時刻同期 | `VAR_timezone` / `VAR_ntp_servers` | NTPサーバはバンドルON | time_sync |
| 2 | 役割と機能 | `VAR_features` | ON | windows_feature |
| 3 | ユーザ | `VAR_users` | ON | local_user |
| 4 | IPv6無効化 | `VAR_ipv6_disablecomponents` | OFF | disable_ipv6 |
| 5 | メモリダンプ | `VAR_dump_type` 他 | OFF | memory_dump |
| 6 | Firewallプロファイル | `VAR_fw_profiles` | ON | windows_firewall |
| 7 | Firewallルール | `VAR_fw_rules` | ON | windows_firewall |
| 8 | サービス設定 | `VAR_services` | ON | service_config |
| 9 | UAC設定（ソフトウェア制御） | `VAR_uac_level` | OFF | uac_config |

---

## 1. 時刻同期

| 項目名 | 代入先 | 型 | 必須 | 既定/例 |
|--------|--------|----|------|---------|
| タイムゾーン | `VAR_timezone` | 文字列 | △ | `Tokyo Standard Time` |
| NTPサーバ | `VAR_ntp_servers[]` | 文字列(バンドル) | △ | `ntp.nict.jp` |

## 2. 役割と機能（バンドルON）

| 項目名 | 代入先 | 型 | 必須 | 例 |
|--------|--------|----|------|----|
| 機能名 | `VAR_features[].name` | 文字列 | ○ | `SNMP-Service` |
| 状態 | `VAR_features[].state` | プルダウン | ○ | `present`/`absent` |
| 管理ツール同梱 | `VAR_features[].include_management_tools` | 真偽 | △ | `false` |
| サブ機能同梱 | `VAR_features[].include_sub_features` | 真偽 | △ | `false` |

## 3. ユーザ（バンドルON）

| 項目名 | 代入先 | 型 | 必須 | 例 |
|--------|--------|----|------|----|
| ユーザー名 | `VAR_users[].name` | 文字列 | ○ | `opsadmin` |
| パスワード | `VAR_users[].password` | **パスワード**(機密) | ○ | ******** |
| グループ | `VAR_users[].groups` | 文字列(複数) | △ | `Administrators`（既定） |
| 説明 | `VAR_users[].description` | 文字列 | △ | 運用管理者 |
| パスワード無期限 | `VAR_users[].password_never_expires` | 真偽 | △ | `true` |

> パスワードは入力タイプ=パスワード、Playbook側 `no_log`。グループ既定は Administrators（`groups_action=add`）。

## 4. IPv6無効化

| 項目名 | 代入先 | 型 | 必須 | 既定 |
|--------|--------|----|------|------|
| DisableComponents値 | `VAR_ipv6_disablecomponents` | 文字列(16進) | ○ | `0xFF`（全無効） |

> `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters` に DWORD で設定。反映に再起動が必要。

## 5. メモリダンプ

| 項目名 | 代入先 | 型 | 必須 | 既定 |
|--------|--------|----|------|------|
| ダンプ種別 | `VAR_dump_type` | プルダウン | ○ | `2`（カーネル） |
| 自動再起動 | `VAR_dump_autoreboot` | 真偽(0/1) | △ | `1` |
| 上書き | `VAR_dump_overwrite` | 真偽(0/1) | △ | `1` |

> `HKLM\SYSTEM\CurrentControlSet\Control\CrashControl`。CrashDumpEnabled 変更時は再起動が必要。

## 6. Firewallプロファイル（バンドルON）

| 項目名 | 代入先 | 型 | 必須 | 例 |
|--------|--------|----|------|----|
| 状態 | `VAR_fw_profiles[].state` | プルダウン | ○ | `enabled`/`disabled` |
| プロファイル | `VAR_fw_profiles[].profiles` | 複数 | ○ | `Domain,Private,Public` |
| 既定インバウンド | `VAR_fw_profiles[].inbound_action` | プルダウン | △ | `block` |
| 既定アウトバウンド | `VAR_fw_profiles[].outbound_action` | プルダウン | △ | `allow` |

## 7. Firewallルール（バンドルON）

| 項目名 | 代入先 | 型 | 必須 | 例 |
|--------|--------|----|------|----|
| ルール名 | `VAR_fw_rules[].name` | 文字列 | ○ | `Allow WinRM-In` |
| 方向 | `VAR_fw_rules[].direction` | プルダウン | ○ | `in`/`out` |
| アクション | `VAR_fw_rules[].action` | プルダウン | ○ | `allow`/`block` |
| プロトコル | `VAR_fw_rules[].protocol` | 文字列 | △ | `tcp`/`icmpv4` |
| ローカルポート | `VAR_fw_rules[].localport` | 文字列 | △ | `5985-5986` |
| 許可元IP | `VAR_fw_rules[].remoteip` | 文字列 | △ | `192.168.0.0/24` |
| プロファイル | `VAR_fw_rules[].profiles` | 複数 | △ | `domain,private,public` |

## 8. サービス設定（バンドルON）

| 項目名 | 代入先 | 型 | 必須 | 例 |
|--------|--------|----|------|----|
| サービス名 | `VAR_services[].name` | 文字列 | ○ | `Spooler` |
| 起動種別 | `VAR_services[].startup_type` | プルダウン | ○ | `disabled`（既定）/`manual`/`auto` |
| 状態 | `VAR_services[].state` | プルダウン | △ | `stopped`（既定） |

> `disabled` にできないサービスは Playbook側で自動的に `manual` にフォールバックする。

## 9. UAC設定（ソフトウェア制御 / 表2.2.3）

| 項目名 | 代入先 | 型 | 必須 | 既定/例 |
|--------|--------|----|------|---------|
| UAC通知レベル | `VAR_uac_level` | プルダウン | ○ | `notify_default`（アプリの変更時のみ通知＝Windows既定・本システム設定値） |

> **UAC有効化（EnableLUA）は代入項目にしない（環境固定）**。本システムは UAC を常に有効（`EnableLUA=1`）で
> 運用する方針（表2.2.3の設定対象は「通知タイミング」のみ）。運用者が誤って UAC を無効化できないよう、
> パラメータシートには出さず、ロール defaults の環境固定値（`VAR_uac_enablelua: 1`）として扱う。（PM SHOULD-1）

プルダウン選択肢（`VAR_uac_level`）と対応レジストリ値:

| 選択肢 | 意味 | ConsentPromptBehaviorAdmin | PromptOnSecureDesktop |
|--------|------|:--:|:--:|
| `always` | 常に通知 | 2 | 1 |
| **`notify_default`** | **アプリがコンピュータに変更を加えようとする場合のみ通知する（既定）** | **5** | **1** |
| `notify_nodim` | アプリの変更時のみ通知（デスクトップを暗転しない） | 5 | 0 |
| `never` | 通知しない | 0 | 0 |

> `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` に DWORD で設定。
> レジストリ値のマッピングは環境固定（ロール defaults の `uac_level_map`）で、パラメータシートからは
> **レベル名（プルダウン）のみ**を代入する。`EnableLUA` を 0→1/1→0 に変更した場合のみ再起動が必要
> （`finalize_reboot` に集約）。通知レベルの変更は再起動なしで反映される。
> 本システムは表2.2.3のとおり既定値（`notify_default`）で運用する。

---

## 代入値自動登録設定 / 接続
- 接続: 各対象サーバへ直接WinRM（Exastro機器一覧に Administrator / WinRM(5986/ntlm) を登録）。
- 単一値メニュー（IPv6/ダンプ/UAC）は単一具体値変数、リスト系はバンドルON（複数具体値変数）。
- 機密項目（ユーザパスワード）は入力タイプ=パスワード、Playbook側 `no_log`。
- 再起動は Conductor 末尾の `finalize_reboot`（`reboot_required` 集約）で1回。

## 残課題 / PM確認
- [ ] 役割と機能・サービスの「実環境での具体的な対象リスト」確定（検証値は例示）。
- [ ] IPv6 DisableComponents の値（`0xFF` 全無効 で良いか）。
- [ ] Conductor定義（time_sync→…→service_config→finalize_reboot）の作成。
