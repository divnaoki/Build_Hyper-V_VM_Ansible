---
project: hyperv-vm-build
---

# レビューログ - Hyper-V VM構築（CPU/メモリ/ディスク）

## 2026-06-25 set_vm_disk 新規作成（exastro_engineer → PMレビュー依頼）
- 依頼: CPU/メモリ/Disk設定の実装。CPU(`set_vm_cpu`)・メモリ(`set_vm_memory`)は既存実装済みのため、`set_vm_disk` を新規作成。
- 成果物: `playbooks/packages/vm_build/roles/set_vm_disk/`（tasks/main.yml, tasks/set_vm_disk.yml, defaults/main.yml）
- status: **review**（PMレビュー待ち）
- 主な確認依頼ポイント（詳細は IMPLEMENTATION_NOTE.md）:
  1. start_vm 後配置＋オンラインResize前提（Gen2/SCSI）の妥当性
  2. ゲスト内拡張をWindows限定とした判断（RHEL要否）
  3. Conductor / パラメータシートへの反映タイミング

### 指摘 → 対応履歴

#### 2026-06-25 PM 1stレビュー結果: **fixing（approved見送り）**
観点: 冪等性 / 前後状態取得 / 命名規則 / 不要タスク混入

良かった点（OK）:
- 命名規則・ファイル構成（main.yml→include_tasks→set_vm_disk.yml、変数はdefaults）はルール準拠。
- VHDX拡張・パーティション拡張とも「目標>現状のときのみ実行」で冪等。縮小しない方針も妥当。
- ホスト側VHDXの before/after 取得・assert・エビデンスあり。不要タスクの混入なし。

**[MUST-1] ゲスト準備完了待ちが無く、start_vm直後にPowerShell Directが失敗しうる**
- `start_vm` 直後はゲストOS起動途中で、`Invoke-Command -VMName` が
  「ゲストが応答しない/資格情報を受け付けない」で失敗する典型ケース。失敗時方針は即時中断のため致命的。
- 対応案: ゲスト疎通の待機タスクを前段に追加（`Invoke-Command -VMName ... { 'OK' }` を
  `retries`/`until` でリトライ、または `Wait-VM -For Heartbeat` 後に PowerShell Direct疎通確認）。

**[MUST-2] ゲスト内パーティション拡張の前後取得・検証が無い（前後状態取得の観点）**
- 現状エビデンスはホスト側VHDXの前後のみ。ゲスト内ボリュームは changed フラグだけで、
  実際にCドライブが拡張されたかの before/after・assert が無い。
- 併せて、オンラインVHDX拡張後はゲストでディスク再スキャンが必要な場合がある
  （`Update-Disk` 未実施だと `Get-PartitionSupportedSize` の SizeMax が伸びず no-op になり得る）。
- 対応案: ゲスト内で (a)`Update-Disk`→(b)拡張前サイズ取得→(c)Resize→(d)拡張後サイズ取得 を行い、
  GB差分をエビデンス出力＋assert（拡張後 >= 拡張前）。

**[MUST-3] 末尾パーティション（回復パーティション）で拡張不可になるケースの方針が無い**
- Windowsテンプレートでは C: の直後に回復パーティションが居ることが多く、その場合 SizeMax が伸びず
  C: を拡張できない（実環境で頻出）。現実装は黙って no-op で「成功」扱いになり、検知できない。
- 対応案: 前提（テンプレートは末尾未割当を確保 or 回復パーティションが末尾に無い）を明記し、
  拡張要求があったのに SizeMax が現サイズ以下のときは fail で気づけるようにする。

**[SHOULD-4] ブートディスク特定・世代前提をタスク冒頭で明示**
- `Get-VMHardDiskDrive | Sort | Select -First 1` を OSディスクとみなす前提（=データディスク未追加・Gen2/SCSI）を
  コメントで明記。データディスク追加ロールを将来 set_vm_disk より前に置く場合に誤認するため。

**[SHOULD-5] no_log による失敗時トラブルシュート困難**
- パスワードを含むため `no_log: true` は妥当だが、失敗時にエラー全文も隠れる。
- 対応案: 資格情報生成のみを別変数化、または失敗時に最低限の文脈（vm名）が残る形を検討（許容範囲だが要一言）。

判定: **fixing**。MUST-1〜3を修正し再レビュー依頼のこと。SHOULD-4/5も対応推奨。
※ Gen1/IDE・RHELゲスト拡張は IMPLEMENTATION_NOTE の残課題として別途切り分けでよい（本レビューの範囲外）。

