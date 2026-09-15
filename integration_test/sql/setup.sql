IF DB_ID(N'mssql_native_test') IS NULL
BEGIN
    CREATE DATABASE mssql_native_test;
END
GO
USE mssql_native_test;
GO

DROP TABLE IF EXISTS dbo.driver_types;
CREATE TABLE dbo.driver_types (
    id int NOT NULL PRIMARY KEY,
    flag bit NULL,
    tiny_value tinyint NULL,
    small_value smallint NULL,
    big_value bigint NULL,
    real_value real NULL,
    float_value float NULL,
    decimal_value decimal(38, 12) NULL,
    money_value money NULL,
    text_value varchar(400) NULL,
    unicode_value nvarchar(400) NULL,
    binary_value varbinary(400) NULL,
    date_value date NULL,
    time_value time(7) NULL,
    datetime_value datetime NULL,
    datetime2_value datetime2(7) NULL,
    offset_value datetimeoffset(7) NULL,
    guid_value uniqueidentifier NULL,
    xml_value xml NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.driver_multi_result
    @id int,
    @output_text nvarchar(100) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @id AS first_id, N'İstanbul Şanlıurfa Ökkeş' AS unicode_text;
    SELECT @id + 1 AS second_id;
    SET @output_text = N'completed';
    RETURN 42;
END
GO

DROP TABLE IF EXISTS dbo.bulk_target;
CREATE TABLE dbo.bulk_target (
    id bigint NOT NULL,
    code nvarchar(100) NULL,
    amount decimal(18,4) NULL,
    created_at datetime2(7) NULL,
    payload varbinary(1024) NULL
);
GO
