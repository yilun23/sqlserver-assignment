# DBA 面試前作業：SQL Server / T-SQL 版本

**作答角度：大學剛畢業、正在學習 DBA 的新手**  
**目標環境：SQL Server 2019+，含 Developer / Express 可用的 T-SQL 語法**

## 0. 說明

這一份是依原始作業規範完成的 **SQL Server/T-SQL 版本**。前一份 MySQL 版本是因為先前曾指定 MySQL 8.0.46；本版本則改回題目原本要求的 SQL Server、`FULL recovery model`、差異備份與 Database Project。

SQL Server 的完整建置腳本放在 `sql/01_schema.sql`，題目二的操作文件放在 `ops/02_backup_restore.md`，題目三和題目四的 T-SQL 分別放在 `sql/03_procedure.sql`、`sql/04_concurrency.sql`。題目五使用 `DatabaseProject/DatabaseProject.sqlproj`，其表結構以檔案保存。

---

# 題目一　訂單相關資料表設計

## 1.1 整體設計

我建立 `Members`、`Products`、`Orders`、`OrderItems`、`OrderStatusHistory` 與 `Payments` 六張表。`Orders` 是主要交易表，每天約 8 萬筆，因此以 `CreatedAt` 做每月 RANGE RIGHT 分區。訂單保留三年，三年以前的資料會先封存，確認封存成功後再以分區操作移除。

## 1.2 資料型別與欄位決定

| 欄位類型 | 選擇 | 理由 |
| --- | --- | --- |
| ID | `bigint IDENTITY` | 目前每日 8 萬筆，長期累積後使用 `int` 可能接近上限。`bigint` 的空間成本可以接受。 |
| 業務編號 | `varchar` | 訂單編號、會員編號與 SKU 是業務識別值，不應假設只能是數字。 |
| 姓名與地址 | `nvarchar` | 需要支援中文與其他 Unicode 字元。 |
| 密碼 | `varbinary(64)` | 只保存 hash 結果，不保存明文密碼。實際雜湊演算法由應用程式決定。 |
| 金額 | `decimal(12,2)` | 金錢不使用 `float`，避免浮點誤差。 |
| 狀態與代碼 | `tinyint` | 狀態值範圍小，搭配 CHECK constraint 限制合法值。 |
| 時間 | `datetime2(0)` | 精度足以支援訂單與狀態時間，資料庫統一保存 UTC。若公司要求更高精度，可改成 `datetime2(3)`。 |
| 商品快照 | `OrderItems` 保存 SKU、名稱、單價 | 商品日後可能改名或改價，歷史訂單需要保留下單當時的內容。 |

`Orders.Status` 使用 1 待付款、2 已付款、3 已出貨、4 已完成、9 已取消。重要時間放在 `PaidAt`、`ShippedAt`、`CompletedAt` 與 `CancelledAt`。`OrderStatusHistory` 再保存每一次狀態變動，方便稽核與客訴查詢。

## 1.3 分區鍵與分區粒度

我選 `Orders.CreatedAt` 作為分區鍵，因為日常查詢包含近三個月訂單、指定日期對帳和每月報表。這些條件都會帶日期範圍，分區可以減少需要讀取的資料。

我選每月一個分區，而不是每日分區。每天 8 萬筆，平均每月約 240 萬筆；每月粒度可以讓三個月查詢只讀取幾個分區，也讓三年只需維護約 36 至 37 個主要分區。每日分區雖然更細，但三年會超過一千個分區，管理成本較高。每季分區又可能使單一分區太大，歸檔和維護單位太粗。

SQL Server 分區表有一個重要限制：**分區唯一索引通常必須把分區鍵納入唯一鍵**。因此 `Orders` 的 clustered primary key 設計為 `(OrderId, CreatedAt)`，並放在 `PS_OrderCreatedAt_Monthly` 分區配置上。為了讓其他表仍可以用單欄 `OrderId` 建立外鍵，我另外建立不分區的 `UQ_Orders_OrderId (OrderId)`。訂單編號的全域唯一性則由不分區的 `UQ_Orders_OrderNo (OrderNo)` 保證。

## 1.4 對應日常操作

1. **會員近三個月訂單列表：** 使用 `MemberId` 加 `CreatedAt >= @StartDate AND CreatedAt < @EndDate`，搭配 `IX_Orders_Member_CreatedAt`。半開區間可以避免結束時間含不含整天的混淆。
2. **客服訂單編號查詢：** 使用 `UQ_Orders_OrderNo`。
3. **每日對帳：** 以 `CreatedAt` 或 `PaidAt` 的日期條件搭配 `Status = 2`，彙總 `TotalAmount`。正式上線後應以實際執行計畫決定是否再加對帳專用索引。
4. **月報：** 以月份範圍查詢，SQL Server optimizer 有機會進行 partition elimination。
5. **金流與物流更新：** 用 `OrderId` 對單筆資料更新狀態與對應時間，再在同一短交易中寫入 `OrderStatusHistory`。