#### 2026-06-25 exastro_engineer 修正対応（→ 再レビュー依頼 status: review）
set_vm_disk.yml を改修。各指摘への対応:
- **[MUST-1] 対応**: タスク5「ゲストOSのPowerShell Direct疎通を待機する」を追加。
  `Invoke-Command -VMName { 'READY' }` を `until/retries:30/delay:10`（最大5分）でリトライし、
  start_vm直後のゲスト起動途中による失敗を回避。
- **[MUST-2] 対応**: タスク6でゲスト内拡張前に `Update-Disk` を実施（オンライン拡張をゲストに認識させる）。
  ゲスト内の before/after/SizeMax を取得しJSONで返却 → タスク8のエビデンスにゲストボリュームの
  前後GB・changed を出力。タスク7のassertで拡張結果を検証。
- **[MUST-3] 対応**: ゲスト内処理で `blocked = (after < target)` を判定。Resize-Partitionは try/catch で
  握って error も返却。タスク7のassert（no_log無し）で blocked時に fail_msg（VM名・前後GB・理由）を出して検知。
- **[SHOULD-4] 対応**: タスク冒頭コメントに Gen2/SCSI前提・データディスク未追加前提・OSディスク特定方法を明記。
- **[SHOULD-5] 対応**: 資格情報を含むタスク（5,6）のみ no_log:true とし、検証(7)・エビデンス(8)は no_log無しで
  VM名・前後サイズ・失敗理由を可視化。

status: **review**（再レビュー待ち）

#### 2026-06-25 exastro_engineer 追加修正（モジュール方針／オーナー指示）
- 指示: 基本は microsoft.hyperv コレクションのモジュールを使い、無いものだけ ansible.windows を使う。
- 対応:
  - **VHDX拡張** を win_shell の `Resize-VHD` → **`microsoft.hyperv.hv_vhd`（path + size_bytes, state: present）** に置換。
    `size_bytes` は拡張のみ（既に同等以上なら changed=false）でモジュール側が冪等性を担保。CPU/メモリ（hv_processor/hv_memory）と同じスタイルに統一。
  - hv_vhd の path 用に、VHDXパス取得タスク（read）を追加。
  - 以下は microsoft.hyperv に該当モジュールが無いため ansible.windows.win_shell を継続:
    VHDXパス/サイズ取得（Get-VMHardDiskDrive / Get-VHD）、ゲスト内パーティション拡張・疎通待ち（PowerShell Direct）。
- 参照: hv_vhd は microsoft.hyperv 公式コレクションのモジュール（size_bytes は expansion only）。
status: **review**（再レビュー待ち・モジュール方針反映済み）

---

## 2026-06-30 OS設定パッケージ（os_config）新規作成（exastro_engineer → PMレビュー依頼）
- 依頼: Windows Server 2022 ゲストへのOS初期設定パッケージ。対象7テーマ＋末尾再起動。
- 接続方式: 各VMへ**直接WinRM**（承認済み）。再起動: **末尾で1回**（reboot_required集約・承認済み）。
- 成果物: `playbooks/packages/os_config/`（site.yml＋8ロール＋各 test_*.yml）
  - time_sync / windows_feature / local_user / disable_ipv6 / memory_dump / windows_firewall / service_config / finalize_reboot
- パラメータシート設計: `os-config-parameter-sheet-design.md`
- モジュールマニュアル運用: 新規8モジュール（win_feature/win_user/win_regedit/win_service/win_reboot/
  community.windows.win_firewall/win_firewall_rule/win_timezone）をObsidian登録済み（9/9確認）。
- 構文チェック: site.yml＋全 test_*.yml OK。
- status: **review**（PMレビュー待ち）

### 主な確認依頼ポイント
1. 接続方式（直接WinRM）とEC2検証時の到達性（ホスト上でansible実行 or 踏み台）の妥当性。
2. service_config の disabled→manual フォールバック設計（block/rescue・include_tasksループ）。
3. 再起動集約（feature/ipv6/dump → finalize_reboot で1回）の妥当性。
4. 検証値（features/services 等）は例示。実環境の対象リスト確定が残課題。

#### 2026-06-30 PM 1stレビュー結果: **fixing（approved見送り）**
観点: 冪等性 / 前後状態取得 / 命名規則 / 不要タスク混入

良かった点（OK）:
- 命名規則・構造（main.yml→include_tasks→<処理名>.yml、_service_one.yml の内部タスク命名、defaults/group_vars/test_*.yml）規約準拠。
- 専用モジュール（win_feature/win_user/win_regedit/win_service/win_firewall/win_timezone）を適切に選定し、
  大半のロールはモジュールで冪等性を確保。全win_shell化を避けている点は良い。
