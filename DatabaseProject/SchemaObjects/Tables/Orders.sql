CREATE TABLE dbo.Orders
(
    OrderId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY,
    OrderNo varchar(30) NOT NULL CONSTRAINT UQ_Orders_OrderNo UNIQUE,
    MemberId bigint NOT NULL,
    Status tinyint NOT NULL CONSTRAINT DF_Orders_Status DEFAULT (1),
    TotalAmount decimal(12,2) NOT NULL,
    InvoiceType tinyint NULL,
    InvoiceNo varchar(30) NULL,
    CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_Orders_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt datetime2(0) NOT NULL CONSTRAINT DF_Orders_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_Orders_Members FOREIGN KEY (MemberId) REFERENCES dbo.Members(MemberId),
    CONSTRAINT CK_Orders_TotalAmount CHECK (TotalAmount >= 0)
);
GO