## 1.5 分區保留與維護

我會在每月維運工作中提前建立下一個月份的 boundary，避免新月份資料落入未來分區或因沒有對應分區而寫入失敗。保留期滿時流程如下：

1. 先將即將到期分區資料切換到 archive table，或使用備份檔封存。要驗證筆數、checksum、訂單明細、付款與狀態歷程是否完整。
2. 確認稽核保存政策允許移除。
3. 使用 `ALTER TABLE ... SWITCH PARTITION` 做快速資料移轉，或在維護窗口以 `ALTER PARTITION FUNCTION ... MERGE RANGE` 移除 boundary。分區 switch 前，來源與目標表的結構、索引與 CHECK constraint 必須相容。
4. 保留 archive 的查詢與還原方式，不能只把資料丟到檔案後就沒有辦法調閱。

我不會直接對 8,000 萬筆訂單執行長時間的 `DELETE WHERE CreatedAt < ...`，因為這會產生大量 log、鎖定與交易記錄。分區操作的目標是把大批資料變成可管理的邊界操作。

## 1.6 我刻意沒有做的事

- **沒有做每日分區：** 三年會有超過一千個分區，維護與管理成本高。
- **沒有一開始做分區子分區：** 題目查詢主要依時間，先用月份分區。子分區需用壓測證明必要性。
- **沒有把每個欄位都建立索引：** 索引會增加 INSERT 與狀態 UPDATE 的成本，也增加備份和磁碟使用量。
- **沒有用 trigger 自動寫完整狀態歷程：** trigger 容易讓寫入副作用不明顯。初版由應用程式在同一交易中更新主表並新增歷程；若公司規範使用 trigger，會另做壓測與失敗測試。
- **沒有讓 `OrderItems` 也使用複雜分區：** 題目明確要求訂單表分區，明細表先以 `OrderId` 索引支援點查。若明細表也需要大量歸檔，第二階段再依 `CreatedAt` 複製分區策略。
- **沒有把取消訂單刪除：** `Cancelled` 是業務狀態，取消訂單仍需保留給客服、對帳與稽核。
- **沒有做讀寫分離或分庫分表：** 這些要等壓測、RTO/RPO 與成本目標確定後再決定。

## 1.7 AI 使用、我的修改與不確定處

我使用 AI 協助整理資料表候選欄位、分區粒度與查詢索引。我自己改成 SQL Server 分區唯一索引可執行的形式：clustered primary key 使用 `(OrderId, CreatedAt)`，再用不分區唯一索引讓其他表仍可用 `OrderId` 外鍵參照。我也否決逐筆刪除三年以前資料的作法。

我目前不確定公司對訂單、付款與發票資料的法定保存年限，也不確定資料庫是否有獨立 filegroup 和儲存設備。正式設計前要和法務、財務及基礎設施團隊確認。

---

# 題目二　備份與還原

## 2.1 還原順序

原題明確指定 recovery model 是 `FULL`，備份順序為週日完整、週一至週六差異、每日每 15 分鐘交易日誌。我的順序是：

1. 先限制危險權限並停止或排隊訂單寫入。
2. 建立 tail-log backup，保存事故發生前後最後一段 transaction log。
3. 在隔離 recovery instance 還原週日完整備份，使用 `NORECOVERY`。
4. 還原週三 02:00 差異備份，使用 `NORECOVERY`。
5. 按 transaction log chain 依序還原週三 02:15 至事故前可用的 log backup，全部使用 `NORECOVERY`。
6. 最後還原 tail-log backup，使用 `STOPAT` 停在誤刪 DELETE transaction 之前，並使用 `RECOVERY`。
7. 驗證訂單主表、明細、付款與狀態歷程，再把需要的資料補回 production。

不能只依檔案名稱排序，必須查 `msdb.dbo.backupset` 的 `first_lsn`、`last_lsn` 與 `database_backup_lsn`，確保 backup chain 連續。完整執行命令在 `ops/02_backup_restore.md`。

## 2.2 最多可以還原到哪一個時間點

若 tail-log backup 成功且 log chain 完整，最多可以還原到 **14:37 誤刪 transaction 之前最後一個已提交 transaction 的時間點**。不應還原到 14:52，因為 14:37 到 14:52 的 log 中包含錯誤 DELETE。