- ユーザパスワードの no_log、reboot_required 集約→末尾1回再起動、フォールバック発想、
  モジュールマニュアル運用・パラメータシート設計の整備も妥当。

**[MUST-1] time_sync のNTP設定が冪等でない**
- `w32tm /config` を毎回実行し、changed_when を出力文言（successfully/正常に）で判定しているため、
  既に同一NTP設定でも**毎回 changed=true** になる。さらに文言はロケール依存で誤判定の懸念。
- 対応案: 実行前に現NTP設定（`w32tm /query /configuration` の NtpServer/Type）を取得し、
  目標と一致していれば config をスキップ（when ガード）。または before/after 比較で changed を確定。

**[MUST-2] service_config の disabled→manual フォールバックが実態を拾えない可能性**
- rescue が発動するのは win_service タスクが**失敗**したときのみ。実際には多くのサービスは
  `start_mode: disabled` の**設定自体は成功**し（無効化できないのは一部のトリガー開始/保護サービス）、
  「無効化できない」ケースをタスク失敗として検知できない恐れがある。
- 対応案: 設定後に実際の start_mode を取得して `disabled` になったか検証し、なっていなければ manual に切替える
  （rescue だけに依存しない）。実機での挙動確認を必須とする。

**[SHOULD-3] memory_dump に before 取得が無い**
- disable_ipv6 は before（現 DisableComponents）を取得しているが、memory_dump は現 CrashDumpEnabled の
  before 取得が無くエビデンスが非対称。一貫性のため before 取得を追加推奨。

**[SHOULD-4] Firewallプロファイル名の大小整合**
- `win_firewall` は `Domain/Private/Public`、`win_firewall_rule` は `domain/private/public` と表記が混在。
  各モジュールの受理形式を確認し、group_vars/パラメータシートの記載を統一すること。

**[NIT-5] 個別 test_*.yml（ipv6/dump）は finalize_reboot を含まない**
- 個別検証では reboot_required を立てても再起動されない（手動再起動が必要）。READMEに一言補足を推奨。

判定: **fixing**。MUST-1/2 を修正し再レビュー依頼のこと。SHOULD-3/4・NIT-5 も対応推奨。
※ 実機検証（特に MUST-2 のフォールバック動作、冪等性2回実行）は接続環境が整い次第必須。

#### 2026-06-30 exastro_engineer 修正対応（→ 再レビュー依頼 status: review）
- **[MUST-1] 対応**: time_sync のNTP設定を冪等化。`w32tm /query /configuration` の出力に対し
  `VAR_ntp_servers | reject('in', before)` で**未設定サーバがある場合のみ** `w32tm /config` を実行（when ガード）。
  changed は `ntp_config is not skipped` で判定（毎回 changed=true を解消）。resync も設定変更時のみ。
- **[MUST-2] 対応**: service_config のフォールバックを rescue 依存から「**設定後に実 start_mode を検証**」方式へ。
  `win_service`（name のみ）で設定後の start_mode を取得し、`disabled` になっていなければ manual に切替え。
  タスク失敗時の rescue→manual も併存（二重で担保）。
- **[SHOULD-3] 対応**: memory_dump に現 CrashDumpEnabled の before 取得を追加し、エビデンスを before→after に。
- **[SHOULD-4] 対応**: Firewallプロファイル名の表記をモジュール仕様（win_firewall=PascalCase /
  win_firewall_rule=小文字）とコメントで明記。混在ではなく各モジュールの正しい形式であることを補足。
- **[NIT-5] 対応**: README に「個別 test_ipv6/dump は finalize_reboot 非対象＝手動再起動、一括は site.yml」を補足。
- 構文チェック: site.yml＋対象 test OK。MUST-1 の reject ロジックは机上検証で冪等動作を確認。
status: **review**（再レビュー待ち）

#### 2026-06-30 PM 再レビュー結果: **approved（設計レビュー・条件付き）**
- MUST-1（NTP冪等化）: `reject('in', before)` の when ガード＋`is not skipped` の changed 判定で解消を確認。OK。
- MUST-2（サービスフォールバック）: 設定後に実 start_mode を取得し `disabled` 不成立なら manual 切替、
  かつ rescue→manual も併存。rescue 依存の懸念は解消。OK。
