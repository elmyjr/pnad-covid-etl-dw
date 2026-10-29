-- =====================================================================
-- Arquivo  : sqlserver/07_validacao.sql
-- Objetivo : validar a carga completa: reconciliacao por mes (staging
--            Oracle = espelho = SUM(qtd_pessoas)), medidas da fato =
--            contagens no espelho, integridade do DW, situacao do log e
--            consultas analiticas de exemplo
-- Etapa    : E9 - Validacao
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid, depois do pipeline (E8)
-- Depende  : espelho, DW e etl.log_execucao carregados
-- Obs      : somente leitura (nao altera dados); pode ser executado de
--            novo
--          : "staging Oracle" = linhas do mes contadas no Oracle pela
--            ponte (ultima copia com SUCESSO no etl.log_execucao); a
--            comparacao arquivo = staging Oracle fica no LOG_CARGA
--          : medidas contam entrevistados, sem o peso amostral V1032
--            (D09): os percentuais sao da amostra, nao da populacao
-- =====================================================================

SET NOCOUNT ON;
GO

USE db_pnad_covid;
GO

-- =====================================================================
-- 1. Reconciliacao por mes: linhas e medidas
--    staging Oracle = espelho = SUM(qtd_pessoas) e medidas da fato =
--    contagens no espelho (esperado: OK em todas as linhas)
-- =====================================================================
WITH ponte AS (
    SELECT ds_referencia,
           qt_linhas_lidas AS staging_oracle,
           ROW_NUMBER() OVER (PARTITION BY ds_referencia ORDER BY id_log DESC) AS ordem
      FROM etl.log_execucao
     WHERE no_processo = 'ponte_oracle_sqlserver'
       AND st_execucao = 'SUCESSO'
),
espelho AS (
    SELECT NU_ANO, NU_MES,
           COUNT(*)                                             AS linhas,
           SUM(CASE WHEN ATENDIMENTO_SUS = 1 THEN 1 ELSE 0 END) AS sus,
           SUM(CASE WHEN INTERNADO = 1 THEN 1 ELSE 0 END)       AS internado,
           SUM(CASE WHEN 1 IN (SINTOMA_FEBRE, SINTOMA_TOSSE, SINTOMA_DOR_GARGANTA,
                               SINTOMA_DIFICULDADE_RESPIRAR, SINTOMA_DOR_CABECA,
                               SINTOMA_DOR_PEITO, SINTOMA_NAUSEA, SINTOMA_NARIZ,
                               SINTOMA_FADIGA, SINTOMA_DOR_OLHOS,
                               SINTOMA_PERDA_CHEIRO_SABOR, SINTOMA_DOR_MUSCULAR)
                    THEN 1 ELSE 0 END)                          AS sintoma
      FROM staging.pnad_covid_pessoa
     GROUP BY NU_ANO, NU_MES
),
fato AS (
    SELECT t.nu_ano, t.nu_mes,
           COUNT(*)               AS linhas_fato,
           SUM(f.qtd_pessoas)     AS pessoas,
           SUM(f.atendimento_SUS) AS sus,
           SUM(f.internado)       AS internado,
           SUM(f.sintoma)         AS sintoma
      FROM dw.fato_pnad_covid AS f
      JOIN dw.dim_tempo       AS t ON t.sk_tempo = f.sk_tempo
     GROUP BY t.nu_ano, t.nu_mes
),
mes AS (
    SELECT COALESCE(e.NU_ANO, f.nu_ano) AS nu_ano,
           COALESCE(e.NU_MES, f.nu_mes) AS nu_mes,
           e.linhas, e.sus AS e_sus, e.internado AS e_internado, e.sintoma AS e_sintoma,
           f.linhas_fato, f.pessoas, f.sus AS f_sus, f.internado AS f_internado, f.sintoma AS f_sintoma
      FROM espelho AS e
      FULL JOIN fato AS f ON f.nu_ano = e.NU_ANO AND f.nu_mes = e.NU_MES
)
SELECT  CONCAT(m.nu_ano, '-', RIGHT(CONCAT('0', m.nu_mes), 2))  AS referencia,
        p.staging_oracle,
        m.linhas                                               AS espelho,
        m.pessoas                                              AS fato_qtd_pessoas,
        CASE WHEN p.staging_oracle = m.linhas AND m.linhas = m.pessoas
             THEN 'OK' ELSE 'DIVERGENTE' END                   AS linhas_ok,
        m.linhas_fato,
        m.e_sus, m.f_sus, m.e_internado, m.f_internado, m.e_sintoma, m.f_sintoma,
        CASE WHEN m.e_sus = m.f_sus AND m.e_internado = m.f_internado
                  AND m.e_sintoma = m.f_sintoma
             THEN 'OK' ELSE 'DIVERGENTE' END                   AS medidas_ok
FROM    mes AS m
LEFT JOIN ponte AS p
       ON p.ds_referencia = CONCAT(m.nu_ano, '-', RIGHT(CONCAT('0', m.nu_mes), 2))
      AND p.ordem = 1
