## 目標環境

- SQL Server 2019+（Developer、Express 或一般 Edition 均可）
- T-SQL
- 題目二使用 `FULL recovery model`
- 題目五使用 SQL Server Database Project (`.sqlproj`)

## 目錄

- `docs/assignment.md`：五題完整作答與設計理由。
- `sql/01_schema.sql`：題目一資料表、分區函數、分區配置與索引。
- `ops/02_backup_restore.md`：題目二 Full / Differential / Transaction Log / Tail-log 還原步驟。
- `sql/03_procedure.sql`：題目三程序改寫與索引。
- `sql/04_concurrency.sql`：題目四重複清理、唯一索引與安全寫入程序。
- `sql/05_add_invoice_no.sql`：題目五新增發票號碼 migration。
- `DatabaseProject/DatabaseProject.sqlproj`：SQL Server Database Project。
- `DatabaseProject/SchemaObjects/`：版控中的表與 stored procedure 檔案。

## 執行方式

先在 SQL Server 建立作業用 database，切換到該 database 後執行：

```text
sqlcmd -S <server> -d <database> -E -i sql/01_schema.sql
sqlcmd -S <server> -d <database> -E -i sql/03_procedure.sql
sqlcmd -S <server> -d <database> -E -i sql/04_concurrency.sql
```

題目二是操作 runbook，不要在 production 直接照範例路徑執行，必須先換成實際備份檔、logical file name、資料庫名稱與 restore instance 路徑。

如果使用 SSDT 或 sqlpackage，從 `DatabaseProject/DatabaseProject.sqlproj` build DACPAC，再產生 deployment script。正式環境先 review script，不要直接接受自動產生的 destructive change。

## 本地驗證限制

本 sandbox 沒有 SQL Server、SSDT 或 sqlpackage，因此本次只完成檔案與 Git 版本控制，沒有宣稱已在 SQL Server instance 實際執行。交付前應在 SQL Server Developer / Express 或 CI runner 做 build、deploy 到測試 database、執行 smoke test，並檢查分區、索引、foreign key 與 stored procedure。

## Git 變更

題目五的 `InvoiceNo` 變更會由 Git commit 歷史表達：

1. 初始 commit：建立 SQL Server schema 與 Database Project，`Orders.sql` 尚未有 `InvoiceNo`。
2. 第二個 commit：新增 `InvoiceNo` 到 `Orders.sql`，並加入 `sql/05_add_invoice_no.sql`。
3. 後續 commit：修正文檔與 T-SQL 細節。