- SHOULD-3（before取得）/ SHOULD-4（大小明記）/ NIT-5（README補足）: いずれも対応確認。OK。
- 命名規則・構造・不要タスク混入なし。専用モジュール活用による冪等性確保も妥当。
- **判定: approved（設計レビュー）**。
- **条件（残必須）**: 接続環境（Hyper-Vホスト上でansible実行 等）が整い次第、**実機検証**を実施すること。
  特に (a) 冪等性2回実行で changed=false、(b) service_config の disabled→manual フォールバック実動作、
  (c) finalize_reboot が末尾で1回だけ走ること。
- **次工程**: Conductor定義（time_sync→…→finalize_reboot）の作成。必要なら基本/詳細設計書を作成し
  PM approved 後に Obsidian 登録（Playbook自体はObsidian登録しない＝既存方針）。

---

## 2026-07-07 configure_guest_network 仕様変更: VLAN廃止（オーナー指示）
- 指示: VLANは使わないことになったため、configure_guest_network のVLAN依存処理を修正。
- 方針（オーナー確認済み）: セグメント=仮想スイッチ1:1とし、vNICの特定を
  「アクセスVLAN ID一致（`Get-VMNetworkAdapterVlan`）」→「**接続先スイッチ名一致**（`Get-VMNetworkAdapter` の SwitchName）」に変更。
- 変更内容:
  - `roles/configure_guest_network/tasks/configure_guest_network.yml`:
    `segments[].vlan_id` → `segments[].switch_name` でvNIC特定。同一スイッチに複数vNICは構成不正として fail
    （1スイッチ1vNIC前提・黙って誤設定しない）。出力キー vlan_id → switch。
  - `roles/configure_guest_network/defaults/main.yml` / `group_vars/main.yml`（検証値）: segments を switch_name 方式に更新。
  - `roles/import_template_vm/defaults/main.yml`: 参考レコード構造から vlan_id を削除。
  - `README.md`: ロール一覧・注意点・group_vars例のVLAN記述をスイッチ1:1方式に書き換え。
  - `parameter-sheet-design.md`: 旧 #12「VLAN ID」削除。ネットワーク項目（#11・#16〜19）は
    segments[] 対応の再設計が必要である旨を注記（別途改訂）。
- 検証: `ansible-playbook test_configure_guest_network.yml --syntax-check` OK。実機検証は未実施（環境起動時に要実施）。
- status: 実装反映済み。**PM再レビュー対象に含めること**（set_vm_disk 再レビューと併せて）。

---

## 2026-07-10 configure_guest_network 仕様変更: gateway/ホスト名/OS分岐の削除（オーナー指示）
- 指示: `roles/configure_guest_network/tasks/configure_guest_network.yml` を以下修正。
  1. DefaultGateway追加を削除
  2. ホスト名設定を削除
  3. `OSがWindowsだったら`条件分岐を削除
- 変更内容:
  - **gateway削除**: payload収集の `gateway` フィールド、`New-NetIPAddress -DefaultGateway` 分岐、
    デフォルトルート削除処理（`Remove-NetRoute -DestinationPrefix '0.0.0.0/0'`）を除去。IPは常にgatewayなしで設定。
  - **ホスト名削除**: ゲスト内 `Rename-Computer`／`name_changed`／返却JSONの `name_changed` を除去。
    再起動タスク（旧タスク5「ホスト名変更を反映するため再起動する」）を丸ごと削除。
    エビデンス(debug)の `hostname` 行を削除。
  - **OS分岐削除**: 全タスクの `when: item.os_type == 'windows'` を除去。ヘッダ/コメントの Windows限定記述も更新。
  - タスク名を「複数セグメントのIP・ホスト名を設定する」→「複数セグメントのIPを設定する」等に整合。
- モジュール構成: win_shell/assert/debug のみで新規モジュールなし（削除のみ）→ モジュールマニュアル対応不要。
- 検証: 未実施（syntax-check・実機検証は環境起動時に要実施）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-10 configure_guest_network 追加修正: DNS削除＋win_shellコメント拡充（オーナー指示）
- 指示: (1) DNS設定も不要なので削除、(2) win_shellで長くなる箇所の処理説明コメントを増やす。
- 変更内容:
  - `tasks/configure_guest_network.yml`:
    - **DNS削除**: payload収集の `dns` フィールド、ゲスト内 `Set-DnsClientServerAddress` を除去。ヘッダの変数記載も更新。
    - **コメント拡充**: タスク1（疎通待機）とタスク2（IP設定）のwin_shell内へ、資格情報生成／PowerShell Direct疎通判定／
      MAC突き合わせの理由／JSON受け渡し／冪等性判定／エビデンス配列の各処理説明コメントを追記。
  - `group_vars/main.yml`: 検証値の各segmentから未使用の `dns` を削除。あわせて前回未反映だった `gateway`（未使用）も削除。
  - `defaults/main.yml`: コメント例から `gateway`/`dns`/ホスト名設定/「Windowsのみ」記述を削除し実装に整合。