ORDER BY m.nu_ano, m.nu_mes;

-- totais (esperado: 2.650.459 em espelho e fato; 201.564 linhas na fato;
-- 7.187 SUS; 1.524 internados; 157.378 com algum sintoma)
SELECT  (SELECT COUNT(*) FROM staging.pnad_covid_pessoa)       AS espelho_linhas,
        (SELECT SUM(qtd_pessoas) FROM dw.fato_pnad_covid)      AS fato_qtd_pessoas,
        (SELECT COUNT(*) FROM dw.fato_pnad_covid)              AS fato_linhas,
        (SELECT SUM(atendimento_SUS) FROM dw.fato_pnad_covid)  AS fato_sus,
        (SELECT SUM(internado) FROM dw.fato_pnad_covid)        AS fato_internado,
        (SELECT SUM(sintoma) FROM dw.fato_pnad_covid)          AS fato_sintoma;
GO

-- =====================================================================
-- 2. Integridade do DW (esperado: 0 em todas as colunas de problema)
-- =====================================================================
SELECT  -- linhas da fato sem dimensao (as FKs tambem impedem)
        (SELECT COUNT(*) FROM dw.fato_pnad_covid AS f
          WHERE NOT EXISTS (SELECT 1 FROM dw.dim_tempo AS t WHERE t.sk_tempo = f.sk_tempo))             AS fato_sem_tempo,
        (SELECT COUNT(*) FROM dw.fato_pnad_covid AS f
          WHERE NOT EXISTS (SELECT 1 FROM dw.dim_municipio AS m WHERE m.sk_municipio = f.sk_municipio)) AS fato_sem_municipio,
        (SELECT COUNT(*) FROM dw.fato_pnad_covid AS f
          WHERE NOT EXISTS (SELECT 1 FROM dw.dim_pessoa AS p WHERE p.sk_pessoa = f.sk_pessoa))          AS fato_sem_pessoa,
        -- FKs desabilitadas ou nao confiaveis
        (SELECT COUNT(*) FROM sys.foreign_keys
          WHERE parent_object_id = OBJECT_ID(N'dw.fato_pnad_covid')
            AND (is_disabled = 1 OR is_not_trusted = 1))                                               AS fk_com_problema,
        -- medidas incoerentes (o CHECK tambem impede)
        (SELECT COUNT(*) FROM dw.fato_pnad_covid
          WHERE atendimento_SUS > qtd_pessoas OR internado > qtd_pessoas OR sintoma > qtd_pessoas)       AS medida_maior_que_pessoas,
        -- itens "Nao informado" (codigo fora do dicionario, D14)
        (SELECT COUNT(*) FROM dw.dim_pessoa
          WHERE N'Não informado' IN (cor_raca, faixa_etaria, escolaridade, faixa_rendimento)
             OR sexo = 'I')                                                                            AS pessoa_nao_informado,
        (SELECT COUNT(*) FROM dw.dim_municipio
          WHERE sg_uf IN ('NA', 'NI') OR no_municipio = 'Nao Informado')                               AS municipio_nao_informado;

-- tamanho das dimensoes e uso pela fato (esperado: 7 / 53 / 2.131, todas usadas)
SELECT 'dim_tempo' AS dimensao,
       (SELECT COUNT(*) FROM dw.dim_tempo) AS linhas,
       (SELECT COUNT(DISTINCT sk_tempo) FROM dw.fato_pnad_covid) AS usadas_na_fato
UNION ALL
SELECT 'dim_municipio',
       (SELECT COUNT(*) FROM dw.dim_municipio),
       (SELECT COUNT(DISTINCT sk_municipio) FROM dw.fato_pnad_covid)
UNION ALL
SELECT 'dim_pessoa',
       (SELECT COUNT(*) FROM dw.dim_pessoa),
       (SELECT COUNT(DISTINCT sk_pessoa) FROM dw.fato_pnad_covid);
GO

-- =====================================================================
-- 3. Situacao do log: ultima execucao de cada processo (ponte: de cada
--    mes do espelho) - esperado: SUCESSO em todas
-- =====================================================================
WITH ultima AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY no_processo,
                            CASE WHEN no_processo = 'ponte_oracle_sqlserver' THEN ds_referencia END
               ORDER BY id_log DESC) AS ordem
      FROM etl.log_execucao
)
SELECT  id_log, no_processo, ds_referencia, qt_linhas_lidas AS lidas, qt_linhas_gravadas AS gravadas,
        st_execucao, dt_inicio, DATEDIFF(SECOND, dt_inicio, dt_fim) AS duracao_s
FROM    ultima
WHERE   ordem = 1
  AND   (no_processo <> 'ponte_oracle_sqlserver'
         OR ds_referencia IN (SELECT DISTINCT CONCAT(NU_ANO, '-', RIGHT(CONCAT('0', NU_MES), 2))
                                FROM staging.pnad_covid_pessoa))
ORDER BY id_log;
GO

