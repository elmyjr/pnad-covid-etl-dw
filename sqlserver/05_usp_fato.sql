-- =====================================================================
-- Arquivo  : sqlserver/05_usp_fato.sql
-- Objetivo : procedure etl.usp_carregar_fato: resolve as chaves das tres
--            dimensoes, agrega as medidas e grava dw.fato_pnad_covid,
--            substituindo os meses presentes no espelho
-- Etapa    : E7 - Fato e procedure principal
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : 02_ddl_dw.sql, 03_functions.sql, 04_usp_dimensoes.sql
--            (dimensoes carregadas antes da fato)
-- Obs      : pode ser executado de novo (CREATE OR ALTER)
--          : grao: mes x municipio x perfil (D09); medidas (D10):
--            qtd_pessoas = linhas; atendimento_SUS e internado = codigo
--            1; sintoma = pelo menos um dos 12 sintomas = 1
--          : functions aplicadas sobre valores distintos (mapas de
--            codigo -> chave em tabelas temporarias) e JOIN depois;
--            codigo NULL vira -1 nos mapas para o JOIN casar (os
--            codigos validos sao >= 0)
--          : na transacao: DELETE dos meses do espelho + conferencia de
--            linhas sem chave (50002) + INSERT + conferencia
--            SUM(qtd_pessoas) = linhas lidas (50003); erro -> ROLLBACK,
--            log de ERRO e THROW (D16, D28)
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

