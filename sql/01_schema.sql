/* 題目一：B2C 電商訂單系統
   Target: SQL Server 2019+ / T-SQL
   可在指定 database 中執行；若 database 名稱不同，請自行切換 USE。
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

/* 分區函數：每月一個邊界。邊界使用 RANGE RIGHT，
   例如 2026-09-01 起的資料進入 p202609。 */
IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'PF_OrderCreatedAt_Monthly')
BEGIN
    CREATE PARTITION FUNCTION PF_OrderCreatedAt_Monthly (datetime2(0))
    AS RANGE RIGHT FOR VALUES
    (
        '2023-10-01', '2023-11-01', '2023-12-01',
        '2024-01-01', '2024-02-01', '2024-03-01', '2024-04-01',
        '2024-05-01', '2024-06-01', '2024-07-01', '2024-08-01', '2024-09-01',
        '2024-10-01', '2024-11-01', '2024-12-01',
        '2025-01-01', '2025-02-01', '2025-03-01', '2025-04-01',
        '2025-05-01', '2025-06-01', '2025-07-01', '2025-08-01', '2025-09-01',
        '2025-10-01', '2025-11-01', '2025-12-01',
        '2026-01-01', '2026-02-01', '2026-03-01', '2026-04-01',
        '2026-05-01', '2026-06-01', '2026-07-01', '2026-08-01', '2026-09-01',
        '2026-10-01', '2026-11-01', '2026-12-01',
        '2027-01-01'
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'PS_OrderCreatedAt_Monthly')
BEGIN
    CREATE PARTITION SCHEME PS_OrderCreatedAt_Monthly
    AS PARTITION PF_OrderCreatedAt_Monthly ALL TO ([PRIMARY]);
END;
GO

