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
