CREATE OR ALTER PROCEDURE dbo.usp_JoinEvent
    @MemberId bigint,
    @EventId int
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT dbo.EventJoin (MemberId, EventId) VALUES (@MemberId, @EventId);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
    END CATCH;
END;
GO
