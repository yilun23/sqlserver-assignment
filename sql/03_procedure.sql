/* 題目三：usp_GetMemberOrders 改寫版
   Target: SQL Server 2019+
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Orders')
      AND name = N'IX_Orders_MemberId_CreatedAt'
)
BEGIN
    CREATE INDEX IX_Orders_MemberId_CreatedAt
    ON dbo.Orders (MemberId, CreatedAt DESC, OrderId DESC)
    INCLUDE
    (
        OrderNo, Status, PaymentMethod, TotalAmount, DiscountAmount,
        ShippingFee, TaxAmount, ReceiverName, ReceiverPhone,
        PaidAt, ShippedAt, CompletedAt, CancelledAt, UpdatedAt
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetMemberOrders
    @MemberId  bigint,
    @StartDate datetime2(0),
    @EndDate   datetime2(0),       -- 半開區間：[StartDate, EndDate)
    @StatusList varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MemberId IS NULL
        THROW 50001, 'MemberId cannot be NULL.', 1;

    IF @StartDate IS NULL OR @EndDate IS NULL OR @StartDate >= @EndDate
        THROW 50002, 'Date range must satisfy StartDate < EndDate.', 1;

    DECLARE @Statuses TABLE
    (
        Status tinyint NOT NULL PRIMARY KEY
    );

    IF @StatusList IS NOT NULL AND NULLIF(LTRIM(RTRIM(@StatusList)), '') IS NOT NULL
    BEGIN
        INSERT INTO @Statuses (Status)
        SELECT DISTINCT TRY_CONVERT(tinyint, LTRIM(RTRIM(value)))
        FROM STRING_SPLIT(@StatusList, ',')
        WHERE TRY_CONVERT(tinyint, LTRIM(RTRIM(value))) IN (1,2,3,4,9);

        IF EXISTS
        (
            SELECT 1
            FROM STRING_SPLIT(@StatusList, ',') AS s
            WHERE TRY_CONVERT(tinyint, LTRIM(RTRIM(s.value))) IS NULL
               OR TRY_CONVERT(tinyint, LTRIM(RTRIM(s.value))) NOT IN (1,2,3,4,9)
        )
            THROW 50003, 'StatusList contains an invalid status.', 1;
    END;

    /* 不用 CONVERT(CreatedAt)，直接對原始欄位做半開區間篩選。
       不建立全體會員的暫存表，也不使用 NOLOCK。 */
    SELECT
        o.OrderId,
        o.OrderNo,
        o.MemberId,
        o.Status,
        o.PaymentMethod,
        o.TotalAmount,
        o.DiscountAmount,
        o.ShippingFee,
        o.TaxAmount,
        o.CouponCode,
        o.ReceiverName,
        o.ReceiverPhone,
        o.ReceiverZipCode,
        o.ReceiverAddress,
        o.ShippingProvider,
        o.TrackingNo,
        o.InvoiceType,
        o.InvoiceNo,
        o.BuyerNote,
        o.InternalNote,
        o.SourceChannel,
        o.IsGift,
        o.CreatedAt,
        o.PaidAt,
        o.ShippedAt,
        o.CompletedAt,
        o.CancelledAt,
        o.UpdatedAt,
        m.MemberName,
        m.Phone,
        m.Email
    FROM dbo.Orders AS o
    INNER JOIN dbo.Members AS m
        ON m.MemberId = o.MemberId
    WHERE o.MemberId = @MemberId
      AND o.CreatedAt >= @StartDate
      AND o.CreatedAt < @EndDate
      AND
      (
          @StatusList IS NULL
          OR EXISTS (SELECT 1 FROM @Statuses AS s WHERE s.Status = o.Status)
      )
    ORDER BY o.CreatedAt DESC, o.OrderId DESC;

    /* 這個寫入不要和上面的讀取放在同一個長 transaction。
       若 LastQueryAt 只是分析資料，正式版可改成非同步事件。 */
    UPDATE dbo.Members
    SET LastQueryAt = SYSUTCDATETIME()
    WHERE MemberId = @MemberId;
END;
GO
