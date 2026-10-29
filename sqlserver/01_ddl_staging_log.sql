-- =====================================================================
-- Arquivo  : sqlserver/01_ddl_staging_log.sql
-- Objetivo : criar o espelho staging.pnad_covid_pessoa, o log
--            etl.log_execucao e a procedure etl.usp_registrar_log
-- Etapa    : E3 - Estrutura SQL Server
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : sqlserver/00_setup_banco.sql
-- Obs      : pode ser executado de novo (IF OBJECT_ID / CREATE OR
--            ALTER); nao apaga dados
--          : espelho com as 24 colunas e os tipos do enunciado (INT e
--            DATETIME), sem restricoes extras
--          : indice clusterizado em (NU_ANO, NU_MES): a ponte apaga e
--            regrava um mes inteiro (extensao fisica, nao muda colunas)
--          : status do log com o mesmo CHECK do Oracle (D15)
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

-- ---------------------------------------------------------------------
-- 1. Espelho da staging (copia do Oracle feita pelo Python, sem
--    transformacao)
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'staging.pnad_covid_pessoa', N'U') IS NULL
BEGIN
    CREATE TABLE staging.pnad_covid_pessoa (
        NU_ANO                       INT      NULL,
        NU_MES                       INT      NULL,
        UF                           INT      NULL,
        CO_MUNICIPIO                 INT      NULL,
        COR_RACA                     INT      NULL,
        SEXO                         INT      NULL,
        IDADE                        INT      NULL,
        ESCOLARIDADE                 INT      NULL,
        FAIXA_RENDIMENTO             INT      NULL,
        ATENDIMENTO_SUS              INT      NULL,
        INTERNADO                    INT      NULL,
        SINTOMA_FEBRE                INT      NULL,
        SINTOMA_TOSSE                INT      NULL,
        SINTOMA_DOR_GARGANTA         INT      NULL,
        SINTOMA_DIFICULDADE_RESPIRAR INT      NULL,
        SINTOMA_DOR_CABECA           INT      NULL,
        SINTOMA_DOR_PEITO            INT      NULL,
        SINTOMA_NAUSEA               INT      NULL,
        SINTOMA_NARIZ                INT      NULL,
        SINTOMA_FADIGA               INT      NULL,
        SINTOMA_DOR_OLHOS            INT      NULL,
        SINTOMA_PERDA_CHEIRO_SABOR   INT      NULL,
        SINTOMA_DOR_MUSCULAR         INT      NULL,
        DT_CARGA                     DATETIME NULL
    );
    PRINT 'Tabela staging.pnad_covid_pessoa criada';
END
ELSE
    PRINT 'Tabela staging.pnad_covid_pessoa ja existe: mantida';
GO

-- apoio ao DELETE do mes pela ponte e a leitura por mes
IF NOT EXISTS (SELECT 1
                 FROM sys.indexes
                WHERE object_id = OBJECT_ID(N'staging.pnad_covid_pessoa')
                  AND name      = N'cix_pnad_covid_pessoa_ano_mes')
BEGIN
    CREATE CLUSTERED INDEX cix_pnad_covid_pessoa_ano_mes
        ON staging.pnad_covid_pessoa (NU_ANO, NU_MES);
    PRINT 'Indice cix_pnad_covid_pessoa_ano_mes criado';
END
ELSE
    PRINT 'Indice cix_pnad_covid_pessoa_ano_mes ja existe: mantido';
GO

-- ---------------------------------------------------------------------
-- 2. Log de execucao (procedures do DW e ponte Python)
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'etl.log_execucao', N'U') IS NULL
BEGIN
    CREATE TABLE etl.log_execucao (
        id_log             INT IDENTITY(1, 1) NOT NULL
                           CONSTRAINT pk_log_execucao PRIMARY KEY,
        dt_inicio          DATETIME2(0)  NOT NULL,
        dt_fim             DATETIME2(0)  NULL,
        no_processo        VARCHAR(60)   NOT NULL,
        ds_referencia      VARCHAR(100)  NULL,
        qt_linhas_lidas    INT           NULL,
        qt_linhas_gravadas INT           NULL,
        st_execucao        VARCHAR(20)   NOT NULL
                           CONSTRAINT ck_log_execucao_status
                           CHECK (st_execucao IN ('SUCESSO', 'SUCESSO PARCIAL', 'ERRO')),
        ds_observacao      VARCHAR(4000) NULL
    );
    PRINT 'Tabela etl.log_execucao criada';