-- =====================================================================
-- 4. Consultas analiticas de exemplo (amostra, sem peso - D09)
-- =====================================================================

-- 4.1 Evolucao mensal: % de entrevistados com algum sintoma, % que
--     buscaram pronto-socorro do SUS/UPA e internados por 100 mil
SELECT  t.nu_mes,
        t.no_mes,
        SUM(f.qtd_pessoas)                                                       AS entrevistados,
        CAST(100.0 * SUM(f.sintoma) / SUM(f.qtd_pessoas) AS DECIMAL(5, 2))        AS pct_com_sintoma,
        CAST(100.0 * SUM(f.atendimento_SUS) / SUM(f.qtd_pessoas) AS DECIMAL(5, 2)) AS pct_sus,
        CAST(100000.0 * SUM(f.internado) / SUM(f.qtd_pessoas) AS DECIMAL(7, 1))  AS internados_100mil
FROM    dw.fato_pnad_covid AS f
JOIN    dw.dim_tempo       AS t ON t.sk_tempo = f.sk_tempo
GROUP BY t.nu_ano, t.nu_mes, t.no_mes
ORDER BY t.nu_ano, t.nu_mes;

-- 4.2 UFs com maior % de entrevistados com sintoma no periodo
SELECT  TOP (10)
        m.sg_uf,
        SUM(f.qtd_pessoas)                                                AS entrevistados,
        SUM(f.sintoma)                                                    AS com_sintoma,
        CAST(100.0 * SUM(f.sintoma) / SUM(f.qtd_pessoas) AS DECIMAL(5, 2)) AS pct_com_sintoma
FROM    dw.fato_pnad_covid AS f
JOIN    dw.dim_municipio   AS m ON m.sk_municipio = f.sk_municipio
GROUP BY m.sg_uf
ORDER BY pct_com_sintoma DESC;

-- 4.3 Capital x demais municipios, por mes: % com sintoma
SELECT  t.nu_mes,
        t.no_mes,
        CAST(100.0 * SUM(CASE WHEN m.co_capital IS NOT NULL THEN f.sintoma END)
             / SUM(CASE WHEN m.co_capital IS NOT NULL THEN f.qtd_pessoas END) AS DECIMAL(5, 2)) AS pct_sintoma_capitais,
        CAST(100.0 * SUM(CASE WHEN m.co_capital IS NULL THEN f.sintoma END)
             / SUM(CASE WHEN m.co_capital IS NULL THEN f.qtd_pessoas END) AS DECIMAL(5, 2))     AS pct_sintoma_demais
FROM    dw.fato_pnad_covid AS f
JOIN    dw.dim_tempo       AS t ON t.sk_tempo = f.sk_tempo
JOIN    dw.dim_municipio   AS m ON m.sk_municipio = f.sk_municipio
GROUP BY t.nu_ano, t.nu_mes, t.no_mes
ORDER BY t.nu_ano, t.nu_mes;

-- 4.4 Faixa etaria: entrevistados, % com sintoma e internados por 100 mil
SELECT  p.faixa_etaria,
        SUM(f.qtd_pessoas)                                                      AS entrevistados,
        CAST(100.0 * SUM(f.sintoma) / SUM(f.qtd_pessoas) AS DECIMAL(5, 2))       AS pct_com_sintoma,
        CAST(100000.0 * SUM(f.internado) / SUM(f.qtd_pessoas) AS DECIMAL(7, 1)) AS internados_100mil
FROM    dw.fato_pnad_covid AS f
JOIN    dw.dim_pessoa      AS p ON p.sk_pessoa = f.sk_pessoa
GROUP BY p.faixa_etaria
ORDER BY MIN(CASE p.faixa_etaria WHEN N'Criança/Adolescente' THEN 1 WHEN 'Jovem Adulto' THEN 2
                                 WHEN 'Adulto' THEN 3 WHEN 'Idoso' THEN 4 ELSE 5 END);

-- 4.5 Faixa de rendimento (quem tinha trabalho remunerado): % com sintoma
SELECT  p.faixa_rendimento,
        SUM(f.qtd_pessoas)                                                AS entrevistados,
        CAST(100.0 * SUM(f.sintoma) / SUM(f.qtd_pessoas) AS DECIMAL(5, 2)) AS pct_com_sintoma
FROM    dw.fato_pnad_covid AS f
JOIN    dw.dim_pessoa      AS p ON p.sk_pessoa = f.sk_pessoa
GROUP BY p.faixa_rendimento
ORDER BY MIN(CASE p.faixa_rendimento
                 WHEN '0 - 100' THEN 0 WHEN '101 - 300' THEN 1 WHEN '301 - 600' THEN 2
                 WHEN '601 - 800' THEN 3 WHEN '801 - 1.600' THEN 4 WHEN '1.601 - 3.000' THEN 5
                 WHEN '3.001 - 10.000' THEN 6 WHEN '10.001 - 50.000' THEN 7
                 WHEN '50.001 - 100.000' THEN 8 WHEN 'Mais de 100.000' THEN 9 ELSE 10 END);
GO