CREATE OR ALTER PROCEDURE etl.usp_carregar_fato
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @processo     VARCHAR(60)    = 'usp_carregar_fato',
            @dt_inicio    DATETIME2(0)   = SYSDATETIME(),
            @referencia   VARCHAR(100),
            @ini          VARCHAR(7),
            @fim          VARCHAR(7),
            @lidas        INT            = 0,
            @gravadas     INT            = 0,
            @substituidas INT            = 0,
            @sem_chave    INT            = 0,
            @soma         INT            = 0,
            @msg          NVARCHAR(2048),
            @obs          NVARCHAR(4000);

    BEGIN TRY
        -- meses presentes no espelho (referencia do log)
        SELECT TOP (1) @ini = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO, NU_MES;
        SELECT TOP (1) @fim = CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
          FROM staging.pnad_covid_pessoa ORDER BY NU_ANO DESC, NU_MES DESC;
        IF @ini IS NULL
            THROW 50001, N'Espelho staging.pnad_covid_pessoa vazio: execute a ponte antes', 1;
        SET @referencia = IIF(@ini = @fim, @ini, CONCAT(@ini, ' a ', @fim));

        SELECT @lidas = COUNT(*) FROM staging.pnad_covid_pessoa;

        -- -------------------------------------------------------------
        -- 1. Mapas de codigo -> chave (valores distintos do espelho)
        -- -------------------------------------------------------------
        -- tempo
        SELECT t.NU_ANO, t.NU_MES, d.sk_tempo
          INTO #mapa_tempo
          FROM (SELECT DISTINCT NU_ANO, NU_MES FROM staging.pnad_covid_pessoa) AS t
          LEFT JOIN dw.dim_tempo AS d
                 ON d.nu_ano = t.NU_ANO
                AND d.nu_mes = t.NU_MES;

        -- municipio: mesma regra da usp_carregar_dim_municipio
        SELECT p.uf,
               p.cap,
               CAST(etl.fn_uf_sigla(NULLIF(p.uf, -1)) AS CHAR(2)) AS sg_uf,
               CAST(etl.fn_normalizar_texto(etl.fn_municipio_nome(NULLIF(p.cap, -1)))
                    AS VARCHAR(150))                             AS no_municipio
          INTO #desc_municipio
          FROM (SELECT DISTINCT ISNULL(UF, -1) AS uf, ISNULL(CO_MUNICIPIO, -1) AS cap
                  FROM staging.pnad_covid_pessoa) AS p;

        SELECT m.uf, m.cap, d.sk_municipio
          INTO #mapa_municipio
          FROM #desc_municipio AS m
          LEFT JOIN dw.dim_municipio AS d
                 ON d.sg_uf        = m.sg_uf
                AND d.no_municipio = m.no_municipio;

        -- pessoa: combinacoes distintas dos 5 codigos
        SELECT DISTINCT
               ISNULL(COR_RACA, -1)         AS cor,
               ISNULL(SEXO, -1)             AS sexo,
               ISNULL(IDADE, -1)            AS idade,
               ISNULL(ESCOLARIDADE, -1)     AS esc,
               ISNULL(FAIXA_RENDIMENTO, -1) AS renda
          INTO #codigos_pessoa
          FROM staging.pnad_covid_pessoa;

        -- descricoes por atributo: mesma regra da usp_carregar_dim_pessoa
        SELECT x.co, CAST(etl.fn_cor_raca(NULLIF(x.co, -1)) AS VARCHAR(25)) AS ds
          INTO #dp_cor_raca
          FROM (SELECT DISTINCT cor AS co FROM #codigos_pessoa) AS x;

        SELECT x.co,
               CAST(CASE x.co WHEN 1 THEN 'M' WHEN 2 THEN 'F' ELSE 'I' END AS CHAR(1)) AS ds
          INTO #dp_sexo
          FROM (SELECT DISTINCT sexo AS co FROM #codigos_pessoa) AS x;

        SELECT x.co, CAST(etl.fn_faixa_etaria(NULLIF(x.co, -1)) AS VARCHAR(25)) AS ds
          INTO #dp_faixa_etaria
          FROM (SELECT DISTINCT idade AS co FROM #codigos_pessoa) AS x;

        SELECT x.co, CAST(etl.fn_escolaridade(NULLIF(x.co, -1)) AS VARCHAR(50)) AS ds
          INTO #dp_escolaridade
          FROM (SELECT DISTINCT esc AS co FROM #codigos_pessoa) AS x;

        SELECT x.co, CAST(etl.fn_faixa_rendimento(NULLIF(x.co, -1)) AS VARCHAR(25)) AS ds
          INTO #dp_faixa_rendimento
          FROM (SELECT DISTINCT renda AS co FROM #codigos_pessoa) AS x;

        SELECT k.cor, k.sexo, k.idade, k.esc, k.renda, d.sk_pessoa
          INTO #mapa_pessoa
          FROM #codigos_pessoa          AS k
          JOIN #dp_cor_raca         AS c ON c.co = k.cor
          JOIN #dp_sexo             AS s ON s.co = k.sexo
          JOIN #dp_faixa_etaria     AS i ON i.co = k.idade
          JOIN #dp_escolaridade     AS e ON e.co = k.esc
          JOIN #dp_faixa_rendimento AS r ON r.co = k.renda
          LEFT JOIN dw.dim_pessoa   AS d
                 ON d.cor_raca         = c.ds
                AND d.sexo             = s.ds
                AND d.faixa_etaria     = i.ds
                AND d.escolaridade     = e.ds
                AND d.faixa_rendimento = r.ds;

        -- -------------------------------------------------------------
        -- 2. Chaves resolvidas e medidas agregadas (uma leitura)
        -- -------------------------------------------------------------
        SELECT mt.sk_tempo,
               mm.sk_municipio,
               mp.sk_pessoa,
               COUNT(*)                                                AS qtd_pessoas,
               SUM(CASE WHEN s.ATENDIMENTO_SUS = 1 THEN 1 ELSE 0 END)  AS atendimento_sus,
               SUM(CASE WHEN s.INTERNADO = 1 THEN 1 ELSE 0 END)        AS internado,
               SUM(CASE WHEN 1 IN (s.SINTOMA_FEBRE, s.SINTOMA_TOSSE, s.SINTOMA_DOR_GARGANTA,
                                   s.SINTOMA_DIFICULDADE_RESPIRAR, s.SINTOMA_DOR_CABECA,
                                   s.SINTOMA_DOR_PEITO, s.SINTOMA_NAUSEA, s.SINTOMA_NARIZ,
                                   s.SINTOMA_FADIGA, s.SINTOMA_DOR_OLHOS,
                                   s.SINTOMA_PERDA_CHEIRO_SABOR, s.SINTOMA_DOR_MUSCULAR)
                        THEN 1 ELSE 0 END)                             AS sintoma
          INTO #fato
          FROM staging.pnad_covid_pessoa AS s
          LEFT JOIN #mapa_tempo     AS mt
                 ON mt.NU_ANO = s.NU_ANO
                AND mt.NU_MES = s.NU_MES
          LEFT JOIN #mapa_municipio AS mm
                 ON mm.uf  = ISNULL(s.UF, -1)
                AND mm.cap = ISNULL(s.CO_MUNICIPIO, -1)
          LEFT JOIN #mapa_pessoa    AS mp
                 ON mp.cor   = ISNULL(s.COR_RACA, -1)
                AND mp.sexo  = ISNULL(s.SEXO, -1)
                AND mp.idade = ISNULL(s.IDADE, -1)
                AND mp.esc   = ISNULL(s.ESCOLARIDADE, -1)
                AND mp.renda = ISNULL(s.FAIXA_RENDIMENTO, -1)
         GROUP BY mt.sk_tempo, mm.sk_municipio, mp.sk_pessoa;

        -- -------------------------------------------------------------
        -- 3. Gravacao: substitui os meses do espelho, numa transacao
        -- -------------------------------------------------------------
        BEGIN TRANSACTION;

        DELETE f
          FROM dw.fato_pnad_covid AS f
          JOIN #mapa_tempo        AS mt ON mt.sk_tempo = f.sk_tempo;
        SET @substituidas = @@ROWCOUNT;

        -- linhas do espelho sem alguma das tres chaves: ERRO e ROLLBACK
        SELECT @sem_chave = ISNULL(SUM(qtd_pessoas), 0)
          FROM #fato
         WHERE sk_tempo IS NULL OR sk_municipio IS NULL OR sk_pessoa IS NULL;
        IF @sem_chave > 0
        BEGIN
            SET @msg = CONCAT(@sem_chave, N' linha(s) do espelho sem chave de dimensao ',
                              N'(tempo: ', (SELECT ISNULL(SUM(qtd_pessoas), 0) FROM #fato WHERE sk_tempo IS NULL),
                              N'; municipio: ', (SELECT ISNULL(SUM(qtd_pessoas), 0) FROM #fato WHERE sk_municipio IS NULL),
                              N'; pessoa: ', (SELECT ISNULL(SUM(qtd_pessoas), 0) FROM #fato WHERE sk_pessoa IS NULL),
                              N'). Execute as procedures das dimensoes antes da fato');
            THROW 50002, @msg, 1;
        END;

        INSERT INTO dw.fato_pnad_covid
               (sk_tempo, sk_municipio, sk_pessoa, qtd_pessoas, atendimento_SUS, internado, sintoma)
        SELECT sk_tempo, sk_municipio, sk_pessoa, qtd_pessoas, atendimento_sus, internado, sintoma
          FROM #fato;
        SET @gravadas = @@ROWCOUNT;

        -- conferencia: pessoas na fato dos meses carregados = linhas lidas
        SELECT @soma = ISNULL(SUM(f.qtd_pessoas), 0)
          FROM dw.fato_pnad_covid AS f
          JOIN #mapa_tempo        AS mt ON mt.sk_tempo = f.sk_tempo;
        IF @soma <> @lidas
        BEGIN
            SET @msg = CONCAT(N'SUM(qtd_pessoas) na fato = ', @soma,
                              N' diferente das linhas lidas do espelho = ', @lidas);
            THROW 50003, @msg, 1;
        END;

        COMMIT TRANSACTION;

        SET @obs = CONCAT(@lidas, N' linhas do espelho (', @referencia, N') agregadas em ',
                          @gravadas, N' linhas da fato; SUM(qtd_pessoas) = ', @soma,
                          N'; substituidas ', @substituidas, N' linhas dos mesmos meses');
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = @gravadas,
             @st_execucao = 'SUCESSO', @ds_observacao = @obs;
        PRINT CONCAT(@processo, ': SUCESSO - ', @obs);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @obs = CONCAT(N'Erro ', ERROR_NUMBER(), N' (linha ', ERROR_LINE(), N'): ', ERROR_MESSAGE(),
                          N' | ROLLBACK: fato sem alteracao');
        EXEC etl.usp_registrar_log
             @no_processo = @processo, @ds_referencia = @referencia, @dt_inicio = @dt_inicio,
             @qt_linhas_lidas = @lidas, @qt_linhas_gravadas = 0,
             @st_execucao = 'ERRO', @ds_observacao = @obs;
        THROW;
    END CATCH
END;
GO

PRINT 'Procedure etl.usp_carregar_fato criada/atualizada';
GO

-- conferencia: procedure criada
SELECT  SCHEMA_NAME(p.schema_id) + N'.' + p.name AS procedure_nome,
        p.create_date,
        p.modify_date
FROM    sys.procedures AS p
WHERE   p.object_id = OBJECT_ID(N'etl.usp_carregar_fato');
GO