題目說每 15 分鐘備份一次，但這不保證 14:37 的所有 log 都已成功寫到異地。實務上還要確認 backup job 狀態、檔案 checksum 和是否有缺少的 log backup。

## 2.3 會不會影響 14:37 後正常交易

如果直接用 recovery database 覆蓋 production，會影響。14:37 後其他會員的正常下單與付款也會被倒退。因此我不會直接覆蓋，而會把 recovery database 當成修復來源：以 OrderId、OrderNo、更新時間比對差異，只補回 production 遺失的訂單及其相關資料。若同一筆訂單在 production 已有合法付款或出貨更新，不能用舊版本無條件覆蓋。

## 2.4 AI 使用、我的修改與不確定處

我使用 AI 協助整理 SQL Server 的 full、differential、transaction log、tail-log 還原順序。我自己把「直接 restore 回 production」否決掉，改成隔離 instance 加資料級修復，因為題目特別說 14:37 後仍有正常寫入。

我目前不確定的是備份檔的實際名稱、資料庫是否有 TDE、是否使用 AG/replication，以及 DELETE 是否還能用 transaction mark 精確定位。正式事故時要以 `RESTORE HEADERONLY`、`RESTORE FILELISTONLY`、`msdb` 記錄和現場監控為準。

---

# 題目三　預存程序檢視與改寫

## 3.1 問題與影響排序

### 第一名：日期欄位被函數包住

原程序使用：

```sql
CONVERT(VARCHAR(10), CreatedAt, 120) >= @StartDate
```

這讓 `CreatedAt` 變成運算式。即使有適合的索引，SQL Server 也可能無法直接用 seek 找到日期範圍，只能先掃描再轉換與比較。在 8,000 萬筆資料上，CPU、I/O 和 query duration 都可能很高，還會讓其他查詢等待。因此我把它排第一。

### 其他問題

2. 原程序先把所有會員的日期範圍資料 `SELECT INTO #tmp`，再刪除不是該會員的資料，做了大量無效讀取與 temporary table 寫入。
3. `Orders` 沒有 `MemberId + CreatedAt` 索引，現有主鍵不足以支援主要查詢。
4. 整個 SELECT、temporary table 及 `LastQueryAt` 更新被包在 transaction 內，查詢慢時 transaction 也變長，可能增加鎖等待。
5. `NOLOCK` 可能讀到 dirty read、重複資料或漏資料，不能拿來取代正確的隔離設計。
6. `@MemberId` 是 `varchar(20)`，但欄位是 `bigint`，可能造成隱式轉換與錯誤輸入。
7. 日期參數是字串，且用包含式日期比較，格式與結束日語意不清楚。
8. `CHARINDEX` 解析狀態字串會發生部分匹配，例如狀態 1 可能誤匹配 10。
9. `SELECT *` 會傳送不必要欄位，未來新增欄位也會改變結果集。
10. 宣告了未使用的 `@sql`，且沒有 `TRY/CATCH` 或 rollback 保護。

## 3.2 改寫重點

改寫版在 `sql/03_procedure.sql`，主要做以下事情：

- 參數改成 `bigint` 與 `datetime2(0)`。
- 使用 `CreatedAt >= @StartDate AND CreatedAt < @EndDate` 半開區間。
- 直接在 `Orders` 上用 `MemberId`、日期與狀態篩選，不建立全會員 temporary table。
- 用 `STRING_SPLIT` 加 `TRY_CONVERT` 精確解析狀態值。
- 移除 `NOLOCK`。
- 列出明確欄位，不使用 `SELECT *`。
- 不把長時間 SELECT 和 `LastQueryAt` 更新包成一個 transaction。

## 3.3 索引

```sql
CREATE INDEX IX_Orders_MemberId_CreatedAt
ON dbo.Orders (MemberId, CreatedAt DESC, OrderId DESC)
INCLUDE (OrderNo, Status, TotalAmount, PaidAt, ShippedAt,
         CompletedAt, CancelledAt, UpdatedAt);
```

這個索引先用會員 ID 定位，再用建立時間做範圍與排序。`OrderId` 作為同時間的穩定排序鍵。INCLUDE 欄位是查詢常需要的欄位，可減少回主表次數，但實際 INCLUDE 清單仍要依 Query Store 與 workload 調整。

## 3.4 驗證是否改善

我會建立和 production 接近的資料量與資料分布，並用同一組 member、日期、狀態參數比較舊版和新版。先確認兩版結果筆數和內容一致，再比較：

