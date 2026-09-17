/* 題目四：同一會員對同一活動只能報名一次
   Target: SQL Server 2019+
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

/* 先盤點現有重複資料。正式環境要先備份並由產品確認保留規則。 */
SELECT
    MemberId,
    EventId,
    COUNT_BIG(*) AS DuplicateCount,
    MIN(JoinedAt) AS FirstJoinedAt,
    MAX(JoinedAt) AS LastJoinedAt
FROM dbo.EventJoin
GROUP BY MemberId, EventId
HAVING COUNT_BIG(*) > 1;
GO

/* 範例清理策略：每組保留最早加入的資料；同時間保留 JoinId 較小者。 */
;WITH Ranked AS
(
    SELECT
        JoinId,
        ROW_NUMBER() OVER
        (
            PARTITION BY MemberId, EventId
            ORDER BY JoinedAt ASC, JoinId ASC
        ) AS RowNo
    FROM dbo.EventJoin
)
DELETE ej
FROM dbo.EventJoin AS ej
INNER JOIN Ranked AS r
    ON r.JoinId = ej.JoinId
WHERE r.RowNo > 1;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.EventJoin')
      AND name = N'UX_EventJoin_MemberId_EventId'
)
BEGIN
    CREATE UNIQUE INDEX UX_EventJoin_MemberId_EventId
        ON dbo.EventJoin (MemberId, EventId);
END;
GO

/* 建議的寫入方式：直接 INSERT，把唯一索引當成資料庫層的最終防線。
   應用程式可捕捉 2601/2627，將它轉成「已報名」的業務回應。 */
CREATE OR ALTER PROCEDURE dbo.usp_JoinEvent
    @MemberId bigint,
    @EventId  int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        INSERT INTO dbo.EventJoin (MemberId, EventId, JoinedAt)
        VALUES (@MemberId, @EventId, SYSUTCDATETIME());
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            -- 已存在時不重複新增；正式程式應回傳既有報名結果。
            RETURN;
        END;
        THROW;
    END CATCH;
END;
GO
GO
