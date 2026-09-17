CREATE TABLE dbo.EventJoin
(
    JoinId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_EventJoin PRIMARY KEY,
    MemberId bigint NOT NULL,
    EventId int NOT NULL,
    JoinedAt datetime2(0) NOT NULL CONSTRAINT DF_EventJoin_JoinedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT UX_EventJoin_Member_Event UNIQUE (MemberId, EventId)
);
GO