- 補足: `os_type` は他ロールでの参照可能性があるため VAR_vm に残置。
- モジュール構成変更なし（win_shell/assert/debug）→ モジュールマニュアル対応不要。
- 検証: 未実施（syntax-check・実機検証は環境起動時に要実施）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-10 configure_guest_network 変数構造変更: 固定3LAN化（Exastro代入値自動登録対応・オーナー指示）
- 背景: Exastro Legacy Role の代入値自動登録は可変長配列が扱いにくいため、segments を固定キー構成に変更。
- 新構造（オーナー確認済み・switch名はdefaults固定マッピング方式を選択）:
  - **代入値**: `VAR_vm.segments[0]` の固定キー
    `sv_lan_ip / sv_lan_prefix / mgmt_lan_ip / mgmt_lan_prefix / bk_lan_ip / bk_lan_prefix`（サーバ/管理/バックアップの3LAN）。
  - **環境固定**: LAN種別→仮想スイッチ名は `switch_map`（defaults/main.yml。sv_lan/mgmt_lan/bk_lan）で解決。代入値ではない。
- 変更ファイル:
  - `tasks/configure_guest_network.yml`: segmentsループ廃止→固定3LANを内部リストに展開。switch_map でスイッチ名解決し
    vNICをMAC特定。prefixは[int]化。エビデンスに lan 種別を付与。win_shellの処理説明コメントは維持。
  - `defaults/main.yml`: `switch_map`（sv_lan:sw-biz / mgmt_lan:sw-mgmt / bk_lan:sw-bk ＝プレースホルダ、実環境で上書き）を追加。
    変数コメントを固定キー構成に更新。
  - `group_vars/main.yml`: 検証値を固定キー構成（segments[0]）に更新。
  - `tasks/main.yml`: include のタスク名から前回の名残「・ホスト名設定」を除去。
  - `parameter-sheet-design.md`: ネットワーク項目（#11・#16〜19）の注記を固定3LAN＋switch_map方式に更新（gateway/dns/ホスト名廃止）。
  - `README.md`: ロール一覧・実行コマンド注記・変数早見・詳細節（4箇所）を固定3LAN構造に更新。
- 補足: 各LANのスイッチ名（switch_map）は実環境値へ要差し替え。os_type は他ロール参照可能性のため残置。
- モジュール構成変更なし（win_shell/assert/debug）→ モジュールマニュアル対応不要。
- 検証: 未実施（syntax-check・実機検証は環境起動時に要実施。特に代入値prefixの型・segments[0]前提を確認）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-10 configure_guest_network: サブネットマスク設定を追加（prefix→netmask置換・オーナー指示）
- 指示: サブネットマスク設定が入っていないため追加。
- 方針（オーナー確認済み）: プレフィックス長 `*_lan_prefix` を廃止し、サブネットマスク `*_lan_netmask`（255.255.255.0形式）
  を代入値にする（置き換え）。ロール内で netmask→プレフィックス長へ変換して New-NetIPAddress に渡す。
- 新・固定キー: `sv_lan_ip / sv_lan_netmask / mgmt_lan_ip / mgmt_lan_netmask / bk_lan_ip / bk_lan_netmask`。
- 変更ファイル:
  - `tasks/configure_guest_network.yml`: PowerShell関数 `Get-PrefixFromMask` を追加（マスク→プレフィックス長変換。
    連続ビット検証・オクテット範囲検証つき。非連続/範囲外は throw）。payload・エビデンスに mask/prefix を保持。
  - `defaults/main.yml` / `group_vars/main.yml`: 変数を netmask 形式に更新（"255.255.255.0"）。
  - `parameter-sheet-design.md` / `README.md`（ロール表・変数早見・詳細節）: 固定キーを netmask 表記に更新。