IF OBJECT_ID(N'dbo.Members', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Members
    (
        MemberId       bigint IDENTITY(1,1) NOT NULL,
        MemberNo       varchar(20) NOT NULL,
        MemberName     nvarchar(50) NOT NULL,
        Phone          nvarchar(20) NULL,
        Email          nvarchar(254) NULL,
        PasswordHash   varbinary(64) NOT NULL,
        Status         tinyint NOT NULL CONSTRAINT DF_Members_Status DEFAULT (1),
        RegisteredAt   datetime2(0) NOT NULL CONSTRAINT DF_Members_RegisteredAt DEFAULT (SYSUTCDATETIME()),
        LastLoginAt    datetime2(0) NULL,
        LastQueryAt    datetime2(0) NULL,
        CONSTRAINT PK_Members PRIMARY KEY CLUSTERED (MemberId),
        CONSTRAINT UQ_Members_MemberNo UNIQUE (MemberNo),
        CONSTRAINT UQ_Members_Email UNIQUE (Email)
    );
END;
GO

IF OBJECT_ID(N'dbo.Products', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Products
    (
        ProductId      bigint IDENTITY(1,1) NOT NULL,
        ProductSku     varchar(50) NOT NULL,
        ProductName    nvarchar(200) NOT NULL,
        UnitPrice      decimal(12,2) NOT NULL,
        Status         tinyint NOT NULL CONSTRAINT DF_Products_Status DEFAULT (1),
        CreatedAt      datetime2(0) NOT NULL CONSTRAINT DF_Products_CreatedAt DEFAULT (SYSUTCDATETIME()),
        UpdatedAt      datetime2(0) NOT NULL CONSTRAINT DF_Products_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_Products PRIMARY KEY CLUSTERED (ProductId),
        CONSTRAINT UQ_Products_ProductSku UNIQUE (ProductSku),
        CONSTRAINT CK_Products_UnitPrice CHECK (UnitPrice >= 0)
    );
END;
GO

IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Orders
    (
        OrderId          bigint IDENTITY(1,1) NOT NULL,
        OrderNo          varchar(30) NOT NULL,
        MemberId         bigint NOT NULL,
        Status           tinyint NOT NULL CONSTRAINT DF_Orders_Status DEFAULT (1),
        PaymentMethod    tinyint NOT NULL,
        TotalAmount      decimal(12,2) NOT NULL,
        DiscountAmount   decimal(12,2) NOT NULL CONSTRAINT DF_Orders_Discount DEFAULT (0),
        ShippingFee      decimal(12,2) NOT NULL CONSTRAINT DF_Orders_ShippingFee DEFAULT (0),
        TaxAmount        decimal(12,2) NOT NULL CONSTRAINT DF_Orders_TaxAmount DEFAULT (0),
        CouponCode       varchar(30) NULL,
        ReceiverName     nvarchar(50) NOT NULL,
        ReceiverPhone    nvarchar(20) NOT NULL,
        ReceiverZipCode  varchar(10) NULL,
        ReceiverAddress  nvarchar(200) NULL,
        ShippingProvider nvarchar(30) NULL,
        TrackingNo       varchar(40) NULL,
        InvoiceType      tinyint NULL,
        InvoiceNo        varchar(30) NULL,
        BuyerNote        nvarchar(500) NULL,
        InternalNote     nvarchar(500) NULL,
        SourceChannel    tinyint NOT NULL,
        IsGift           bit NOT NULL CONSTRAINT DF_Orders_IsGift DEFAULT (0),
        CreatedAt        datetime2(0) NOT NULL CONSTRAINT DF_Orders_CreatedAt DEFAULT (SYSUTCDATETIME()),
        PaidAt           datetime2(0) NULL,
        ShippedAt        datetime2(0) NULL,
        CompletedAt      datetime2(0) NULL,
        CancelledAt      datetime2(0) NULL,
        UpdatedAt        datetime2(0) NOT NULL CONSTRAINT DF_Orders_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        -- SQL Server 的分區唯一索引必須把分區鍵放入鍵值，因此 clustered PK 使用複合鍵。
        CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderId, CreatedAt) ON PS_OrderCreatedAt_Monthly(CreatedAt),
        -- 讓明細、付款與歷程仍可用單欄 OrderId 做外鍵；這個小索引不分區。
        CONSTRAINT UQ_Orders_OrderId UNIQUE (OrderId) ON [PRIMARY],
        CONSTRAINT UQ_Orders_OrderNo UNIQUE (OrderNo) ON [PRIMARY],
        CONSTRAINT FK_Orders_Members FOREIGN KEY (MemberId) REFERENCES dbo.Members(MemberId),
        CONSTRAINT CK_Orders_Status CHECK (Status IN (1,2,3,4,9)),
        CONSTRAINT CK_Orders_Amounts CHECK
            (TotalAmount >= 0 AND DiscountAmount >= 0 AND ShippingFee >= 0 AND TaxAmount >= 0),
        CONSTRAINT CK_Orders_StatusTimes CHECK
            ((Status <> 2 OR PaidAt IS NOT NULL)
             AND (Status <> 3 OR ShippedAt IS NOT NULL)
             AND (Status <> 4 OR CompletedAt IS NOT NULL)
             AND (Status <> 9 OR CancelledAt IS NOT NULL))
    );
END;
GO

IF OBJECT_ID(N'dbo.OrderItems', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.OrderItems
    (
        OrderItemId      bigint IDENTITY(1,1) NOT NULL,
        OrderId          bigint NOT NULL,
        ProductId        bigint NOT NULL,
        ProductSku       varchar(50) NOT NULL,
        ProductName      nvarchar(200) NOT NULL,
        UnitPrice        decimal(12,2) NOT NULL,
        Quantity         int NOT NULL,
        LineDiscount     decimal(12,2) NOT NULL CONSTRAINT DF_OrderItems_Discount DEFAULT (0),
        LineTax          decimal(12,2) NOT NULL CONSTRAINT DF_OrderItems_Tax DEFAULT (0),
        LineTotal        decimal(12,2) NOT NULL,
        CreatedAt        datetime2(0) NOT NULL CONSTRAINT DF_OrderItems_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_OrderItems PRIMARY KEY CLUSTERED (OrderItemId),
        CONSTRAINT FK_OrderItems_Orders FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId),
        CONSTRAINT FK_OrderItems_Products FOREIGN KEY (ProductId) REFERENCES dbo.Products(ProductId),
        CONSTRAINT CK_OrderItems_Quantity CHECK (Quantity > 0),
        CONSTRAINT CK_OrderItems_Amounts CHECK
            (UnitPrice >= 0 AND LineDiscount >= 0 AND LineTax >= 0 AND LineTotal >= 0)
    );
END;
GO

IF OBJECT_ID(N'dbo.OrderStatusHistory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.OrderStatusHistory
    (
        HistoryId       bigint IDENTITY(1,1) NOT NULL,
        OrderId         bigint NOT NULL,
        FromStatus      tinyint NULL,
        ToStatus        tinyint NOT NULL,
        ChangedAt       datetime2(0) NOT NULL CONSTRAINT DF_OrderStatusHistory_ChangedAt DEFAULT (SYSUTCDATETIME()),
        ChangedBy       nvarchar(100) NOT NULL,
        ChangeReason    nvarchar(500) NULL,
        CONSTRAINT PK_OrderStatusHistory PRIMARY KEY CLUSTERED (HistoryId),
        CONSTRAINT FK_OrderStatusHistory_Orders FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId),
        CONSTRAINT CK_OrderStatusHistory_ToStatus CHECK (ToStatus IN (1,2,3,4,9))
    );
END;
GO

IF OBJECT_ID(N'dbo.Payments', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Payments
    (
        PaymentId       bigint IDENTITY(1,1) NOT NULL,
        OrderId         bigint NOT NULL,
        TransactionId   varchar(100) NOT NULL,
        PaymentMethod   tinyint NOT NULL,
        Amount          decimal(12,2) NOT NULL,
        Status          tinyint NOT NULL,
        PaidAt          datetime2(0) NULL,
        CreatedAt       datetime2(0) NOT NULL CONSTRAINT DF_Payments_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_Payments PRIMARY KEY CLUSTERED (PaymentId),
        CONSTRAINT UQ_Payments_TransactionId UNIQUE (TransactionId),
        CONSTRAINT FK_Payments_Orders FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId),
        CONSTRAINT CK_Payments_Amount CHECK (Amount >= 0)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Orders') AND name = N'IX_Orders_Member_CreatedAt')
BEGIN
    CREATE INDEX IX_Orders_Member_CreatedAt
        ON dbo.Orders (MemberId, CreatedAt DESC, OrderId DESC)
        INCLUDE (Status, TotalAmount, PaidAt, ShippedAt, CompletedAt, CancelledAt, OrderNo);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.OrderItems') AND name = N'IX_OrderItems_OrderId')
BEGIN
    CREATE INDEX IX_OrderItems_OrderId ON dbo.OrderItems (OrderId, OrderItemId);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.OrderStatusHistory') AND name = N'IX_OrderStatusHistory_OrderId')
BEGIN
    CREATE INDEX IX_OrderStatusHistory_OrderId ON dbo.OrderStatusHistory (OrderId, ChangedAt);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Payments') AND name = N'IX_Payments_OrderId')
BEGIN
    CREATE INDEX IX_Payments_OrderId ON dbo.Payments (OrderId, CreatedAt);
END;
GO
