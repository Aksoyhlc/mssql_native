-- Query timeout fixture:
WAITFOR DELAY '00:00:30';
SELECT 1;
GO

-- Deadlock tests should be run from two independent connections in a controlled fixture.
-- Constraint fixture:
USE mssql_native_test;
INSERT INTO dbo.driver_types(id) VALUES (1), (1);
GO
