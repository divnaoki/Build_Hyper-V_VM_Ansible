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
