---
project: hyperv-vm-build
status: review
created: 2026-06-25
ref_repo: https://github.com/divnaoki/ExastroWork/tree/main/packages/vm_build
---

# Hyper-V 仮想マシン構築 - CPU/メモリ/ディスク設定 実装ノート

## 依頼内容
テンプレートVHDからのインポート（`import_template_vm`）実装済みを前提に、以下を実装。
- CPU設定 / メモリ設定（動的メモリ）/ Disk設定
- ルール: `<処理名>.yml` に実行タスク、`main.yml` が `include_tasks`、変数は `defaults/main.yml`

## 実装結果サマリ

| 項目 | ロール | 状況 |
|------|--------|------|
| CPU設定 | `set_vm_cpu` | **既存・実装済み**（`microsoft.hyperv.hv_processor`、前後取得あり、ルール準拠）。変更不要 |
| メモリ設定（動的メモリ） | `set_vm_memory` | **既存・実装済み**（`microsoft.hyperv.hv_memory`、動的/静的分岐、前後取得あり、ルール準拠）。変更不要 |
| Disk設定 | `set_vm_disk` | **今回新規作成**（OS VHDX拡張＋ゲスト内パーティション拡張） |

> CPU/メモリは既にリポジトリ上で完成しており、指定ルールにも準拠していたため再実装は不要と判断。
> 実質の新規作業は `set_vm_disk` のみ。

## set_vm_disk の設計（新規）

### ファイル構成（指定ルール準拠）
```
roles/set_vm_disk/
├── tasks/
│   ├── main.yml            # set_vm_disk.yml を include_tasks するだけ
│   └── set_vm_disk.yml     # 実行タスク本体
└── defaults/
    └── main.yml            # VAR_vm（新規メンバー os_disk_size_gb / os_disk_drive_letter を文書化）
```

### 処理フロー（item ごと・loop: VAR_vm）
1. before: ホスト側 `Get-VHD` で現VHDXサイズ(GB)取得（read-only）
2. ホスト: 目標 > 現サイズ のときのみ `Resize-VHD`（オンライン拡張・冪等）
3. ゲスト: Windowsのみ PowerShell Direct で `Resize-Partition` を SizeMax まで（冪等・no_log）
4. after: VHDXサイズ(GB)再取得
5. assert: VHDX >= 目標サイズ
6. debug: 前後差分＋ゲスト拡張結果のエビデンス

### 設計判断（レビュー観点）
- **配置位置**: Conductor で `start_vm` の**後ろ**。ゲスト内パーティション拡張にVM起動が必須なため。
  既存の「HW設定はVM停止中」原則の意図的な例外。
- **オンラインResize前提**: OS(ブート)ディスクは **Generation2 / SCSI接続** 前提。
  → 要確認: テンプレートがGen1/IDEの場合はオンライン拡張不可。その場合は `start_vm` 前にVHDX拡張を分離する設計に変更が必要。
- **接続方式**: ゲスト内拡張は **PowerShell Direct**（`Invoke-Command -VMName`）。ゲストNW非依存で、
  既存ロールと同じ「ホストへの単一WinRM接続」を維持。
- **OS種別**: ゲスト内拡張は **Windowsのみ**（`configure_vm_network` がWindows専用なのに合わせる）。
  RHELはVHDX拡張のみ実施しゲスト内はスキップ。→ RHELもゲスト内拡張が必要なら growpart/xfs_growfs 対応を追加実装する。
- **冪等性**: 拡張のみ（縮小しない）。目標<=現サイズなら no-op。
- **機密**: ゲストパスワードを使うタスクは `no_log: true`。

## Conductor への組み込み（未反映・要対応）
現行 `conductor_A_vm_build`（7ロール）の末尾に `set_vm_disk` を追加する。

```
... A6 enable_time_sync --> A7 start_vm --> A8 set_vm_disk --> 終了
```

Mermaid追記イメージ:
```
  A7 --> A8["set_vm_disk<br/>pkg: vm_build / 対象: 全VM<br/>OSディスク拡張(VHDX+ゲスト内)"]
  A8 --> E((終了))
```
> CPU/メモリは A2/A3 に既存のため変更なし。

## パラメータシート追加項目（VAR_vm）
| メンバー | 例 | 説明 |
|----------|----|------|
| `os_disk_size_gb` | 100 | OSディスク目標サイズ(GB)。現サイズ未満のときのみ拡張 |
| `os_disk_drive_letter` | "C" | ゲスト内拡張対象ドライブ（Windowsのみ） |

## 残課題 / PMへの確認事項
- [ ] テンプレートVMの世代（Gen2/SCSI）確認 → オンラインResize可否の確定
- [ ] RHELゲストのOSディスク拡張要否（要ならLinux側拡張タスク追加）
- [ ] Conductor定義・パラメータシート定義への反映（exastro-designerのconductor/param-assignサブエージェント）
- [ ] 動作確認環境での冪等性テスト（2回実行でchanged=falseになること）