- 補足: マスクは連続ビットのみ許容（例 255.0.255.0 はエラー）。switch_map はプレースホルダのまま（実環境値へ要差し替え）。
- モジュール構成変更なし（win_shell/assert/debug）→ モジュールマニュアル対応不要。
- 検証: 未実施（syntax-check・実機検証は環境起動時に要実施。代入値maskが文字列で渡ること・変換結果を確認）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-10 configure_guest_network: netmask版を1つ前（prefix版）へロールバック（オーナー指示）
- 指示: 1つ前（プレフィックス長 `*_lan_prefix` 方式）に戻す。実機 ipconfig でサブネットマスクが 0.0.0.0 となる事象の切り分けのため。
- 対応: 直前の「サブネットマスク追加（netmask置換）」を全ファイルで巻き戻し。
  - tasks（Get-PrefixFromMask削除・prefix直指定に復帰）/ defaults / group_vars / parameter-sheet-design.md / README.md。
- 事象「ipconfig でサブネットマスク 0.0.0.0」の原因分析（要実機ログ確認）:
  - マスク 0.0.0.0 は New-NetIPAddress に **-PrefixLength 0** が渡って設定された確定症状（IPは付くがマスクだけ0）。
  - prefix版は `prefix=[int]$seg.sv_lan_prefix`。代入値/変数に prefix が無い（$null）と **[int]$null=0** となり、
    例外にならず静かに 0 → PrefixLength 0 → マスク 0.0.0.0。空文字は逆に例外。
  - 実機で $null になる典型: Exastro パラメータシート/代入値自動登録に prefix 項目が未登録、または
    メンバー変数名が segments[0].sv_lan_prefix 等と不一致で、segments にキーが載っていない。
  - 確認策: タスク4のエビデンス（segments 出力）と、代入値自動登録設定のキー名・値を突き合わせる。
    group_vars（prefix:24）でのローカル検証では 24 になるはずで、そこで再現するかも切り分けに有効。
- 注意: 戻すだけでは代入値未登録が真因の場合は解消しない（prefix版でも同条件で 0.0.0.0 になる）。
- status: ロールバック反映済み。原因は代入値側の要確認事項として PM/オーナーへ共有。

---

## 2026-07-10 prefix=0 の真因確定＋解決、および Ping 片方向不通の切り分け（オーナー実機）
### prefix=0（マスク0.0.0.0）の真因 — 確定
- 実機 exec.log の `echo $seg`（Format-Table）で、$seg のプロパティが sv_lan_ip / mgmt_lan_ip / bk_lan_ip の**3つのみ**、
  prefix系が**1つも存在しない**ことを確認。ip系は値あり（10.103.0.46 等）。
- `$seg.sv_lan_prefix` が無い → `[int]$null=0` → `New-NetIPAddress -PrefixLength 0` → サブネットマスク 0.0.0.0。
- 原因: defaults/代入値のYAMLで `sv_lan_prefix` 等が `sv_lan_ip:`（値空）の配下に**ネスト**していた
  （インデントが1段深く、sv_lan_ip の値扱い）。結果 segments[0] 直下に prefix キーが載らなかった。
- **解決（オーナー実施）**: 各 prefix を segments 配列内メンバーではなく**別変数として定義**したところ正常化。
  ※ ドラフト（.company側）の tasks/defaults/group_vars は segments 内フラット定義のまま。実環境の別変数方式に合わせるかは要判断。

### 新課題: Ping 片方向不通
- 事象: 構築VM（WindowsServer）→ 他VM / Hyper-Vホスト は疎通OK。逆（他VM/ホスト → 構築VM）が**不通**。
- 原因（診断）: 構築VMの **Windowsファイアウォールがインバウンドの ICMPv4 Echo Request を拒否**（既定 inbound block）。
  行き（VM発）は戻りが確立済み扱いで通るが、帰り（VM宛の Echo Request）に VM が応答しないため片方向不通。
  設計書「6. Firewallプロファイル」既定 inbound_action=block とも整合。
- 対処案: os_config パッケージの **Firewallルール（VAR_fw_rules / windows_firewall ロール）** に
  ICMPv4 Echo Request のインバウンド許可レコードを追加（direction=in / action=allow / protocol=icmpv4）。
  ※ Echo Request限定にするなら icmp_type_code=8 相当の指定可否を windows_firewall ロールで要確認。
- 切り分け: 構築VMで一時的に FW 無効（`Set-NetFirewallProfile -All -Enabled $false`）or `Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In`
  で Ping が通れば FW 起因で確定。
- status: prefix=0 は解決。Ping はFW設定（VAR_fw_rules）での対応を提案中。

---

