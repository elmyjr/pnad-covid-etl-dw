-- =====================================================================
-- Arquivo  : sqlserver/06_usp_carregar_dw.sql
-- Objetivo : procedure principal etl.usp_carregar_dw: chama as quatro
--            cargas em ordem (tempo -> municipio -> pessoa -> fato) e
--            registra o resultado do conjunto no log
-- Etapa    : E7 - Fato e procedure principal
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : 04_usp_dimensoes.sql e 05_usp_fato.sql
-- Obs      : pode ser executado de novo (CREATE OR ALTER)
--          : sem transacao externa: cada etapa tem a sua (COMMIT,
--            ROLLBACK e log proprios); para na primeira etapa com erro,
--            e reexecutar e seguro, porque as dimensoes inserem so o
--            novo e a fato substitui os meses do espelho (D16)
--          : log (D28): lidas = linhas do espelho; gravadas = linhas da
--            fato nos meses do espelho; no CATCH: log de ERRO com a
--            etapa que falhou e THROW
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

CREATE OR ALTER PROCEDURE etl.usp_carregar_dw
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @processo   VARCHAR(60)    = 'usp_carregar_dw',
            @dt_inicio  DATETIME2(0)   = SYSDATETIME(),
            @referencia VARCHAR(100),
            @ini        VARCHAR(7),
            @fim        VARCHAR(7),
            @etapa      VARCHAR(60)    = 'inicio',
            @lidas      INT            = 0,
            @gravadas   INT            = 0,
            @soma       INT            = 0,
            @obs        NVARCHAR(4000);

    BEGIN TRY
        SELECT TOP (1) @ini = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO, NU_MES;
        SELECT TOP (1) @fim = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO DESC, NU_MES DESC;
        IF @ini IS NULL
            THROW 50001, N'Espelho staging.pnad_covid_pessoa vazio: execute a ponte antes', 1;
        SET @referencia = IIF(@ini = @fim, @ini, CONCAT(@ini, ' a ', @fim));

        SELECT @lidas = COUNT(*) FROM staging.pnad_covid_pessoa;

        -- ordem obrigatoria: dimensoes antes da fato
        SET @etapa = 'usp_carregar_dim_tempo';
        EXEC etl.usp_carregar_dim_tempo;

        SET @etapa = 'usp_carregar_dim_municipio';
        EXEC etl.usp_carregar_dim_municipio;

        SET @etapa = 'usp_carregar_dim_pessoa';
        EXEC etl.usp_carregar_dim_pessoa;

        SET @etapa = 'usp_carregar_fato';
        EXEC etl.usp_carregar_fato;

        -- resultado: linhas e pessoas da fato nos meses do espelho
        SET @etapa = 'conferencia';
        SELECT @gravadas = COUNT(*),
               @soma     = ISNULL(SUM(f.qtd_pessoas), 0)
          FROM dw.fato_pnad_covid AS f
          JOIN dw.dim_tempo       AS t ON t.sk_tempo = f.sk_tempo
         WHERE EXISTS (SELECT 1
                         FROM staging.pnad_covid_pessoa AS s
                        WHERE s.NU_ANO = t.nu_ano
                          AND s.NU_MES = t.nu_mes);

        SET @obs = CONCAT(N'4 etapas com SUCESSO (tempo, municipio, pessoa, fato); dimensoes com ',
                          (SELECT COUNT(*) FROM dw.dim_tempo), N' / ',
                          (SELECT COUNT(*) FROM dw.dim_municipio), N' / ',
                          (SELECT COUNT(*) FROM dw.dim_pessoa), N' linhas; fato com ',
                          @gravadas, N' linhas nos meses do espelho; SUM(qtd_pessoas) = ', @soma);
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = @gravadas,
             @st_execucao = 'SUCESSO', @ds_observacao = @obs;
        PRINT CONCAT(@processo, ': SUCESSO - ', @obs);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @obs = CONCAT(N'Falha na etapa ', @etapa, N' - Erro ', ERROR_NUMBER(), N': ', ERROR_MESSAGE());
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = 0,
             @st_execucao = 'ERRO', @ds_observacao = @obs;
        THROW;
    END CATCH
END;
GO

PRINT 'Procedure etl.usp_carregar_dw criada/atualizada';
GO

-- conferencia: as 5 procedures do DW e a de log (esperado: 6)
SELECT  SCHEMA_NAME(p.schema_id) + N'.' + p.name AS procedure_nome,
        p.modify_date
FROM    sys.procedures AS p
WHERE   p.schema_id = SCHEMA_ID(N'etl')
ORDER BY procedure_nome;
GO
