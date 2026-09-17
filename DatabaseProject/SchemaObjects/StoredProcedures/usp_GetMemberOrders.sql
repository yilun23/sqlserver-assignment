CREATE OR ALTER PROCEDURE dbo.usp_GetMemberOrders
    @MemberId bigint,
    @StartDate datetime2(0),
    @EndDate datetime2(0),
    @StatusList varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.OrderId, o.OrderNo, o.MemberId, o.Status, o.TotalAmount,
           o.InvoiceType, o.InvoiceNo, o.CreatedAt, o.UpdatedAt,
           m.MemberName, m.Phone, m.Email
    FROM dbo.Orders AS o
    INNER JOIN dbo.Members AS m ON m.MemberId = o.MemberId
    WHERE o.MemberId = @MemberId
      AND o.CreatedAt >= @StartDate
      AND o.CreatedAt < @EndDate
    ORDER BY o.CreatedAt DESC, o.OrderId DESC;
END;
GO