## 2026-07-10 import_template_vm: Dドライブ対応＋VHDXファイル名のVM名リネーム追加（オーナー指示）
- 指示: 現在Cドライブのみ構成→Dドライブ追加（C=固定/D=可変）。VHDX名をVM名、Dディスク名をVM名_dataにリネームする処理追加。
- 前提（オーナー補足）: テンプレートは C・D 両ディスクをマウント済みでエクスポート → **新規ディスク作成は不要**。
  「C=固定/D=可変」はテンプレート側のディスク形式であり、Playbookはサイズ・形式に触れない（リネームのみ）。
- 変更（tasks/import_template_vm.yml）:
  - タスク2.5「VHDXファイル名をVM名基準にリネームする（C/D）」を追加（インポート直後・after確認前）。
    - ディスクはコントローラ位置昇順で 先頭=OS(C)/2番目=データ(D) と識別。2台未満なら fail。
    - C=<VM名>.vhdx / D=<VM名>_data.vhdx。アタッチ中はリネーム不可のため
      「デタッチ→Rename-Item→同一コントローラ位置へ再アタッチ」。既に目標名ならskip（冪等）。
    - Generation2 はデタッチ/アタッチでブート順が末尾に回るため、OSディスクを FirstBootDevice に再設定。
    - VM停止中前提（本ロールは start_vm 前）。
  - ヘッダにディスク構成・リネーム規則を追記。エビデンス(debug)に disks 行を追加。
  - defaults/main.yml・README.md にディスク前提とリネーム規則を追記。
- モジュール: 追加処理は win_shell 内のPowerShell（Get/Add/Remove-VMHardDiskDrive・Rename-Item・Set-VMFirmware）。
  Ansibleモジュールは ansible.windows.win_shell のみ（既存）→ モジュールマニュアル対応不要。
- ★要確認（PM/オーナー）: set_vm_disk は現状 OSディスク(C) を os_disk_size_gb へ拡張する設計。
  「Cは固定」方針と矛盾するため、set_vm_disk の扱い（停止 or Dデータディスク拡張へ転用）を別途決める必要あり。
  また set_vm_disk は「データディスク未追加・接続先頭=OS」前提だが、D追加後も先頭=C拡張のため動作自体は継続する。
- 検証: YAML構文OK（python yaml）。syntax-check・実機は環境起動時に要実施（特にデタッチ/再アタッチ後のブート）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-10 set_vm_disk: Cドライブ拡張→Dドライブ（データディスク）拡張へ変更（オーナー指示）
- 指示: Cドライブは固定、Dドライブを可変で拡張する処理に変更。拡張後にゲストOS上でパーティション拡張も実施（C時と同様）。
- 変更（tasks/set_vm_disk.yml のみ・構造/順序/スタイルは不変。C→Dの置換に限定）:
  - ディスク特定: 接続中ディスクの先頭（OS/C）→ **2番目（データ/D）**。`Select-Object -First 1` → `-Skip 1 -First 1`
    （import_template_vm が D を2番目に配置する前提と整合）。
  - 変数: `item.os_disk_size_gb` → `item.data_disk_size_gb`、`item.os_disk_drive_letter` → `item.data_disk_drive_letter`。
  - register `os_disk` → `data_disk`。名称/コメントを OSディスク → データディスク に。
  - ゲスト内パーティション拡張（タスク6-8）は既存処理をそのまま D ドライブ対象で流用（ドライブレター駆動のため
    data_disk_drive_letter を渡すだけ）。冪等性・no_log・assert・エビデンス等のロジックは変更なし。
- ★未反映（指示範囲を set_vm_disk.yml に限定したため別途必要）:
  - 新変数 `data_disk_size_gb` / `data_disk_drive_letter` を set_vm_disk の defaults/main.yml・group_vars/main.yml に反映。
  - parameter-sheet-design.md #9「OSディスクサイズ」#10「OSドライブレター」を データディスク用（D）へ改訂。
  - ※ 上記は「勝手に触らない」方針で今回は未変更。反映要否はオーナー/PM判断。
