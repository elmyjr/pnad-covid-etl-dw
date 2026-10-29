-- =====================================================================
-- Arquivo  : sqlserver/99_drop.sql
-- Objetivo : remover os objetos do projeto no SQL Server, para recriar
--            o ambiente do zero (00_setup_banco -> 01 a 06)
-- Etapa    : E10 - Documentacao (script de apoio)
-- Executar : como sa no container tsql (localhost,1434)
-- Depende  : -
-- Obs      : DESTRUTIVO: apaga procedures, functions, espelho, log, DW e
--            schemas; nao faz parte do pipeline
--          : pode ser executado de novo (DROP ... IF EXISTS)
--          : ordem: procedures -> functions -> fato -> dimensoes ->
--            espelho e log -> schemas; o banco so sai na parte opcional
-- =====================================================================

SET NOCOUNT ON;
GO

USE db_pnad_covid;
GO

-- procedures
DROP PROCEDURE IF EXISTS etl.usp_carregar_dw;
DROP PROCEDURE IF EXISTS etl.usp_carregar_fato;
DROP PROCEDURE IF EXISTS etl.usp_carregar_dim_pessoa;
DROP PROCEDURE IF EXISTS etl.usp_carregar_dim_municipio;
DROP PROCEDURE IF EXISTS etl.usp_carregar_dim_tempo;
DROP PROCEDURE IF EXISTS etl.usp_registrar_log;
PRINT 'Procedures removidas';
GO

-- functions
DROP FUNCTION IF EXISTS etl.fn_normalizar_texto;
DROP FUNCTION IF EXISTS etl.fn_title_case;
DROP FUNCTION IF EXISTS etl.fn_remover_acentos;
DROP FUNCTION IF EXISTS etl.fn_remover_espacos;
DROP FUNCTION IF EXISTS etl.fn_uf_nome;
DROP FUNCTION IF EXISTS etl.fn_uf_sigla;
DROP FUNCTION IF EXISTS etl.fn_municipio_nome;
DROP FUNCTION IF EXISTS etl.fn_sexo;
DROP FUNCTION IF EXISTS etl.fn_cor_raca;
DROP FUNCTION IF EXISTS etl.fn_escolaridade;
DROP FUNCTION IF EXISTS etl.fn_faixa_etaria;
DROP FUNCTION IF EXISTS etl.fn_faixa_rendimento;
DROP FUNCTION IF EXISTS etl.fn_atendimento_sus;
DROP FUNCTION IF EXISTS etl.fn_internado;
DROP FUNCTION IF EXISTS etl.fn_sintoma;
DROP FUNCTION IF EXISTS etl.fn_nome_mes;
PRINT 'Functions removidas';
GO

-- tabelas: a fato antes das dimensoes (FK)
DROP TABLE IF EXISTS dw.fato_pnad_covid;
DROP TABLE IF EXISTS dw.dim_tempo;
DROP TABLE IF EXISTS dw.dim_municipio;
DROP TABLE IF EXISTS dw.dim_pessoa;
DROP TABLE IF EXISTS staging.pnad_covid_pessoa;
DROP TABLE IF EXISTS etl.log_execucao;
PRINT 'Tabelas removidas';
GO

-- schemas (vazios)
DROP SCHEMA IF EXISTS dw;
DROP SCHEMA IF EXISTS staging;
DROP SCHEMA IF EXISTS etl;
PRINT 'Schemas removidos';
GO

-- conferencia: objetos restantes nos schemas do projeto (esperado: nenhum)
SELECT  s.name AS schema_nome, o.name AS objeto, o.type_desc
FROM    sys.objects AS o
JOIN    sys.schemas AS s ON s.schema_id = o.schema_id
WHERE   s.name IN (N'staging', N'dw', N'etl');

SELECT  name AS schema_restante
FROM    sys.schemas
WHERE   name IN (N'staging', N'dw', N'etl');
GO

-- ---------------------------------------------------------------------
-- Opcional: remover o banco inteiro
-- ---------------------------------------------------------------------
-- USE master;
-- ALTER DATABASE db_pnad_covid SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE IF EXISTS db_pnad_covid;
