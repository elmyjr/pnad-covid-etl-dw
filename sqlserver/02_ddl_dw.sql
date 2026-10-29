-- =====================================================================
-- Arquivo  : sqlserver/02_ddl_dw.sql
-- Objetivo : criar as dimensoes dw.dim_tempo, dw.dim_municipio e
--            dw.dim_pessoa e a fato dw.fato_pnad_covid, com PK, FK e
--            UNIQUE
-- Etapa    : E3 - Estrutura SQL Server
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : sqlserver/00_setup_banco.sql
-- Obs      : pode ser executado de novo (IF OBJECT_ID); nao apaga dados
--          : extensoes ao enunciado (D07): nu_mes (dim_tempo),
--            co_capital (dim_municipio) e qtd_pessoas (fato)
--          : atributos NOT NULL: NULL e codigo fora do dominio viram
--            Nao aplicavel / Nao informado nas functions (D14)
--          : CHECKs de integridade (extensao): mes 1-12, sexo M/F/I e
--            medidas entre 0 e qtd_pessoas
--          : grao da fato: mes x municipio x perfil de pessoa (D09)
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

-- ---------------------------------------------------------------------
-- 1. dim_tempo
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dw.dim_tempo', N'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_tempo (
        sk_tempo INT IDENTITY(1, 1) NOT NULL
                 CONSTRAINT pk_dim_tempo PRIMARY KEY,
        nu_ano   INT         NOT NULL,
        nu_mes   INT         NOT NULL,          -- extensao (D07)
        no_mes   VARCHAR(20) NOT NULL,
        CONSTRAINT uq_dim_tempo_ano_mes UNIQUE (nu_ano, nu_mes),
        CONSTRAINT ck_dim_tempo_mes CHECK (nu_mes BETWEEN 1 AND 12)
    );
    PRINT 'Tabela dw.dim_tempo criada';
END
ELSE
    PRINT 'Tabela dw.dim_tempo ja existe: mantida';
GO

-- ---------------------------------------------------------------------
-- 2. dim_municipio (27 capitais + "Demais Municipios" de cada UF, D06)
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dw.dim_municipio', N'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_municipio (
        sk_municipio INT IDENTITY(1, 1) NOT NULL
                     CONSTRAINT pk_dim_municipio PRIMARY KEY,
        co_capital   INT          NULL,         -- extensao (D07); NULL = demais municipios
        sg_uf        CHAR(2)      NOT NULL,
        no_municipio VARCHAR(150) NOT NULL,
        CONSTRAINT uq_dim_municipio_uf_nome UNIQUE (sg_uf, no_municipio)
    );
    PRINT 'Tabela dw.dim_municipio criada';
END
ELSE
    PRINT 'Tabela dw.dim_municipio ja existe: mantida';
GO

-- ---------------------------------------------------------------------
-- 3. dim_pessoa (perfil: combinacoes unicas dos 5 atributos, D08)
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dw.dim_pessoa', N'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_pessoa (
        sk_pessoa        INT IDENTITY(1, 1) NOT NULL
                         CONSTRAINT pk_dim_pessoa PRIMARY KEY,
        cor_raca         VARCHAR(25) NOT NULL,
        sexo             CHAR(1)     NOT NULL,
        faixa_etaria     VARCHAR(25) NOT NULL,
        escolaridade     VARCHAR(50) NOT NULL,
        faixa_rendimento VARCHAR(25) NOT NULL,
        CONSTRAINT uq_dim_pessoa_perfil
            UNIQUE (cor_raca, sexo, faixa_etaria, escolaridade, faixa_rendimento),
        CONSTRAINT ck_dim_pessoa_sexo CHECK (sexo IN ('M', 'F', 'I'))  -- D13
    );
    PRINT 'Tabela dw.dim_pessoa criada';
END
ELSE
    PRINT 'Tabela dw.dim_pessoa ja existe: mantida';
GO

