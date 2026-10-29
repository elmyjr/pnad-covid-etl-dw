-- =====================================================================
-- Arquivo  : sqlserver/04_usp_dimensoes.sql
-- Objetivo : procedures de carga das dimensoes a partir do espelho
--            staging.pnad_covid_pessoa: usp_carregar_dim_tempo,
--            usp_carregar_dim_municipio e usp_carregar_dim_pessoa
-- Etapa    : E6 - Dimensoes
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : 01_ddl_staging_log.sql, 02_ddl_dw.sql, 03_functions.sql;
--            espelho carregado pela ponte (E5)
-- Obs      : pode ser executado de novo (CREATE OR ALTER)
--          : cada procedure le o espelho uma vez (DISTINCT), aplica as
--            functions sobre os valores distintos (de-para em tabela
--            temporaria) e insere so o que e novo (D16)
--          : log (D28): lidas = combinacoes distintas no espelho;
--            gravadas = linhas novas (0 numa reexecucao); SUCESSO sem
--            erro; no CATCH: ROLLBACK, log de ERRO e THROW
--          : erros de negocio 50001-50099
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

-- =====================================================================
-- 1. dim_tempo: pares distintos ano/mes; no_mes via fn_nome_mes (D17)
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.usp_carregar_dim_tempo
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @processo   VARCHAR(60)    = 'usp_carregar_dim_tempo',
            @dt_inicio  DATETIME2(0)   = SYSDATETIME(),
            @referencia VARCHAR(100),
            @ini        VARCHAR(7),
            @fim        VARCHAR(7),
            @lidas      INT            = 0,
            @gravadas   INT            = 0,
            @obs        NVARCHAR(4000);

    BEGIN TRY
        -- meses presentes no espelho (referencia do log)
        SELECT TOP (1) @ini = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO, NU_MES;
        SELECT TOP (1) @fim = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO DESC, NU_MES DESC;
        IF @ini IS NULL
            THROW 50001, N'Espelho staging.pnad_covid_pessoa vazio: execute a ponte antes', 1;
        SET @referencia = IIF(@ini = @fim, @ini, CONCAT(@ini, ' a ', @fim));

        -- combinacoes distintas de ano/mes
        SELECT DISTINCT NU_ANO, NU_MES
          INTO #tempo
          FROM staging.pnad_covid_pessoa;
        SET @lidas = @@ROWCOUNT;

        BEGIN TRANSACTION;

        INSERT INTO dw.dim_tempo (nu_ano, nu_mes, no_mes)
        SELECT t.NU_ANO, t.NU_MES, etl.fn_nome_mes(t.NU_MES)
          FROM #tempo AS t
         WHERE NOT EXISTS (SELECT 1
                             FROM dw.dim_tempo AS d
                            WHERE d.nu_ano = t.NU_ANO
                              AND d.nu_mes = t.NU_MES);
        SET @gravadas = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @obs = CONCAT(@lidas, N' mes(es) no espelho; ', @gravadas, N' novo(s); ',
                          (SELECT COUNT(*) FROM dw.dim_tempo), N' linha(s) na dim_tempo');
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = @gravadas,
             @st_execucao = 'SUCESSO', @ds_observacao = @obs;
        PRINT CONCAT(@processo, ': SUCESSO - ', @obs);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @obs = CONCAT(N'Erro ', ERROR_NUMBER(), N' (linha ', ERROR_LINE(), N'): ', ERROR_MESSAGE());
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = 0,
             @st_execucao = 'ERRO', @ds_observacao = @obs;
        THROW;
    END CATCH
END;
GO

