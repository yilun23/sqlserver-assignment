/* 題目五：一次結構變更
   變更：dbo.Orders 新增 InvoiceNo
   Target: SQL Server 2019+
*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH(N'dbo.Orders', N'InvoiceNo') IS NULL
BEGIN
    ALTER TABLE dbo.Orders
        ADD InvoiceNo varchar(30) NULL;
END;
GO