-- ---------------------------------------------------------------------
-- 4. fato_pnad_covid (medidas = contagens de entrevistados, D09/D10)
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dw.fato_pnad_covid', N'U') IS NULL
BEGIN
    CREATE TABLE dw.fato_pnad_covid (
        sk_tempo        INT NOT NULL,
        sk_municipio    INT NOT NULL,
        sk_pessoa       INT NOT NULL,
        qtd_pessoas     INT NOT NULL,           -- extensao (D07)
        atendimento_SUS INT NOT NULL,
        internado       INT NOT NULL,
        sintoma         INT NOT NULL,
        CONSTRAINT pk_fato_pnad_covid
            PRIMARY KEY (sk_tempo, sk_municipio, sk_pessoa),
        CONSTRAINT fk_fato_dim_tempo
            FOREIGN KEY (sk_tempo)     REFERENCES dw.dim_tempo (sk_tempo),
        CONSTRAINT fk_fato_dim_municipio
            FOREIGN KEY (sk_municipio) REFERENCES dw.dim_municipio (sk_municipio),
        CONSTRAINT fk_fato_dim_pessoa
            FOREIGN KEY (sk_pessoa)    REFERENCES dw.dim_pessoa (sk_pessoa),
        CONSTRAINT ck_fato_medidas CHECK (
                qtd_pessoas > 0
            AND atendimento_SUS BETWEEN 0 AND qtd_pessoas
            AND internado       BETWEEN 0 AND qtd_pessoas
            AND sintoma         BETWEEN 0 AND qtd_pessoas)
    );
    PRINT 'Tabela dw.fato_pnad_covid criada';
END
ELSE
    PRINT 'Tabela dw.fato_pnad_covid ja existe: mantida';
GO

-- ---------------------------------------------------------------------
-- 5. Conferencia
-- ---------------------------------------------------------------------
-- tabelas do DW: colunas e linhas (esperado: 4, 4, 6, 7 colunas; 0 linhas)
SELECT  s.name + N'.' + t.name AS tabela,
        (SELECT COUNT(*) FROM sys.columns AS c WHERE c.object_id = t.object_id) AS qtd_colunas,
        (SELECT SUM(p.rows) FROM sys.partitions AS p
          WHERE p.object_id = t.object_id AND p.index_id IN (0, 1))            AS qtd_linhas
FROM    sys.tables  AS t
JOIN    sys.schemas AS s ON s.schema_id = t.schema_id
WHERE   s.name = N'dw'
ORDER BY tabela;

-- PK e UNIQUE com as colunas (esperado: 4 PK e 3 UNIQUE)
SELECT  OBJECT_NAME(k.parent_object_id) AS tabela,
        k.name                          AS restricao,
        k.type_desc                     AS tipo,
        STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS colunas
FROM    sys.key_constraints AS k
JOIN    sys.index_columns   AS ic ON ic.object_id = k.parent_object_id
                                 AND ic.index_id  = k.unique_index_id
JOIN    sys.columns         AS c  ON c.object_id  = ic.object_id
                                 AND c.column_id  = ic.column_id
WHERE   k.schema_id = SCHEMA_ID(N'dw')
GROUP BY k.parent_object_id, k.name, k.type_desc
ORDER BY tabela, tipo, restricao;

-- FKs da fato (esperado: 3, habilitadas e confiaveis)
SELECT  fk.name                                         AS restricao,
        COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS coluna,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + N'.'
          + OBJECT_NAME(fk.referenced_object_id)        AS referencia,
        fk.is_disabled                                  AS desabilitada,
        fk.is_not_trusted                               AS nao_confiavel
FROM    sys.foreign_keys        AS fk
JOIN    sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
WHERE   fk.parent_object_id = OBJECT_ID(N'dw.fato_pnad_covid')
ORDER BY restricao;

-- CHECKs (esperado: 3)
SELECT  OBJECT_NAME(cc.parent_object_id) AS tabela,
        cc.name                          AS restricao,
        cc.definition                    AS definicao
FROM    sys.check_constraints AS cc
WHERE   cc.schema_id = SCHEMA_ID(N'dw')
ORDER BY tabela;
GO