END
ELSE
    PRINT 'Tabela etl.log_execucao ja existe: mantida';
GO

-- ---------------------------------------------------------------------
-- 3. Gravacao do log (usada pelas procedures e pela ponte)
--    Chamar fora de transacao: depois do COMMIT, ou no CATCH depois do
--    ROLLBACK, para o ERRO ficar registrado.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_registrar_log
    @no_processo        VARCHAR(60),
    @ds_referencia      VARCHAR(100)   = NULL,
    @dt_inicio          DATETIME2(0),
    @qt_linhas_lidas    INT            = NULL,
    @qt_linhas_gravadas INT            = NULL,
    @st_execucao        VARCHAR(20),
    @ds_observacao      NVARCHAR(4000) = NULL,
    @id_log             INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO etl.log_execucao
           (dt_inicio, dt_fim, no_processo, ds_referencia,
            qt_linhas_lidas, qt_linhas_gravadas, st_execucao, ds_observacao)
    VALUES (@dt_inicio, SYSDATETIME(), @no_processo, @ds_referencia,
            @qt_linhas_lidas, @qt_linhas_gravadas, @st_execucao, @ds_observacao);

    SET @id_log = CAST(SCOPE_IDENTITY() AS INT);
END;
GO

PRINT 'Procedure etl.usp_registrar_log criada/atualizada';
GO

-- ---------------------------------------------------------------------
-- 4. Conferencia
-- ---------------------------------------------------------------------
-- tabelas e quantidade de colunas (esperado: 24 e 9)
SELECT  s.name + N'.' + t.name AS tabela,
        (SELECT COUNT(*) FROM sys.columns AS c WHERE c.object_id = t.object_id) AS qtd_colunas
FROM    sys.tables  AS t
JOIN    sys.schemas AS s ON s.schema_id = t.schema_id
WHERE   t.object_id IN (OBJECT_ID(N'staging.pnad_covid_pessoa'), OBJECT_ID(N'etl.log_execucao'))
ORDER BY tabela;

-- tipos do espelho (esperado: datetime 1, int 23)
SELECT  TYPE_NAME(c.user_type_id) AS tipo,
        COUNT(*)                  AS qtd_colunas
FROM    sys.columns AS c
WHERE   c.object_id = OBJECT_ID(N'staging.pnad_covid_pessoa')
GROUP BY TYPE_NAME(c.user_type_id)
ORDER BY tipo;

-- indices
SELECT  OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS tabela,
        i.name        AS indice,
        i.type_desc   AS tipo,
        STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS colunas
FROM    sys.indexes       AS i
JOIN    sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN    sys.columns       AS c  ON c.object_id  = ic.object_id AND c.column_id = ic.column_id
WHERE   i.object_id IN (OBJECT_ID(N'staging.pnad_covid_pessoa'), OBJECT_ID(N'etl.log_execucao'))
GROUP BY i.object_id, i.name, i.type_desc
ORDER BY tabela, indice;

-- restricoes do log
SELECT  OBJECT_NAME(o.parent_object_id) AS tabela,
        o.name                          AS restricao,
        o.type_desc                     AS tipo,
        cc.definition                   AS definicao
FROM    sys.objects AS o
LEFT JOIN sys.check_constraints AS cc ON cc.object_id = o.object_id
WHERE   o.parent_object_id = OBJECT_ID(N'etl.log_execucao')
  AND   o.type IN ('PK', 'C')
ORDER BY o.type_desc;

-- procedure de log
SELECT  SCHEMA_NAME(p.schema_id) + N'.' + p.name AS procedure_nome,
        p.type_desc,
        (SELECT COUNT(*) FROM sys.parameters AS pa WHERE pa.object_id = p.object_id) AS qtd_parametros
FROM    sys.procedures AS p
WHERE   p.object_id = OBJECT_ID(N'etl.usp_registrar_log');
GO