| 指標 | 測量方法 | 比較數字 |
| --- | --- | --- |
| 延遲 | Query Store、Extended Events 或執行器的 duration | 舊版與新版 p50、p95、p99 |
| CPU | Query Store 的 total / average CPU time | 同一 workload 下的平均 CPU |
| logical reads | `SET STATISTICS IO ON` | 舊版與新版 logical reads |
| 執行計畫 | Actual Execution Plan、Live Query Statistics | 舊版 scan 與新版 index seek/range scan |
| rows examined | Actual plan 的 rows read / rows returned | 新版應接近單一會員實際資料量 |
| 鎖等待 | `sys.dm_exec_requests`、`sys.dm_os_waiting_tasks`、Extended Events | 查詢期間的 LCK  等待時間 |

我最重視兩組數字：第一是相同參數下的 **p95 duration**，第二是 `STATISTICS IO` 的 **logical reads**。另外要進行併發測試，確認寫入尖峰下沒有因更新 `Members.LastQueryAt` 造成新的等待。

## 3.5 AI 使用、我的修改與不確定處

我使用 AI 協助列出原程序可能造成效能和一致性問題。我自己把函數包住日期欄位列為第一名，因為它直接破壞日期範圍的搜尋能力；也否決把 `NOLOCK` 當成效能解法。我保留 `LastQueryAt` 行為，但註明若只是分析用途，應改為非同步事件。

我目前不確定 production 的實際查詢分布、Query Store 是否開啟、`LastQueryAt` 是否被其他程式使用。因此索引需要在 staging 壓測和 production 觀測後再確認。

---

# 題目四　並發下的資料一致性

## 4.1 兩個請求會發生什麼

原本的邏輯是先 `IF NOT EXISTS`，再 `INSERT`，這不是原子操作。兩個連線可能依序發生：

1. 連線 A 查詢 `(MemberId, EventId)`，找不到資料。
2. 連線 B 幾乎同時查詢同一組條件，也找不到資料。
3. A 執行 INSERT，成功。
4. B 執行 INSERT，也成功，因為表上沒有唯一約束。
5. 表中最後有兩筆相同會員、相同活動的報名資料。

即使應用程式把兩句放進 transaction，如果沒有資料庫唯一索引或適當的鎖，也不能把「查不到」變成其他連線不可插入。

## 4.2 責任應放在哪一層

「同一會員對同一活動只能報名一次」是資料模型的不變條件，最終責任應放在資料庫：

```sql
CREATE UNIQUE INDEX UX_EventJoin_MemberId_EventId
ON dbo.EventJoin (MemberId, EventId);
```

應用程式可以先查詢來改善訊息，但不能把先查後寫當成唯一保護。資料庫唯一索引會保護 API、批次工作、客服工具等所有寫入路徑。

## 4.3 已存在重複資料時

1. 先備份並在 staging 演練。
2. 用 `GROUP BY MemberId, EventId HAVING COUNT(*) > 1` 找出重複群組。
3. 和產品確認保留規則。沒有其他規則時，我在腳本中保留最早 `JoinedAt`，同時間保留 `JoinId` 較小者。
4. 使用 `ROW_NUMBER()` 列出要刪除的資料，最好先寫入 audit table。
5. 確認沒有重複後才建立唯一索引。
6. 將應用程式改成直接 INSERT，捕捉 SQL Server 2601 或 2627，轉成「已報名」業務結果。

## 4.4 AI 使用、我的修改與不確定處

我使用 AI 協助模擬兩個連線的交錯順序，並整理 duplicate cleanup 和 unique index 的 T-SQL。我自己把唯一索引放在資料庫層，並保留應用程式錯誤轉換只作為使用者體驗。

我目前不確定重複資料真正應保留哪一筆，因為這是產品規則，不是 DBA 可以自行決定的技術細節。腳本中的保留最早一筆是需要業務確認前的示例。

---

# 題目五　資料庫結構版本控制

## 5.1 Repository 設計

我使用 SQL Server Database Project 的 `.sqlproj`，並把表與 stored procedure 以獨立 `.sql` 檔放入 Git：

- `DatabaseProject/DatabaseProject.sqlproj`
- `DatabaseProject/SchemaObjects/Tables/Members.sql`
- `DatabaseProject/SchemaObjects/Tables/Orders.sql`
- `DatabaseProject/SchemaObjects/Tables/EventJoin.sql`
- `DatabaseProject/SchemaObjects/StoredProcedures/usp_GetMemberOrders.sql`
- `DatabaseProject/SchemaObjects/StoredProcedures/usp_JoinEvent.sql`
- `sql/05_add_invoice_no.sql`