-- =====================================================================
-- 2. dim_municipio: pares distintos UF/capital; sg_uf via fn_uf_sigla;
--    no_municipio = fn_normalizar_texto(fn_municipio_nome(capital));
--    capital vazia = "Demais Municipios" da UF (D06); novo = sg_uf +
--    no_municipio ainda nao existentes
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.usp_carregar_dim_municipio
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @processo   VARCHAR(60)    = 'usp_carregar_dim_municipio',
            @dt_inicio  DATETIME2(0)   = SYSDATETIME(),
            @referencia VARCHAR(100),
            @ini        VARCHAR(7),
            @fim        VARCHAR(7),
            @lidas      INT            = 0,
            @gravadas   INT            = 0,
            @obs        NVARCHAR(4000);

    BEGIN TRY
        SELECT TOP (1) @ini = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO, NU_MES;
        SELECT TOP (1) @fim = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO DESC, NU_MES DESC;
        IF @ini IS NULL
            THROW 50001, N'Espelho staging.pnad_covid_pessoa vazio: execute a ponte antes', 1;
        SET @referencia = IIF(@ini = @fim, @ini, CONCAT(@ini, ' a ', @fim));

        -- pares distintos UF x capital (uma leitura do espelho)
        SELECT DISTINCT UF, CO_MUNICIPIO
          INTO #pares
          FROM staging.pnad_covid_pessoa;
        SET @lidas = @@ROWCOUNT;

        -- de-para: functions sobre os pares distintos
        SELECT p.UF,
               p.CO_MUNICIPIO,
               CAST(etl.fn_uf_sigla(p.UF) AS CHAR(2)) AS sg_uf,
               CAST(etl.fn_normalizar_texto(etl.fn_municipio_nome(p.CO_MUNICIPIO))
                    AS VARCHAR(150))                  AS no_municipio
          INTO #depara_municipio
          FROM #pares AS p;

        BEGIN TRANSACTION;

        -- um item por sg_uf + nome; co_capital so quando o codigo e unico
        -- (codigo fora do dominio vira 'Nao Informado' e fica sem codigo)
        INSERT INTO dw.dim_municipio (co_capital, sg_uf, no_municipio)
        SELECT CASE WHEN MIN(m.CO_MUNICIPIO) = MAX(m.CO_MUNICIPIO)
                    THEN MIN(m.CO_MUNICIPIO) END,
               m.sg_uf,
               m.no_municipio
          FROM #depara_municipio AS m
         WHERE NOT EXISTS (SELECT 1
                             FROM dw.dim_municipio AS d
                            WHERE d.sg_uf        = m.sg_uf
                              AND d.no_municipio = m.no_municipio)
         GROUP BY m.sg_uf, m.no_municipio;
        SET @gravadas = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @obs = CONCAT(@lidas, N' par(es) UF/capital no espelho; ', @gravadas, N' novo(s); ',
                          (SELECT COUNT(*) FROM dw.dim_municipio), N' linha(s) na dim_municipio');
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = @gravadas,
             @st_execucao = 'SUCESSO', @ds_observacao = @obs;
        PRINT CONCAT(@processo, ': SUCESSO - ', @obs);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @obs = CONCAT(N'Erro ', ERROR_NUMBER(), N' (linha ', ERROR_LINE(), N'): ', ERROR_MESSAGE());
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = 0,
             @st_execucao = 'ERRO', @ds_observacao = @obs;
        THROW;
    END CATCH
END;
GO

