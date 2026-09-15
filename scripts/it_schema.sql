SET NOCOUNT ON;
IF DB_ID('mssql_native_test') IS NOT NULL
BEGIN
    ALTER DATABASE mssql_native_test SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE mssql_native_test;
END
GO
CREATE DATABASE mssql_native_test;
GO
USE mssql_native_test;
GO

CREATE TABLE dbo.categories (
    id           INT IDENTITY(1,1) PRIMARY KEY,
    code         VARCHAR(16)   NOT NULL UNIQUE,
    name         NVARCHAR(80)  NOT NULL,
    margin_rate  DECIMAL(5,4)  NOT NULL DEFAULT (0.2000),
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.products (
    id           INT IDENTITY(1000,1) PRIMARY KEY,
    sku          VARCHAR(24)      NOT NULL UNIQUE,
    name         NVARCHAR(120)    NOT NULL,
    category_id  INT              NOT NULL REFERENCES dbo.categories(id),
    unit_code    CHAR(3)          NOT NULL DEFAULT ('M2'),
    price        MONEY            NOT NULL,
    cost         DECIMAL(18,4)    NOT NULL,
    weight_kg    FLOAT            NULL,
    grammage        REAL             NULL,
    stock_qty    SMALLINT         NOT NULL DEFAULT (0),
    reorder_lvl  TINYINT          NOT NULL DEFAULT (5),
    is_active    BIT              NOT NULL DEFAULT (1),
    barcode      NCHAR(13)        NULL,
    thumbnail       VARBINARY(32)    NULL,
    rowguid      UNIQUEIDENTIFIER NOT NULL DEFAULT (NEWID()),
    created_at   DATETIME2(6)     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIMEOFFSET(3) NULL
);
GO

CREATE TABLE dbo.customers (
    id           INT IDENTITY(1,1) PRIMARY KEY,
    name         NVARCHAR(120)  NOT NULL,
    tax_no       VARCHAR(16)    NULL,
    segment      NVARCHAR(20)   NOT NULL DEFAULT (N'retail'),
    credit_limit DECIMAL(18,2)  NOT NULL DEFAULT (0),
    balance      DECIMAL(18,2)  NOT NULL DEFAULT (0),
    registered   DATE           NOT NULL,
    open_time    TIME(0)        NULL
);
GO

CREATE TABLE dbo.orders (
    id           BIGINT IDENTITY(500000,1) PRIMARY KEY,
    customer_id  INT            NOT NULL REFERENCES dbo.customers(id),
    order_date   DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    status       TINYINT        NOT NULL DEFAULT (1),  -- 1=new 2=paid 3=shipped 4=cancelled
    total        DECIMAL(18,2)  NOT NULL DEFAULT (0),
    notes        NVARCHAR(MAX)  NULL
);
GO

CREATE TABLE dbo.order_items (
    order_id     BIGINT         NOT NULL REFERENCES dbo.orders(id),
    line_no      INT            NOT NULL,
    product_id   INT            NOT NULL REFERENCES dbo.products(id),
    qty          DECIMAL(9,3)   NOT NULL,
    unit_price   MONEY          NOT NULL,
    discount     DECIMAL(5,4)   NOT NULL DEFAULT (0),
    CONSTRAINT pk_order_items PRIMARY KEY (order_id, line_no)
);
GO

CREATE TABLE dbo.inventory_log (
    id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    product_id   INT           NOT NULL REFERENCES dbo.products(id),
    delta        INT           NOT NULL,
    reason       NVARCHAR(40)  NOT NULL,
    ts           DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-------------------- SEED --------------------
INSERT INTO dbo.categories (code, name, margin_rate) VALUES
 ('DESK',  N'Masa Üstü', 0.4500),
 ('PAPER',  N'Kağıt Ürünleri', 0.2500),
 ('WRITE', N'Yazı Gereçleri', 0.3500),
 ('FILING',N'Dosyalama',   0.3000),
 ('ACCS',  N'Aksesuar & Bakım',  0.5000);
GO

DECLARE @desk INT = (SELECT id FROM dbo.categories WHERE code='DESK');
DECLARE @papr INT = (SELECT id FROM dbo.categories WHERE code='PAPER');
DECLARE @wrt  INT = (SELECT id FROM dbo.categories WHERE code='WRITE');
DECLARE @fil  INT = (SELECT id FROM dbo.categories WHERE code='FILING');
DECLARE @accs INT = (SELECT id FROM dbo.categories WHERE code='ACCS');

INSERT INTO dbo.products (sku,name,category_id,price,cost,weight_kg,grammage,stock_qty,reorder_lvl,is_active,barcode,thumbnail,updated_at) VALUES
 ('DSK-LMP-001', N'Işıklı Masa Lambası',      @desk, 42000.00, 21000.0000, 6.4,  900000, 12, 3, 1, N'8690000000017', 0x1A2B3C4D, SYSDATETIMEOFFSET()),
 ('DSK-ORG-002', N'Ahşap Masa Düzenleyici',        @desk, 18500.50, 9200.5000,  4.1,  360000,  7, 3, 1, N'8690000000024', 0x00FF00FF, SYSDATETIMEOFFSET()),
 ('PPR-A4C-101', N'A4 Fotokopi Kağıdı 80g',      @papr,  3250.00, 1600.0000,  8.9,  NULL,   40, 8, 1, N'8690000001014', NULL,       NULL),
 ('PPR-NBK-102', N'Spiralli Defter 200 yaprak',       @papr,  4899.99, 2450.0000, 12.3,  NULL,   25, 8, 1, N'8690000001021', 0xDEADBEEF, SYSDATETIMEOFFSET()),
 ('WRT-PEN-201', N'Tükenmez Kalem Mavi',        @wrt,   1450.00,  700.0000,  2.2,  NULL,   60, 10,1, N'8690000002011', NULL,       NULL),
 ('WRT-MRK-202', N'Fosforlu Kalem Sarı',       @wrt,   1975.25,  980.0000,  2.6,  NULL,    4, 10,1, N'8690000002028', NULL,       SYSDATETIMEOFFSET()),
 ('FIL-CLS-301', N'Klasör Geniş 8cm',      @fil,   2100.00, 1050.0000,  3.7,  NULL,   18, 6, 1, N'8690000003018', NULL,       NULL),
 ('FIL-GEO-302', N'Sunum Dosyası 40 Yaprak', @fil,   2780.00, 1390.0000,  4.9,  NULL,    2, 6, 1, N'8690000003025', 0xCAFEBABE, SYSDATETIMEOFFSET()),
 ('ACC-UDR-401', N'Kaymaz Fare Altlığı',       @accs,   349.90,  120.0000,  0.8,  NULL,  200, 20,1, N'8690000004015', NULL,       NULL),
 ('ACC-CLN-402', N'Cam Temizleyici 1L',          @accs,   189.50,   70.0000,  1.1,  NULL,    0, 20,0, N'8690000004022', NULL,       SYSDATETIMEOFFSET());
GO

INSERT INTO dbo.customers (name, tax_no, segment, credit_limit, balance, registered, open_time) VALUES
 (N'Acar Mobilya Ltd.',      '1234567890', N'wholesale', 500000.00, 125300.75, '2023-02-11', '08:30:00'),
 (N'Deniz Ev Tekstil',       '2345678901', N'wholesale', 300000.00,  48200.00, '2024-06-01', '09:00:00'),
 (N'Zeynep Kaya',            NULL,         N'retail',        0.00,      0.00,   '2025-01-20', NULL),
 (N'Bazaar Export',    '3456789012', N'export',   1000000.00, 803450.90, '2022-11-05', '07:45:00'),
 (N'Mehmet Demir',           NULL,         N'retail',     15000.00,   1899.50,  '2025-07-15', '10:15:00');
GO

-- Orders + items (varied)
INSERT INTO dbo.orders (customer_id, order_date, status, notes) VALUES
 (1, '2025-07-01T10:00:00', 3, N'Toptan sevkiyat - İstanbul deposu'),
 (1, '2025-07-20T14:30:00', 2, NULL),
 (2, '2025-07-22T09:10:00', 1, N'Müşteri onayı bekliyor'),
 (4, '2025-07-25T16:45:00', 3, N'İhracat - konteyner #A19, özel paketleme'),
 (5, '2025-08-01T11:05:00', 1, N'Perakende');
GO

INSERT INTO dbo.order_items (order_id, line_no, product_id, qty, unit_price, discount)
SELECT o.id, x.line_no, p.id, x.qty, p.price, x.discount
FROM (VALUES
   (0,1,'DSK-LMP-001',1.000,0.0500),
   (0,2,'ACC-UDR-401',3.000,0.0000),
   (1,1,'PPR-NBK-102',4.000,0.1000),
   (1,2,'PPR-A4C-101',6.000,0.1000),
   (2,1,'WRT-PEN-201',10.000,0.0000),
   (3,1,'DSK-ORG-002',2.000,0.1500),
   (3,2,'FIL-GEO-302',5.000,0.0500),
   (3,3,'ACC-CLN-402',12.000,0.0000),
   (4,1,'FIL-CLS-301',1.000,0.0000)
) AS x(ord_ix, line_no, sku, qty, discount)
JOIN (SELECT id, ROW_NUMBER() OVER (ORDER BY id)-1 AS ix FROM dbo.orders) o ON o.ix = x.ord_ix
JOIN dbo.products p ON p.sku = x.sku;
GO

-- Recompute order totals
UPDATE o SET total = t.s
FROM dbo.orders o
JOIN (SELECT order_id, SUM(qty*unit_price*(1-discount)) s FROM dbo.order_items GROUP BY order_id) t
  ON t.order_id = o.id;
GO

INSERT INTO dbo.inventory_log (product_id, delta, reason)
SELECT id, stock_qty, N'initial-count' FROM dbo.products;
GO

-------------------- CHARSET REGRESSION (single-byte non-Latin1 collation) --------------------
-- A VARCHAR column with a Turkish (CP1254) collation next to an NVARCHAR mirror.
-- Reading `label` requires FreeTDS's iconv to convert CP1254 -> UTF-8. Without a
-- full iconv (built-in converter only), the bytes degrade to ISO-8859-1 and the
-- Turkish-specific letters İ/Ş/Ğ/ı/ş/ğ come back as Ý/Þ/Ð/ý/þ/ð. `label_n`
-- (Unicode/UCS-2) is the control that was always correct.
CREATE TABLE dbo.charset_probe (
    id       INT IDENTITY(1,1) PRIMARY KEY,
    label    VARCHAR(200)  COLLATE Turkish_CI_AS NOT NULL,  -- single-byte CP1254
    label_n  NVARCHAR(200) NOT NULL                         -- Unicode control
);
GO
INSERT INTO dbo.charset_probe (label, label_n) VALUES
 (N'4 KENAR OVERLOK ÜZERİ EBATLAR BEZ BAŞLIKLI OLACAKTIR. DÜZ BÜKÜM ÇÖĞÜŞİ çöğüşı',
  N'4 KENAR OVERLOK ÜZERİ EBATLAR BEZ BAŞLIKLI OLACAKTIR. DÜZ BÜKÜM ÇÖĞÜŞİ çöğüşı');
GO

-------------------- STORED PROCEDURE (multi-result + output + return) --------------------
CREATE OR ALTER PROCEDURE dbo.usp_customer_dashboard
    @customer_id INT,
    @order_count INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.customers WHERE id=@customer_id)
    BEGIN
        SET @order_count = -1;
        RETURN 404;
    END

    -- Result set 1: customer header
    SELECT id, name, segment, credit_limit, balance
    FROM dbo.customers WHERE id=@customer_id;

    -- Result set 2: order lines with computed columns (join, window)
    SELECT o.id AS order_id, o.order_date, o.status, o.total,
           COUNT(oi.line_no) AS lines,
           SUM(oi.qty) AS total_qty,
           RANK() OVER (ORDER BY o.total DESC) AS spend_rank
    FROM dbo.orders o
    LEFT JOIN dbo.order_items oi ON oi.order_id = o.id
    WHERE o.customer_id=@customer_id
    GROUP BY o.id, o.order_date, o.status, o.total;

    SELECT @order_count = COUNT(*) FROM dbo.orders WHERE customer_id=@customer_id;
    RETURN 0;
END
GO

PRINT '=== SEED SUMMARY ===';
SELECT 'categories' t, COUNT(*) n FROM dbo.categories
UNION ALL SELECT 'products', COUNT(*) FROM dbo.products
UNION ALL SELECT 'customers', COUNT(*) FROM dbo.customers
UNION ALL SELECT 'orders', COUNT(*) FROM dbo.orders
UNION ALL SELECT 'order_items', COUNT(*) FROM dbo.order_items
UNION ALL SELECT 'inventory_log', COUNT(*) FROM dbo.inventory_log;
GO
