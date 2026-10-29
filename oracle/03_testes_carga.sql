-- =====================================================================
-- Arquivo  : oracle/03_testes_carga.sql
-- Objetivo : testar PKG_CARGA_PNAD.usp_carregar: sucesso parcial, erro
--            (arquivo inexistente e cabecalho invalido), carga real de
--            maio e recarga sem duplicar
-- Etapa    : E2 - Package de carga
-- Executar : como STAGING no XEPDB1
-- Depende  : oracle/02_pkg_carga_pnad.sql; TESTE_parcial.csv e
--            TESTE_cabecalho.csv na pasta data
-- Obs      : ordem importa - os testes sao de maio e a carga real
--            vem por ultimo, substituindo o mes
--          : colunas com $ (tabela de erros) exibidas por alias: o
--            COLUMN do SQL*Plus nao aceita $ no nome (SP2-0158)
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 250
SET PAGESIZE 100
SET TIMING ON
WHENEVER SQLERROR CONTINUE

-- teste 1: SUCESSO PARCIAL (1 linha com idade invalida)
BEGIN
  pkg_carga_pnad.usp_carregar('TESTE_parcial.csv');
  DBMS_OUTPUT.PUT_LINE('Teste 1 executado (esperado SUCESSO PARCIAL no log)');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Teste 1 FALHOU: ' || SQLERRM);
END;
/

-- teste 2: ERRO - arquivo inexistente
BEGIN
  pkg_carga_pnad.usp_carregar('NAO_EXISTE.csv');
  DBMS_OUTPUT.PUT_LINE('Teste 2 FALHOU: deveria terminar com erro');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Teste 2 OK (erro esperado): ' || SQLERRM);
END;
/

-- teste 3: ERRO - cabecalho sem coluna obrigatoria
BEGIN
  pkg_carga_pnad.usp_carregar('TESTE_cabecalho.csv');
  DBMS_OUTPUT.PUT_LINE('Teste 3 FALHOU: deveria terminar com erro');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Teste 3 OK (erro esperado): ' || SQLERRM);
END;
/

-- teste 4: carga real de maio
BEGIN
  pkg_carga_pnad.usp_carregar('PNAD_COVID_052020.csv');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Teste 4 FALHOU: ' || SQLERRM);
END;
/

-- teste 5: recarga de maio (nao pode duplicar)
BEGIN
  pkg_carga_pnad.usp_carregar('PNAD_COVID_052020.csv');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Teste 5 FALHOU: ' || SQLERRM);
END;
/

SET TIMING OFF

-- conferencia 1: log de todas as execucoes
COLUMN no_arquivo    FORMAT A22
COLUMN st_execucao   FORMAT A16
COLUMN observacao    FORMAT A110
COLUMN duracao_s     FORMAT 9999

SELECT id_log,
       no_arquivo,
       qt_linhas_lidas      AS lidas,
       qt_linhas_gravadas   AS gravadas,
       qt_linhas_rejeitadas AS rejeitadas,
       st_execucao,
       ROUND((dt_fim - dt_inicio) * 86400) AS duracao_s,
       SUBSTR(ds_observacao, 1, 110) AS observacao
  FROM log_carga
 ORDER BY id_log;

-- conferencia 2: linha rejeitada no teste 1
COLUMN mensagem_erro FORMAT A45
COLUMN tag_carga     FORMAT A40
COLUMN idade         FORMAT A8

SELECT ora_err_number$ AS numero_erro,
       ora_err_mesg$   AS mensagem_erro,
       idade,
       ora_err_tag$    AS tag_carga
  FROM err$_pnad_covid_pessoa
 WHERE ora_err_tag$ LIKE 'TESTE_parcial.csv%';

-- conferencia 3: staging so com maio, sem duplicar
SELECT nu_ano, nu_mes, COUNT(*) AS linhas
  FROM pnad_covid_pessoa
 GROUP BY nu_ano, nu_mes
 ORDER BY nu_ano, nu_mes;

-- conferencia 4: perfil de maio x dados_fonte.md (secao 3)
SELECT SUM(CASE WHEN sexo = 1 THEN 1 ELSE 0 END)                AS homens_167712,
       SUM(CASE WHEN sexo = 2 THEN 1 ELSE 0 END)                AS mulheres_181594,
       COUNT(co_municipio)                                      AS capital_82115,
       COUNT(faixa_rendimento)                                  AS renda_preench_132375,
       SUM(CASE WHEN atendimento_sus = 1 THEN 1 ELSE 0 END)     AS sus_sim_1369,
       SUM(CASE WHEN internado = 1 THEN 1 ELSE 0 END)           AS internado_sim_200,
       SUM(CASE WHEN 1 IN (sintoma_febre, sintoma_tosse, sintoma_dor_garganta,
                           sintoma_dificuldade_respirar, sintoma_dor_cabeca,
                           sintoma_dor_peito, sintoma_nausea, sintoma_nariz,
                           sintoma_fadiga, sintoma_dor_olhos,
                           sintoma_perda_cheiro_sabor, sintoma_dor_muscular)
                THEN 1 ELSE 0 END)                              AS algum_sintoma_38166,
       MIN(idade) AS idade_min_0,
       MAX(idade) AS idade_max_111
  FROM pnad_covid_pessoa
 WHERE nu_ano = 2020 AND nu_mes = 5;
