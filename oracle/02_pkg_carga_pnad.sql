-- =====================================================================
-- Arquivo  : oracle/02_pkg_carga_pnad.sql
-- Objetivo : package PKG_CARGA_PNAD - carga de um CSV da PNAD COVID na
--            staging, com colunas localizadas pelo nome no cabecalho
-- Etapa    : E2 - Package de carga
-- Executar : como STAGING no XEPDB1
-- Depende  : oracle/01_ddl_staging.sql; DIRECTORYs DIR_PNAD_DADOS e
--            DIR_PNAD_LOG; UTL_FILE (grant a PUBLIC)
-- Fluxo    : nome valido -> cabecalho e contagem (UTL_FILE) -> colunas
--            obrigatorias -> tabela externa dinamica -> DELETE do mes ->
--            INSERT com LOG ERRORS -> status -> log autonomo
-- Obs      : a tabela externa e criada antes do DELETE porque DDL faz
--            commit implicito
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

CREATE OR REPLACE PACKAGE pkg_carga_pnad AS

  -- carrega um CSV (nome do arquivo em DIR_PNAD_DADOS) na staging
  PROCEDURE usp_carregar(p_no_arquivo IN VARCHAR2);

  -- devolve as colunas obrigatorias ausentes no cabecalho (NULL = ok)
  FUNCTION fn_colunas_ausentes(p_cabecalho IN VARCHAR2) RETURN VARCHAR2;

END pkg_carga_pnad;
/