- 補足: Cドライブ固定化に伴い、OSディスク拡張は本ロールから消滅（Cは import 時のVHDXそのまま）。
- モジュール: hv_vhd（既存）＋ win_shell（PowerShell Direct）。新規モジュールなし → モジュールマニュアル対応不要。
- 検証: YAML構文OK。syntax-check・実機は環境起動時に要実施（特に D=2番目ディスクの前提とゲスト内 D: パーティション拡張）。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-13 import_template_vm: VM起動中はVHDXリネームをスキップ（オーナー指示）
- 指示: VM情報を取得し、起動状態の場合はVHDXリネーム処理をスキップする。
- 変更（tasks/import_template_vm.yml のタスク2.5のみ・他タスクは不変）:
  - リネーム用 win_shell の冒頭で `Get-VM` によりVM情報を取得し、`State -ne 'Off'` なら
    「OK | skip: VMが起動状態のため…（State=xxx）」を出力して `exit 0`（skip扱い・エラーにしない）。
  - Running のほか Paused / Saved 等の Off 以外も同様にアタッチ中VHDXの名前変更が不可のため、
    スキップ対象は「Off 以外」で判定（起動状態の要求を包含する安全側の判定）。
  - Generation の取得を後段の `(Get-VM).Generation` 再呼び出しから、冒頭で取得した `$vmInfo.Generation` に統一。
  - changed_when は従来どおり 'CHANGED' 判定のため、skip時は changed=false（冪等表示も維持）。
  - ファイル先頭・タスク2.5のコメント（冪等性の説明）に本挙動を追記。
- 理由: 稼働中VMに対して再実行すると Remove-VMHardDiskDrive で必ず失敗するため、
  稼働中は「リネーム未実施のままskip」で安全に流し切れるようにする。
- モジュール: win_shell（既存）のみ → モジュールマニュアル対応不要。
- 検証: YAML構文OK。実機（Hyper-Vホスト）での起動中VM skip / 停止中VM rename の両パス確認は環境起動時に要実施。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-13 import_template_vm: Gen2ブート順再設定を削除（オーナー指示・実機確認に基づく）
- 指示: インポート後のファームウェアは bootmgfw.efi（OSディスクEFIパーティション上のブートマネージャ）を指す
  ファイルブートエントリでブート設定されており、不要なら Set-VMFirmware のブート順再設定を削除する。
- 変更（tasks/import_template_vm.yml のタスク2.5のみ）:
  - `if ($changed -and $gen -eq 2) { Set-VMFirmware -FirstBootDevice ... }` ブロックを削除。
  - 不要になった `$gen = $vmInfo.Generation` の取得行を削除。
  - タスク2.5コメントとスクリプト内コメントを「ブート順再設定は不要（bootmgfw.efi のファイルブートエントリが
    デタッチ→再アタッチ後も維持される・実機確認 2026-07-13）」に更新。
- 根拠: オーナーの実機確認。デタッチ→リネーム→再アタッチ後もファイルブートエントリが先頭のまま維持され、
  ドライブ再設定なしで正常起動する。
- 留意: テンプレートが変わって「ファイルブートエントリを持たない（ドライブエントリのみの）」Gen2 VMを
  インポートする運用になった場合は、本削除の前提が崩れるため再検討が必要（review-log参照のこと）。
- モジュール: 変更なし（win_shellのみ）→ モジュールマニュアル対応不要。
- 検証: YAML構文OK。次回実機実行時に「リネーム後の初回起動が正常」であることを確認。
- status: 実装反映済み。**PM再レビュー対象に含めること**。

---

## 2026-07-13 set_vm_disk: オフラインのデータディスクをオンライン化してから拡張（オーナー指示・実機事象）
- 事象: ゲスト内でデータディスクがオフライン状態（SCSIデータディスクはSANポリシー既定でオフラインになりうる）となり、
  Get-Partition に D ドライブが表示されず Update-Disk 以降が実行できない。
- 変更（tasks/set_vm_disk.yml タスク7のScriptBlockのみ）:
  - 冒頭で `Get-Partition -DriveLetter $dl -ErrorAction SilentlyContinue` により対象ドライブの可視性を確認し、
    見えない場合のみ `Get-Disk | Where IsOffline` を `Set-Disk -IsOffline $false` でオンライン化。
    読み取り専用フラグが残る場合は `Set-Disk -IsReadOnly $false` で解除（Resize-Partition に必要）。
  - ドライブが見えている場合はオンライン化処理自体を通らない（冪等）。
  - オンライン化を changed 扱いに反映（`$changed = $onlined` 初期化）し、結果JSONに `onlined` フィールドを追加。
  - タスク7のヘッダコメントに本挙動を追記。
- 留意: オンライン化対象は「オフラインの全ディスク」（対象VMはC/Dの2ディスク構成前提のため実質D固定）。
  将来3ディスク以上の構成になる場合は、対象ディスクの特定（2番目のSCSI位置基準など）に絞る見直しが必要。
- モジュール: win_shell（既存）のみ → モジュールマニュアル対応不要。
- 検証: YAML構文OK。実機での確認ポイント: ①オフラインD→オンライン化→拡張成功 ②再実行時（オンライン済み）にonlined=false でskip。
- status: 実装反映済み。**PM再レビュー対象に含めること**。