資料庫結構不應只存在某台 DBA 電腦的 SSMS script 中；檔案進 Git 後可以 code review、比較版本，並由 CI 使用 `sqlpackage` build 或產出 deployment script。

## 5.2 發票號碼欄位的變更

題目要求新增發票號碼。我會新增：

```sql
ALTER TABLE dbo.Orders
ADD InvoiceNo varchar(30) NULL;
```

先允許 NULL，是因為既有訂單可能還沒有發票。應用程式先以 backward-compatible 方式部署，之後才依財務規則回填。若未來確認發票號碼有全域唯一性，另外建立索引前要先確認既有資料沒有重複。

## 5.3 套用到 production 的方式

1. 建立變更單，寫清楚欄位用途、資料型別、NULL 規則、預計影響與 rollback 方案。
2. 在開發環境、staging、production clone 先 build `.sqlproj`，再用 `sqlpackage /Action:Script` 產生 deployment script。
3. 人工 review script，確認沒有意外 DROP、資料轉換或整表重建。
4. 在低流量時段執行，監控 schema lock、執行時間、CPU、log usage 與 AG/replication lag。
5. 先部署可以讀取新欄位但不要求它一定有值的應用程式，再於後續 migration 回填。
6. 驗證 `sys.columns`、smoke test、應用程式錯誤率與 replication。
7. 將實際 deployment script、執行者、時間、版本與結果存入變更紀錄。

## 5.4 自動 diff 可能做出不希望的事

schema compare 只知道結構，不知道資料價值。以下情況一定要人工 review：

- 將欄位改名誤判成 DROP 舊欄位加 ADD 新欄位，造成原資料遺失。
- 欄位型別或長度縮小，觸發截斷或轉換錯誤。
- 為了重建索引或分區，產生長時間 table rebuild、schema lock 或大量 transaction log。
- 自動刪除工具認為多餘的 index、constraint、partition 或 stored procedure。
- 新增 NOT NULL 欄位沒有合理 default。
- 變更 unique constraint、外鍵或分區鍵，導致既有資料不符合或需要長時間驗證。
- 在 production 直接產生 destructive script，例如 `DROP TABLE`、`DROP COLUMN`、`TRUNCATE`。

我會先讓工具產生候選 script，再做 code review、staging restore / deploy、實際資料檢查與正式變更審批。

## 5.5 AI 使用、我的修改與不確定處

我使用 AI 協助規劃 `.sqlproj` 目錄、migration 流程及 schema diff 的風險。我自己按照題目要求使用 SQL Server Database Project，而不是沿用前一份 MySQL 的版本控制方式。我也把 `InvoiceNo` 先設成 nullable，沒有在同一次變更自動刪欄位或回填，因為發票編號規則尚未確定。

我目前不確定公司使用 Visual Studio SSDT、sqlpackage、DACPAC pipeline，還是其他 migration 工具。這不影響 schema 檔案可以進 Git，但正式 CI/CD 的參數、權限與審批要依公司流程調整。

---

# 附錄：建置與交付檔案

```text
sql/01_schema.sql                         題目一完整 T-SQL
ops/02_backup_restore.md                  題目二還原 runbook
sql/03_procedure.sql                      題目三 procedure 與索引
sql/04_concurrency.sql                    題目四清理、唯一索引與寫入 procedure
DatabaseProject/DatabaseProject.sqlproj  題目五 SQL Server Database Project
DatabaseProject/SchemaObjects/            版控中的表與程序
sql/05_add_invoice_no.sql                 題目五新增欄位 migration
```

由於本 sandbox 沒有安裝 SQL Server、SSDT 或 `sqlpackage`，我沒有宣稱已在 SQL Server instance 執行成功。交付前應由面試者在 SQL Server Developer / Express 或 CI runner 執行建置與 smoke test；報告中的 T-SQL 已依 SQL Server 語法與題目條件編寫。

# References

[1]: https://learn.microsoft.com/sql/relational-databases/partitions/partitioned-tables-and-indexes "Microsoft Learn: Partitioned Tables and Indexes"
[2]: https://learn.microsoft.com/sql/relational-databases/backup-restore/restore-and-recovery-overview-sql-server "Microsoft Learn: Restore and Recovery Overview"
[3]: https://learn.microsoft.com/sql/relational-databases/backup-restore/recover-to-a-point-in-time-sql-server "Microsoft Learn: Recover to a Point in Time"
[4]: https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-who-transact-sql "Microsoft Learn: sp_who (Transact-SQL)"
[5]: https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store "Microsoft Learn: Monitoring Performance by Using the Query Store"
[6]: https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage "Microsoft Learn: SqlPackage"
