CREATE TABLE dbo.Members
(
    MemberId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Members PRIMARY KEY,
    MemberNo varchar(20) NOT NULL CONSTRAINT UQ_Members_MemberNo UNIQUE,
    MemberName nvarchar(50) NOT NULL,
    Phone nvarchar(20) NULL,
    Email nvarchar(254) NULL,
    PasswordHash varbinary(64) NOT NULL,
    Status tinyint NOT NULL CONSTRAINT DF_Members_Status DEFAULT (1),
    RegisteredAt datetime2(0) NOT NULL CONSTRAINT DF_Members_RegisteredAt DEFAULT (SYSUTCDATETIME()),
    LastLoginAt datetime2(0) NULL,
    LastQueryAt datetime2(0) NULL
);
GO