-- =====================================================================
-- 3. dim_pessoa: combinacoes distintas dos 5 atributos (perfil, D08);
--    faixa etaria via fn_faixa_etaria; sexo M/F por CASE (outro -> I,
--    D13); cor/raca, escolaridade e faixa de rendimento pelas functions
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.usp_carregar_dim_pessoa
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @processo   VARCHAR(60)    = 'usp_carregar_dim_pessoa',
            @dt_inicio  DATETIME2(0)   = SYSDATETIME(),
            @referencia VARCHAR(100),
            @ini        VARCHAR(7),
            @fim        VARCHAR(7),
            @lidas      INT            = 0,
            @gravadas   INT            = 0,
            @obs        NVARCHAR(4000);

    BEGIN TRY
        SELECT TOP (1) @ini = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO, NU_MES;
        SELECT TOP (1) @fim = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO DESC, NU_MES DESC;
        IF @ini IS NULL
            THROW 50001, N'Espelho staging.pnad_covid_pessoa vazio: execute a ponte antes', 1;
        SET @referencia = IIF(@ini = @fim, @ini, CONCAT(@ini, ' a ', @fim));

        -- combinacoes distintas dos 5 codigos de origem (uma leitura)
        SELECT DISTINCT COR_RACA, SEXO, IDADE, ESCOLARIDADE, FAIXA_RENDIMENTO
          INTO #codigos
          FROM staging.pnad_covid_pessoa;

        -- de-para: cada function sobre os valores distintos de um codigo
        SELECT x.co, CAST(etl.fn_cor_raca(x.co) AS VARCHAR(25)) AS ds
          INTO #dp_cor_raca
          FROM (SELECT DISTINCT COR_RACA AS co FROM #codigos) AS x;

        SELECT x.co,
               CAST(CASE x.co WHEN 1 THEN 'M' WHEN 2 THEN 'F' ELSE 'I' END AS CHAR(1)) AS ds
          INTO #dp_sexo
          FROM (SELECT DISTINCT SEXO AS co FROM #codigos) AS x;

        SELECT x.co, CAST(etl.fn_faixa_etaria(x.co) AS VARCHAR(25)) AS ds
          INTO #dp_faixa_etaria
          FROM (SELECT DISTINCT IDADE AS co FROM #codigos) AS x;

        SELECT x.co, CAST(etl.fn_escolaridade(x.co) AS VARCHAR(50)) AS ds
          INTO #dp_escolaridade
          FROM (SELECT DISTINCT ESCOLARIDADE AS co FROM #codigos) AS x;

        SELECT x.co, CAST(etl.fn_faixa_rendimento(x.co) AS VARCHAR(25)) AS ds
          INTO #dp_faixa_rendimento
          FROM (SELECT DISTINCT FAIXA_RENDIMENTO AS co FROM #codigos) AS x;

        -- perfis distintos ja descritos (JOIN que trata NULL como valor)
        SELECT DISTINCT
               c.ds AS cor_raca,
               s.ds AS sexo,
               i.ds AS faixa_etaria,
               e.ds AS escolaridade,
               r.ds AS faixa_rendimento
          INTO #perfil
          FROM #codigos                  AS k
          JOIN #dp_cor_raca          AS c ON c.co IS NOT DISTINCT FROM k.COR_RACA
          JOIN #dp_sexo              AS s ON s.co IS NOT DISTINCT FROM k.SEXO
          JOIN #dp_faixa_etaria      AS i ON i.co IS NOT DISTINCT FROM k.IDADE
          JOIN #dp_escolaridade      AS e ON e.co IS NOT DISTINCT FROM k.ESCOLARIDADE
          JOIN #dp_faixa_rendimento  AS r ON r.co IS NOT DISTINCT FROM k.FAIXA_RENDIMENTO;
        SET @lidas = @@ROWCOUNT;

        BEGIN TRANSACTION;

        INSERT INTO dw.dim_pessoa (cor_raca, sexo, faixa_etaria, escolaridade, faixa_rendimento)
        SELECT p.cor_raca, p.sexo, p.faixa_etaria, p.escolaridade, p.faixa_rendimento
          FROM #perfil AS p
         WHERE NOT EXISTS (SELECT 1
                             FROM dw.dim_pessoa AS d
                            WHERE d.cor_raca         = p.cor_raca
                              AND d.sexo             = p.sexo
                              AND d.faixa_etaria     = p.faixa_etaria
                              AND d.escolaridade     = p.escolaridade
                              AND d.faixa_rendimento = p.faixa_rendimento);
        SET @gravadas = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @obs = CONCAT(@lidas, N' perfil(is) distinto(s) no espelho; ', @gravadas, N' novo(s); ',
                          (SELECT COUNT(*) FROM dw.dim_pessoa), N' linha(s) na dim_pessoa');
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = @gravadas,
             @st_execucao = 'SUCESSO', @ds_observacao = @obs;
        PRINT CONCAT(@processo, ': SUCESSO - ', @obs);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @obs = CONCAT(N'Erro ', ERROR_NUMBER(), N' (linha ', ERROR_LINE(), N'): ', ERROR_MESSAGE());
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = 0,
             @st_execucao = 'ERRO', @ds_observacao = @obs;
        THROW;
    END CATCH
END;
GO

PRINT 'Procedures das dimensoes criadas/atualizadas';
GO

-- conferencia: procedures criadas (esperado: 3)
SELECT  SCHEMA_NAME(p.schema_id) + N'.' + p.name AS procedure_nome,
        p.create_date,
        p.modify_date
FROM    sys.procedures AS p
WHERE   p.object_id IN (OBJECT_ID(N'etl.usp_carregar_dim_tempo'),
                        OBJECT_ID(N'etl.usp_carregar_dim_municipio'),
                        OBJECT_ID(N'etl.usp_carregar_dim_pessoa'))
ORDER BY procedure_nome;
GO
