# 題目二：SQL Server 誤刪資料的備份與還原

## 先說結論

我會把 production 先切換成受控狀態，建立 tail-log backup，然後在另一台 recovery instance 還原：週日完整備份、週三 02:00 差異備份，以及 14:37 前最後一份交易日誌備份，再用 tail-log backup 做時間點還原。最後把修復後的資料與 production 比對，只補回被誤刪的訂單，不直接用舊資料庫覆蓋 production。

## 1. 事故現場處置

下方的 `2026-09-17` 只是依本次作業檔案日期放入的示例；正式執行必須替換成事故在 production 使用的實際日期、時區、資料庫名稱與備份檔路徑。題目文字只說週三，因此不能只靠星期幾猜日期。

1. 立即停止或撤銷執行 DELETE 的帳號權限，保留 DBA、應用程式與必要監控權限。
2. 先確認資料庫名稱、伺服器時區、目前 LSN 與 backup chain。記下 14:37 與 14:52 的時區。
3. 讓應用程式暫停修改訂單，或至少把訂單寫入 queue。原因是直接把 production 還原到 14:37 會丟失 14:37 之後的正常交易。
4. 立刻取得 tail-log backup。因為資料庫仍在線，使用 `WITH NO_TRUNCATE` 搶救目前尚未被其他 log backup 保存的交易記錄。

```sql
BACKUP LOG [ShopDb]
TO DISK = N'\\BackupShare\ShopDb\incident_20260917_1437_tail.trn'
WITH NO_TRUNCATE, INIT, COMPRESSION, CHECKSUM, STATS = 10;
GO
```

如果 production 已經不允許停寫，我會先將 tail-log backup 複製到隔離儲存，再繼續處理。備份檔不能只留在 production 本機磁碟。

## 2. 還原順序

假設檔案如下：

- `ShopDb_Full_Sun_0200.bak`：週日 02:00 完整備份。
- `ShopDb_Diff_Wed_0200.bak`：週三 02:00 差異備份。
- `ShopDb_Log_Wed_1415.trn`：14:15 的交易日誌備份。
- `ShopDb_Incident_Tail.trn`：事故後取得的 tail-log backup。

在隔離 recovery instance 上先確認備份檔：

```sql
RESTORE VERIFYONLY
FROM DISK = N'\\BackupShare\ShopDb_Full_Sun_0200.bak'
WITH CHECKSUM;
GO
RESTORE VERIFYONLY
FROM DISK = N'\\BackupShare\ShopDb_Diff_Wed_0200.bak'
WITH CHECKSUM;
GO
RESTORE VERIFYONLY
FROM DISK = N'\\BackupShare\ShopDb_Log_Wed_1415.trn'
WITH CHECKSUM;
GO
```

先取得 logical file name，再依 recovery instance 的路徑執行：

```sql
RESTORE FILELISTONLY
FROM DISK = N'\\BackupShare\ShopDb_Full_Sun_0200.bak';
GO

RESTORE DATABASE [ShopDb_Recovery]
FROM DISK = N'\\BackupShare\ShopDb_Full_Sun_0200.bak'
WITH
    MOVE N'ShopDb'     TO N'D:\SQLData\ShopDb_Recovery.mdf',
    MOVE N'ShopDb_log' TO N'E:\SQLLog\ShopDb_Recovery_log.ldf',
    NORECOVERY,
    CHECKSUM,
    STATS = 10;
GO

RESTORE DATABASE [ShopDb_Recovery]
FROM DISK = N'\\BackupShare\ShopDb_Diff_Wed_0200.bak'
WITH NORECOVERY, CHECKSUM, STATS = 10;
GO
```

接下來依照 `msdb.dbo.backupset` 與 `backupmediafamily` 確認所有 log backup 的連續順序。不要只依檔名排序；要確認 `first_lsn`、`last_lsn` 與 `database_backup_lsn`。

```sql
SELECT
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.type,
    bs.first_lsn,
    bs.last_lsn,
    bs.database_backup_lsn,
    bmf.physical_device_name
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediafamily AS bmf
  ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = N'ShopDb'
ORDER BY bs.backup_start_date;
```

在本案例，依序套用週三 02:15、02:30……14:15 的所有交易日誌備份。若 14:30 備份已成功完成，也應套用 14:30 的檔案，但在下一步以時間點停止。每一份中間 log 都要 `NORECOVERY`：

```sql
RESTORE LOG [ShopDb_Recovery]
FROM DISK = N'\\BackupShare\ShopDb_Log_Wed_0215.trn'
WITH NORECOVERY, CHECKSUM, STATS = 10;
GO

-- 依實際 backup chain 繼續執行每一份 log backup。
RESTORE LOG [ShopDb_Recovery]
FROM DISK = N'\\BackupShare\ShopDb_Log_Wed_1430.trn'
WITH NORECOVERY, CHECKSUM, STATS = 10;
GO
```

最後套用事故後取得的 tail-log backup，並設定 STOPAT 在 DELETE 交易之前的安全時間。題目只給 14:37，實務上應從 log 檢視精確 transaction 時間與 LSN，最好使用 DELETE transaction 開始前一個已提交的時間點：

```sql
RESTORE LOG [ShopDb_Recovery]
FROM DISK = N'\\BackupShare\ShopDb\incident_20260917_1437_tail.trn'
WITH
    STOPAT = '2026-09-17T14:36:59.997',
    RECOVERY,
    CHECKSUM,
    STATS = 10;
GO
```

如果已精確找到 DELETE 所在交易的 LSN，應以 `STOPBEFOREMARK` 的 transaction mark 或更精確的 stop position 流程執行，並先在測試 instance 演練。只用毫秒時間不是精確切交易邊界的最佳方式。

## 3. 最多可還原到哪一個時間點

在 tail-log backup 成功、log chain 完整且 DELETE transaction 可以被定位的前提下，最多可以還原到 **誤刪 DELETE transaction 之前最後一個已提交交易的時間點**。用題目提供的時間來說，應是 14:37 之前，而不是 14:52。

原因是 14:37 之後的 transaction log 同時包含錯誤 DELETE 與其他會員正常下單、付款的交易。若還原到 14:52，DELETE 會被一併重播；若停在 14:37 之前，則可以排除 DELETE，但仍可能需要補回 14:37 前後邊界的正常交易。

## 4. 14:37 之後正常交易如何處理

直接把 `ShopDb_Recovery` 覆蓋 production 會影響 14:37 之後的合法交易，因此不這樣做。我會：

1. 將 recovery database 設成唯讀，只允許 DBA 讀取。
2. 比對 recovery database 與 production 的訂單主表、明細、付款和狀態歷程。
3. 產生「recovery 有、production 沒有」的清單，這就是優先補回的資料。
4. 對 production 在 14:37 後已有付款或出貨更新的同一筆訂單，不用舊資料直接覆蓋；以訂單事件時間和業務規則合併。
5. 暫停會修改該批訂單的 worker，在短交易中補回資料，再執行對帳。
6. 所有補回、跳過與人工決策都寫入 audit log。

如果錯誤 DELETE 的範圍可以可靠地重建，通常比整庫 failover 更適合做資料級修復。若 production 已無法繼續服務，再評估用 recovery database failover，但要同時重播 14:37 後合法交易。

## 5. 事故後改善

我會把備份檔的每日異地同步改成接近即時的 off-host copy，為 full、differential、log backup 建立監控，並定期做 restore drill。每份備份都使用 `CHECKSUM`，且定期用 `RESTORE VERIFYONLY` 和實際還原驗證。備份成功不代表災難復原成功，必須量測 RPO、RTO 與 log chain 完整性。
