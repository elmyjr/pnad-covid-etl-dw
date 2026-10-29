-- =====================================================================
-- Arquivo  : sqlserver/00_setup_banco.sql
-- Objetivo : criar o banco db_pnad_covid e os schemas staging, dw e etl
-- Etapa    : E0 - Ambiente
-- Executar : como sa (ou login sysadmin) no container tsql,
--            localhost,1434, banco master
-- Depende  : container tsql rodando
-- Obs      : pode ser executado de novo (IF NOT EXISTS)
--          : recovery SIMPLE: cargas grandes e repetiveis, sem
--            necessidade de recuperacao ponto a ponto
--          : collation herdada do servidor (igual a do tempdb, evita
--            conflito nos JOINs com tabelas temporarias)
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE master;
GO

-- ---------------------------------------------------------------------
-- 1. Banco
-- ---------------------------------------------------------------------
IF DB_ID(N'db_pnad_covid') IS NULL
BEGIN
    CREATE DATABASE db_pnad_covid;
    PRINT 'Banco db_pnad_covid criado';
END
ELSE
    PRINT 'Banco db_pnad_covid ja existe: mantido';
GO

IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'db_pnad_covid') <> 'SIMPLE'
BEGIN
    ALTER DATABASE db_pnad_covid SET RECOVERY SIMPLE;
    PRINT 'Recovery model ajustado para SIMPLE';
END
GO

USE db_pnad_covid;
GO

-- ---------------------------------------------------------------------
-- 2. Schemas (CREATE SCHEMA precisa ser o unico comando do lote)
-- ---------------------------------------------------------------------
IF SCHEMA_ID(N'staging') IS NULL
BEGIN
    EXEC (N'CREATE SCHEMA staging AUTHORIZATION dbo');
    PRINT 'Schema staging criado';
END
ELSE
    PRINT 'Schema staging ja existe';

IF SCHEMA_ID(N'dw') IS NULL
BEGIN
    EXEC (N'CREATE SCHEMA dw AUTHORIZATION dbo');
    PRINT 'Schema dw criado';
END
ELSE
    PRINT 'Schema dw ja existe';

IF SCHEMA_ID(N'etl') IS NULL
BEGIN
    EXEC (N'CREATE SCHEMA etl AUTHORIZATION dbo');
    PRINT 'Schema etl criado';
END
ELSE
    PRINT 'Schema etl ja existe';
GO

-- ---------------------------------------------------------------------
-- 3. Conferencia
-- ---------------------------------------------------------------------
SELECT  d.name                AS banco,
        d.state_desc          AS estado,
        d.recovery_model_desc AS recovery,
        d.collation_name      AS collation_banco,
        d.compatibility_level AS nivel_compat
FROM    sys.databases AS d
WHERE   d.name = N'db_pnad_covid';

SELECT  s.name                     AS schema_nome,
        USER_NAME(s.principal_id)  AS dono
FROM    sys.schemas AS s
WHERE   s.name IN (N'staging', N'dw', N'etl')
ORDER BY s.name;

SELECT  CONVERT(sysname, SERVERPROPERTY('Collation'))            AS collation_servidor,
        CONVERT(sysname, DATABASEPROPERTYEX(N'tempdb', 'Collation')) AS collation_tempdb,
        COLLATIONPROPERTY(CONVERT(sysname, DATABASEPROPERTYEX(N'db_pnad_covid', 'Collation')),
                          'CodePage')                            AS code_page_banco;

SELECT @@VERSION AS versao_sql_server;
GO