CREATE OR REPLACE PACKAGE BODY pkg_carga_pnad AS

  c_dir_dados CONSTANT VARCHAR2(30) := 'DIR_PNAD_DADOS';
  c_dir_log   CONSTANT VARCHAR2(30) := 'DIR_PNAD_LOG';
  c_tab_ext   CONSTANT VARCHAR2(30) := 'PNAD_COVID_EXT';

  TYPE t_lista IS TABLE OF VARCHAR2(128);

  TYPE t_mapa IS RECORD (
    col_stg VARCHAR2(30),
    col_csv VARCHAR2(30)
  );
  TYPE t_lista_mapa IS TABLE OF t_mapa;

  -- ---------------------------------------------------------------
  -- mapeamento staging x CSV (secao 4 da especificacao), em ordem
  -- ---------------------------------------------------------------
  FUNCTION fn_mapa RETURN t_lista_mapa IS
    v_mapa t_lista_mapa := t_lista_mapa();

    PROCEDURE incluir(p_stg IN VARCHAR2, p_csv IN VARCHAR2) IS
    BEGIN
      v_mapa.EXTEND;
      v_mapa(v_mapa.LAST).col_stg := p_stg;
      v_mapa(v_mapa.LAST).col_csv := p_csv;
    END incluir;
  BEGIN
    incluir('NU_ANO',                       'ANO');
    incluir('NU_MES',                       'V1013');
    incluir('UF',                           'UF');
    incluir('CO_MUNICIPIO',                 'CAPITAL');
    incluir('COR_RACA',                     'A004');
    incluir('SEXO',                         'A003');
    incluir('IDADE',                        'A002');
    incluir('ESCOLARIDADE',                 'A005');
    incluir('FAIXA_RENDIMENTO',             'C01011');
    incluir('ATENDIMENTO_SUS',              'B0042');
    incluir('INTERNADO',                    'B005');
    incluir('SINTOMA_FEBRE',                'B0011');
    incluir('SINTOMA_TOSSE',                'B0012');
    incluir('SINTOMA_DOR_GARGANTA',         'B0013');
    incluir('SINTOMA_DIFICULDADE_RESPIRAR', 'B0014');
    incluir('SINTOMA_DOR_CABECA',           'B0015');
    incluir('SINTOMA_DOR_PEITO',            'B0016');
    incluir('SINTOMA_NAUSEA',               'B0017');
    incluir('SINTOMA_NARIZ',                'B0018');
    incluir('SINTOMA_FADIGA',               'B0019');
    incluir('SINTOMA_DOR_OLHOS',            'B00110');
    incluir('SINTOMA_PERDA_CHEIRO_SABOR',   'B00111');
    incluir('SINTOMA_DOR_MUSCULAR',         'B00112');
    RETURN v_mapa;
  END fn_mapa;

  -- ---------------------------------------------------------------
  -- separa o cabecalho em nomes (maiusculo, sem espaco e sem CHR(13))
  -- ---------------------------------------------------------------
  FUNCTION fn_separar(p_cabecalho IN VARCHAR2) RETURN t_lista IS
    v_cab   VARCHAR2(32767) := REPLACE(p_cabecalho, CHR(13));
    v_lista t_lista := t_lista();
    v_nome  VARCHAR2(128);
  BEGIN
    FOR i IN 1 .. REGEXP_COUNT(v_cab, ',') + 1 LOOP
      v_nome := SUBSTR(UPPER(TRIM(REGEXP_SUBSTR(v_cab, '([^,]*)(,|$)', 1, i, NULL, 1))), 1, 128);
      IF v_nome IS NULL THEN
        v_nome := 'COL_' || i;   -- nome vazio no cabecalho
      END IF;
      v_lista.EXTEND;
      v_lista(v_lista.LAST) := v_nome;
    END LOOP;
    RETURN v_lista;
  END fn_separar;

  -- ---------------------------------------------------------------
  -- colunas obrigatorias ausentes (NULL quando todas estao presentes)
  -- ---------------------------------------------------------------
  FUNCTION fn_colunas_ausentes(p_cabecalho IN VARCHAR2) RETURN VARCHAR2 IS
    v_colunas  t_lista      := fn_separar(p_cabecalho);
    v_mapa     t_lista_mapa := fn_mapa;
    v_ausentes VARCHAR2(4000);
  BEGIN
    FOR i IN 1 .. v_mapa.COUNT LOOP
      IF v_mapa(i).col_csv NOT MEMBER OF v_colunas THEN
        v_ausentes := v_ausentes
                      || CASE WHEN v_ausentes IS NOT NULL THEN ', ' END
                      || v_mapa(i).col_csv;
      END IF;
    END LOOP;
    RETURN v_ausentes;
  END fn_colunas_ausentes;

  -- ---------------------------------------------------------------
  -- le o cabecalho e conta as linhas de dados (sem o cabecalho)
  -- ---------------------------------------------------------------
  PROCEDURE prc_ler_arquivo(p_no_arquivo IN  VARCHAR2,
                            p_cabecalho  OUT VARCHAR2,
                            p_qt_linhas  OUT NUMBER) IS
    v_existe  BOOLEAN;
    v_tamanho NUMBER;
    v_bloco   BINARY_INTEGER;
    v_arq     UTL_FILE.FILE_TYPE;
    v_linha   VARCHAR2(32767);
  BEGIN
    UTL_FILE.FGETATTR(c_dir_dados, p_no_arquivo, v_existe, v_tamanho, v_bloco);
    IF NOT v_existe THEN
      RAISE_APPLICATION_ERROR(-20003, 'Arquivo inexistente em DIR_PNAD_DADOS: ' || p_no_arquivo);
    END IF;

    v_arq := UTL_FILE.FOPEN(c_dir_dados, p_no_arquivo, 'r', 32767);

    BEGIN
      UTL_FILE.GET_LINE(v_arq, p_cabecalho);
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20004, 'Arquivo vazio: ' || p_no_arquivo);
    END;

    p_qt_linhas := 0;
    LOOP
      BEGIN
        UTL_FILE.GET_LINE(v_arq, v_linha);
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          EXIT;
      END;
      IF REPLACE(v_linha, CHR(13)) IS NOT NULL THEN
        p_qt_linhas := p_qt_linhas + 1;
      END IF;
    END LOOP;

    UTL_FILE.FCLOSE(v_arq);
  EXCEPTION
    WHEN OTHERS THEN
      IF UTL_FILE.IS_OPEN(v_arq) THEN
        UTL_FILE.FCLOSE(v_arq);
      END IF;
      RAISE;
  END prc_ler_arquivo;

  -- ---------------------------------------------------------------
  -- grava o log em transacao autonoma (sobrevive ao ROLLBACK)
  -- ---------------------------------------------------------------
  PROCEDURE prc_registrar_log(p_dt_inicio  IN DATE,
                              p_no_arquivo IN VARCHAR2,
                              p_lidas      IN NUMBER,
                              p_gravadas   IN NUMBER,
                              p_rejeitadas IN NUMBER,
                              p_status     IN VARCHAR2,
                              p_obs        IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO log_carga (dt_inicio, dt_fim, no_arquivo, qt_linhas_lidas,
                           qt_linhas_gravadas, qt_linhas_rejeitadas,
                           st_execucao, ds_observacao)
    VALUES (p_dt_inicio, SYSDATE, SUBSTR(p_no_arquivo, 1, 100), p_lidas,
            p_gravadas, p_rejeitadas, p_status, SUBSTR(p_obs, 1, 4000));
    COMMIT;
  END prc_registrar_log;

  -- ---------------------------------------------------------------
  -- recria a tabela externa com as colunas do cabecalho (todas texto)
  -- ---------------------------------------------------------------
  PROCEDURE prc_criar_tabela_externa(p_no_arquivo IN VARCHAR2,
                                     p_base       IN VARCHAR2,
                                     p_colunas    IN t_lista) IS
    v_ddl VARCHAR2(32767);
  BEGIN
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE ' || c_tab_ext;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE <> -942 THEN   -- -942: tabela nao existe
          RAISE;
        END IF;
    END;

    v_ddl := 'CREATE TABLE ' || c_tab_ext || ' (';
    FOR i IN 1 .. p_colunas.COUNT LOOP
      v_ddl := v_ddl || CASE WHEN i > 1 THEN ', ' END
                     || '"' || p_colunas(i) || '" VARCHAR2(255)';
    END LOOP;

    v_ddl := v_ddl || ') ORGANIZATION EXTERNAL ('
      || ' TYPE ORACLE_LOADER DEFAULT DIRECTORY ' || c_dir_dados
      || ' ACCESS PARAMETERS ('
      || ' RECORDS DELIMITED BY NEWLINE SKIP 1'
      || ' BADFILE ' || c_dir_log || ':''' || p_base || '.bad'''
      || ' LOGFILE ' || c_dir_log || ':''' || p_base || '.log'''
      || ' FIELDS TERMINATED BY '','' MISSING FIELD VALUES ARE NULL)'
      || ' LOCATION (''' || p_no_arquivo || '''))'
      || ' REJECT LIMIT UNLIMITED';

    EXECUTE IMMEDIATE v_ddl;
  END prc_criar_tabela_externa;

  -- ---------------------------------------------------------------
  -- carga principal
  -- ---------------------------------------------------------------
  PROCEDURE usp_carregar(p_no_arquivo IN VARCHAR2) IS
    v_dt_inicio  DATE := SYSDATE;
    v_sufixo     VARCHAR2(20) := TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
    v_base       VARCHAR2(150);
    v_tag        VARCHAR2(200);
    v_cabecalho  VARCHAR2(32767);
    v_mapa       t_lista_mapa := fn_mapa;
    v_ausentes   VARCHAR2(4000);
    v_lidas      NUMBER;
    v_gravadas   NUMBER := 0;
    v_apagadas   NUMBER := 0;
    v_err_dml    NUMBER := 0;
    v_rejeitadas NUMBER;
    v_status     VARCHAR2(20);
    v_obs        VARCHAR2(4000);
    v_cols_stg   VARCHAR2(4000);
    v_cols_sel   VARCHAR2(32767);
    v_cod        NUMBER;

    -- valor texto limpo (sem CHR(13) e sem espacos)
    FUNCTION expr(p_col IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
      RETURN 'TRIM(REPLACE("' || p_col || '", CHR(13)))';
    END expr;
  BEGIN
    -- 0. nome do arquivo (entra em DDL dinamico: so caracteres seguros)
    IF p_no_arquivo IS NULL
       OR NOT REGEXP_LIKE(p_no_arquivo, '^[A-Za-z0-9_.-]{1,90}\.csv$', 'i') THEN
      RAISE_APPLICATION_ERROR(-20001, 'Nome de arquivo invalido: ' || p_no_arquivo);
    END IF;
    v_base := REGEXP_REPLACE(p_no_arquivo, '\.csv$', '', 1, 1, 'i') || '_' || v_sufixo;
    v_tag  := p_no_arquivo || ' ' || v_sufixo;

    -- 1 e 3. cabecalho e contagem das linhas de dados
    prc_ler_arquivo(p_no_arquivo, v_cabecalho, v_lidas);

    -- 2. colunas obrigatorias
    v_ausentes := fn_colunas_ausentes(v_cabecalho);
    IF v_ausentes IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20002, 'Cabecalho invalido. Colunas ausentes: ' || v_ausentes);
    END IF;
    IF v_lidas = 0 THEN
      RAISE_APPLICATION_ERROR(-20005, 'Arquivo sem linhas de dados: ' || p_no_arquivo);
    END IF;

    -- tabela externa (DDL faz commit implicito: antes do DELETE)
    prc_criar_tabela_externa(p_no_arquivo, v_base, fn_separar(v_cabecalho));

    FOR i IN 1 .. v_mapa.COUNT LOOP
      v_cols_stg := v_cols_stg || v_mapa(i).col_stg || ', ';
      v_cols_sel := v_cols_sel || expr(v_mapa(i).col_csv) || ', ';
    END LOOP;

    -- 4. apaga da staging o(s) mes(es) presentes no arquivo
    EXECUTE IMMEDIATE
         'DELETE FROM pnad_covid_pessoa WHERE (nu_ano, nu_mes) IN ('
      || ' SELECT DISTINCT'
      || '   TO_NUMBER(' || expr('ANO')   || ' DEFAULT NULL ON CONVERSION ERROR),'
      || '   TO_NUMBER(' || expr('V1013') || ' DEFAULT NULL ON CONVERSION ERROR)'
      || ' FROM ' || c_tab_ext || ')';
    v_apagadas := SQL%ROWCOUNT;

    -- 5. insere; conversao texto -> INTEGER implicita, erros na ERR$
    EXECUTE IMMEDIATE
         'INSERT INTO pnad_covid_pessoa (' || v_cols_stg || 'dt_carga)'
      || ' SELECT ' || v_cols_sel || ':dt FROM ' || c_tab_ext
      || ' LOG ERRORS INTO err$_pnad_covid_pessoa (''' || v_tag || ''')'
      || ' REJECT LIMIT UNLIMITED'
      USING v_dt_inicio;
    v_gravadas := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_err_dml
      FROM err$_pnad_covid_pessoa
     WHERE ora_err_tag$ = v_tag;

    v_rejeitadas := v_lidas - v_gravadas;

    IF v_gravadas = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nenhuma linha gravada. Rejeitadas: ' || v_rejeitadas
        || ' (ERR$_PNAD_COVID_PESSOA tag ''' || v_tag || ''': ' || v_err_dml
        || '; BADFILE ' || v_base || '.bad: ' || (v_rejeitadas - v_err_dml) || ')');
    END IF;

    IF v_gravadas = v_lidas THEN
      v_status := 'SUCESSO';
      v_obs    := 'Carga concluida. Linhas substituidas do mes: ' || v_apagadas;
    ELSE
      v_status := 'SUCESSO PARCIAL';
      v_obs    := v_rejeitadas || ' linha(s) rejeitada(s): '
               || v_err_dml || ' na ERR$_PNAD_COVID_PESSOA (tag ''' || v_tag || ''') e '
               || (v_rejeitadas - v_err_dml) || ' no BADFILE ' || v_base
               || '.bad (DIR_PNAD_LOG). Linhas substituidas do mes: ' || v_apagadas;
    END IF;

    COMMIT;

    -- 6. log
    prc_registrar_log(v_dt_inicio, p_no_arquivo, v_lidas, v_gravadas,
                      v_rejeitadas, v_status, v_obs);
    DBMS_OUTPUT.PUT_LINE(p_no_arquivo || ': ' || v_status || ' - lidas ' || v_lidas
                         || ', gravadas ' || v_gravadas);
  EXCEPTION
    WHEN OTHERS THEN
      v_cod := SQLCODE;
      v_obs := SQLERRM;
      ROLLBACK;
      prc_registrar_log(v_dt_inicio, p_no_arquivo, v_lidas, 0,
                        v_lidas, 'ERRO', v_obs);
      IF v_cod BETWEEN -20099 AND -20001 THEN
        RAISE;
      ELSE
        RAISE_APPLICATION_ERROR(-20999, 'Erro na carga de ' || p_no_arquivo || ': ' || v_obs);
      END IF;
  END usp_carregar;

END pkg_carga_pnad;
/

SHOW ERRORS PACKAGE BODY pkg_carga_pnad

-- conferencia da compilacao e teste rapido da function de validacao
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name = 'PKG_CARGA_PNAD'
 ORDER BY object_type;

SELECT pkg_carga_pnad.fn_colunas_ausentes('Ano,UF,CAPITAL,V1013,A002') AS ausentes_esperado_18
  FROM dual;