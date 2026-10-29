-- =====================================================================
-- Arquivo  : sqlserver/03_functions.sql
-- Objetivo : functions de normalizacao textual e de mapeamento de
--            codigos (secoes 1 a 10 do enunciado), no schema etl,
--            com teste de cada uma (inclusive NULL e codigo invalido)
-- Etapa    : E4 - Functions
-- Executar : como sa no container tsql (localhost,1434), banco
--            db_pnad_covid
-- Depende  : sqlserver/00_setup_banco.sql (schema etl)
-- Obs      : pode ser executado de novo (CREATE OR ALTER)
--          : regra geral (D14): codigo NULL -> 'Nao aplicavel'; codigo
--            fora do dominio -> 'Nao informado'; na sigla da UF, NA e
--            NI (D29); municipio NULL -> 'Demais municipios' (D06)
--          : textos com a acentuacao do enunciado (D12); so o nome do
--            municipio e normalizado (D11)
--          : as procedures aplicam estas functions sobre valores
--            distintos e fazem JOIN depois (nada linha a linha)
--          : arquivo em UTF-8 com BOM (literais acentuados em N'...')
-- =====================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE db_pnad_covid;
GO

-- =====================================================================
-- 1. Normalizacao textual
-- =====================================================================

-- remove espacos extras: TRIM e sequencias de espacos viram um so
CREATE OR ALTER FUNCTION etl.fn_remover_espacos (@texto NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    IF @texto IS NULL
        RETURN NULL;

    -- tabulacao e quebras de linha tambem contam como espaco
    DECLARE @t NVARCHAR(4000) =
        REPLACE(REPLACE(REPLACE(@texto, NCHAR(9), N' '), NCHAR(10), N' '), NCHAR(13), N' ');

    WHILE CHARINDEX(N'  ', @t) > 0
        SET @t = REPLACE(@t, N'  ', N' ');

    RETURN TRIM(@t);
END;
GO

-- remove acentos; collation binaria para preservar maiusculas/minusculas
CREATE OR ALTER FUNCTION etl.fn_remover_acentos (@texto NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    RETURN TRANSLATE(@texto COLLATE Latin1_General_100_BIN2,
                     N'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                     N'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN');
END;
GO

-- Title Case: primeira letra de cada palavra maiuscula; conectivos
-- de, da, do, das, dos, e em minusculo, exceto na primeira palavra (D11)
CREATE OR ALTER FUNCTION etl.fn_title_case (@texto NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    IF @texto IS NULL
        RETURN NULL;

    DECLARE @resultado NVARCHAR(4000);

    SELECT @resultado =
           STRING_AGG(
               CASE
                   WHEN p.ordinal > 1
                    AND LOWER(p.value) IN (N'de', N'da', N'do', N'das', N'dos', N'e')
                       THEN LOWER(p.value)
                   ELSE UPPER(LEFT(p.value, 1)) + LOWER(SUBSTRING(p.value, 2, 4000))
               END, N' ') WITHIN GROUP (ORDER BY p.ordinal)
      FROM STRING_SPLIT(@texto, N' ', 1) AS p
     WHERE p.value <> N'';

    RETURN ISNULL(@resultado, N'');
END;
GO

-- aplica as tres: espacos -> acentos -> Title Case
CREATE OR ALTER FUNCTION etl.fn_normalizar_texto (@texto NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    RETURN etl.fn_title_case(etl.fn_remover_acentos(etl.fn_remover_espacos(@texto)));
END;
GO

-- =====================================================================
-- 2. Mapeamento de codigos (enunciado, secoes 1 a 10)
-- =====================================================================

-- 1) Unidade da Federacao: nome
CREATE OR ALTER FUNCTION etl.fn_uf_nome (@co INT)
RETURNS NVARCHAR(50)
AS
BEGIN
    IF @co IS NULL
        RETURN N'Não aplicável';

    RETURN CASE @co
               WHEN 11 THEN N'Rondônia'
               WHEN 12 THEN N'Acre'
               WHEN 13 THEN N'Amazonas'
               WHEN 14 THEN N'Roraima'
               WHEN 15 THEN N'Pará'
               WHEN 16 THEN N'Amapá'
               WHEN 17 THEN N'Tocantins'
               WHEN 21 THEN N'Maranhão'
               WHEN 22 THEN N'Piauí'
               WHEN 23 THEN N'Ceará'
               WHEN 24 THEN N'Rio Grande do Norte'
               WHEN 25 THEN N'Paraíba'
               WHEN 26 THEN N'Pernambuco'
               WHEN 27 THEN N'Alagoas'
               WHEN 28 THEN N'Sergipe'
               WHEN 29 THEN N'Bahia'
               WHEN 31 THEN N'Minas Gerais'
               WHEN 32 THEN N'Espírito Santo'
               WHEN 33 THEN N'Rio de Janeiro'
               WHEN 35 THEN N'São Paulo'
               WHEN 41 THEN N'Paraná'
               WHEN 42 THEN N'Santa Catarina'
               WHEN 43 THEN N'Rio Grande do Sul'
               WHEN 50 THEN N'Mato Grosso do Sul'
               WHEN 51 THEN N'Mato Grosso'
               WHEN 52 THEN N'Goiás'
               WHEN 53 THEN N'Distrito Federal'
               ELSE N'Não informado'
           END;
END;
GO

-- 1) Unidade da Federacao: sigla (exigida pela dim_municipio); NA/NI (D29)
CREATE OR ALTER FUNCTION etl.fn_uf_sigla (@co INT)
RETURNS CHAR(2)
AS
BEGIN
    IF @co IS NULL
        RETURN 'NA';

    RETURN CASE @co
               WHEN 11 THEN 'RO'  WHEN 12 THEN 'AC'  WHEN 13 THEN 'AM'
               WHEN 14 THEN 'RR'  WHEN 15 THEN 'PA'  WHEN 16 THEN 'AP'
               WHEN 17 THEN 'TO'  WHEN 21 THEN 'MA'  WHEN 22 THEN 'PI'
               WHEN 23 THEN 'CE'  WHEN 24 THEN 'RN'  WHEN 25 THEN 'PB'
               WHEN 26 THEN 'PE'  WHEN 27 THEN 'AL'  WHEN 28 THEN 'SE'
               WHEN 29 THEN 'BA'  WHEN 31 THEN 'MG'  WHEN 32 THEN 'ES'
               WHEN 33 THEN 'RJ'  WHEN 35 THEN 'SP'  WHEN 41 THEN 'PR'
               WHEN 42 THEN 'SC'  WHEN 43 THEN 'RS'  WHEN 50 THEN 'MS'
               WHEN 51 THEN 'MT'  WHEN 52 THEN 'GO'  WHEN 53 THEN 'DF'
               ELSE 'NI'
           END;
END;
GO

-- 2) Municipios: nome da capital sem "Municipio de" e sem "(UF)";
--    NULL = fora da capital -> 'Demais municipios' (D06)
CREATE OR ALTER FUNCTION etl.fn_municipio_nome (@co_capital INT)
RETURNS NVARCHAR(150)
AS
BEGIN
    IF @co_capital IS NULL
        RETURN N'Demais municípios';

    DECLARE @descricao NVARCHAR(150) =
        CASE @co_capital
            WHEN 11 THEN N'Município de Porto Velho (RO)'
            WHEN 12 THEN N'Município de Rio Branco (AC)'
            WHEN 13 THEN N'Município de Manaus (AM)'
            WHEN 14 THEN N'Município de Boa Vista (RR)'
            WHEN 15 THEN N'Município de Belém (PA)'
            WHEN 16 THEN N'Município de Macapá (AP)'
            WHEN 17 THEN N'Município de Palmas (TO)'
            WHEN 21 THEN N'Município de São Luís (MA)'
            WHEN 22 THEN N'Município de Teresina (PI)'
            WHEN 23 THEN N'Município de Fortaleza (CE)'
            WHEN 24 THEN N'Município de Natal (RN)'
            WHEN 25 THEN N'Município de João Pessoa (PB)'
            WHEN 26 THEN N'Município de Recife (PE)'
            WHEN 27 THEN N'Município de Maceió (AL)'
            WHEN 28 THEN N'Município de Aracaju (SE)'
            WHEN 29 THEN N'Município de Salvador (BA)'
            WHEN 31 THEN N'Município de Belo Horizonte (MG)'
            WHEN 32 THEN N'Município de Vitória (ES)'
            WHEN 33 THEN N'Município de Rio de Janeiro (RJ)'
            WHEN 35 THEN N'Município de São Paulo (SP)'
            WHEN 41 THEN N'Município de Curitiba (PR)'
            WHEN 42 THEN N'Município de Florianópolis (SC)'
            WHEN 43 THEN N'Município de Porto Alegre (RS)'
            WHEN 50 THEN N'Município de Campo Grande (MS)'
            WHEN 51 THEN N'Município de Cuiabá (MT)'
            WHEN 52 THEN N'Município de Goiânia (GO)'
            WHEN 53 THEN N'Município de Brasília (DF)'
        END;

    IF @descricao IS NULL
        RETURN N'Não informado';

    -- tira o prefixo "Municipio de " e o sufixo " (UF)"
    SET @descricao = REPLACE(@descricao, N'Município de ', N'');
    RETURN LEFT(@descricao, CHARINDEX(N' (', @descricao) - 1);
END;
GO

-- 3) Sexo (descricao; a dim_pessoa usa M/F/I por CASE, D13)
CREATE OR ALTER FUNCTION etl.fn_sexo (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Homem'
               WHEN @co = 2     THEN N'Mulher'
               ELSE N'Não informado'
           END;
END;
GO

-- 4) Cor ou raca
CREATE OR ALTER FUNCTION etl.fn_cor_raca (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Branca'
               WHEN @co = 2     THEN N'Preta'
               WHEN @co = 3     THEN N'Amarela'
               WHEN @co = 4     THEN N'Parda'
               WHEN @co = 5     THEN N'Indígena'
               WHEN @co = 9     THEN N'Ignorado'
               ELSE N'Não informado'
           END;
END;
GO

-- 5) Escolaridade (textos do enunciado)
CREATE OR ALTER FUNCTION etl.fn_escolaridade (@co INT)
RETURNS NVARCHAR(50)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Sem instrução'
               WHEN @co = 2     THEN N'Fundamental incompleto'
               WHEN @co = 3     THEN N'Fundamental completa'
               WHEN @co = 4     THEN N'Médio incompleto'
               WHEN @co = 5     THEN N'Médio completo'
               WHEN @co = 6     THEN N'Superior incompleto'
               WHEN @co = 7     THEN N'Superior completo'
               WHEN @co = 8     THEN N'Pós-graduação, mestrado ou doutorado'
               ELSE N'Não informado'
           END;
END;
GO

-- 6) Faixa etaria a partir da idade (dicionario IBGE: 0 a 130 anos)
CREATE OR ALTER FUNCTION etl.fn_faixa_etaria (@idade INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @idade IS NULL                 THEN N'Não aplicável'
               WHEN @idade BETWEEN 0  AND 17       THEN N'Criança/Adolescente'
               WHEN @idade BETWEEN 18 AND 29       THEN N'Jovem Adulto'
               WHEN @idade BETWEEN 30 AND 59       THEN N'Adulto'
               WHEN @idade BETWEEN 60 AND 130      THEN N'Idoso'
               ELSE N'Não informado'
           END;
END;
GO

-- 7) Faixa de rendimento (C01011: 00 a 09; vazio = Nao aplicavel)
CREATE OR ALTER FUNCTION etl.fn_faixa_rendimento (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 0     THEN N'0 - 100'
               WHEN @co = 1     THEN N'101 - 300'
               WHEN @co = 2     THEN N'301 - 600'
               WHEN @co = 3     THEN N'601 - 800'
               WHEN @co = 4     THEN N'801 - 1.600'
               WHEN @co = 5     THEN N'1.601 - 3.000'
               WHEN @co = 6     THEN N'3.001 - 10.000'
               WHEN @co = 7     THEN N'10.001 - 50.000'
               WHEN @co = 8     THEN N'50.001 - 100.000'
               WHEN @co = 9     THEN N'Mais de 100.000'
               ELSE N'Não informado'
           END;
END;
GO

-- 8) Atendimento SUS (B0042)
CREATE OR ALTER FUNCTION etl.fn_atendimento_sus (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Sim'
               WHEN @co = 2     THEN N'Não'
               WHEN @co = 9     THEN N'Ignorado'
               ELSE N'Não informado'
           END;
END;
GO

-- 9) Internado (B005)
CREATE OR ALTER FUNCTION etl.fn_internado (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Sim'
               WHEN @co = 2     THEN N'Não'
               WHEN @co = 3     THEN N'Não foi atendido'
               WHEN @co = 9     THEN N'Ignorado'
               ELSE N'Não informado'
           END;
END;
GO

-- 10) Sintomas (B0011 a B00112, mesmas categorias nos 12)
CREATE OR ALTER FUNCTION etl.fn_sintoma (@co INT)
RETURNS NVARCHAR(25)
AS
BEGIN
    RETURN CASE
               WHEN @co IS NULL THEN N'Não aplicável'
               WHEN @co = 1     THEN N'Sim'
               WHEN @co = 2     THEN N'Não'
               WHEN @co = 3     THEN N'Não sabe'
               WHEN @co = 9     THEN N'Ignorado'
               ELSE N'Não informado'
           END;
END;
GO

-- Nome do mes sem depender de SET LANGUAGE (D17)
CREATE OR ALTER FUNCTION etl.fn_nome_mes (@nu_mes INT)
RETURNS NVARCHAR(20)
AS
BEGIN
    RETURN CASE
               WHEN @nu_mes IS NULL THEN N'Não aplicável'
               WHEN @nu_mes = 1     THEN N'Janeiro'
               WHEN @nu_mes = 2     THEN N'Fevereiro'
               WHEN @nu_mes = 3     THEN N'Março'
               WHEN @nu_mes = 4     THEN N'Abril'
               WHEN @nu_mes = 5     THEN N'Maio'
               WHEN @nu_mes = 6     THEN N'Junho'
               WHEN @nu_mes = 7     THEN N'Julho'
               WHEN @nu_mes = 8     THEN N'Agosto'
               WHEN @nu_mes = 9     THEN N'Setembro'
               WHEN @nu_mes = 10    THEN N'Outubro'
               WHEN @nu_mes = 11    THEN N'Novembro'
               WHEN @nu_mes = 12    THEN N'Dezembro'
               ELSE N'Não informado'
           END;
END;
GO

PRINT 'Functions do schema etl criadas/atualizadas';
GO

-- =====================================================================
-- 3. Testes: cada function com valores validos, NULL e codigo invalido
--    Comparacao binaria: diferencia maiuscula/minuscula e acento
-- =====================================================================
DECLARE @teste TABLE (
    id        INT IDENTITY(1, 1),
    funcao    VARCHAR(40),
    entrada   NVARCHAR(60),
    resultado NVARCHAR(200),
    esperado  NVARCHAR(200)
);

INSERT INTO @teste (funcao, entrada, resultado, esperado)
VALUES
 ('fn_remover_espacos',  N'''  Rio   de    Janeiro  ''', etl.fn_remover_espacos(N'  Rio   de    Janeiro  '), N'Rio de Janeiro'),
 ('fn_remover_espacos',  N'NULL',            etl.fn_remover_espacos(NULL),                 NULL),
 ('fn_remover_acentos',  N'São Luís - João', etl.fn_remover_acentos(N'São Luís - João'),   N'Sao Luis - Joao'),
 ('fn_remover_acentos',  N'GOIÂNIA, MACEIÓ', etl.fn_remover_acentos(N'GOIÂNIA, MACEIÓ'),   N'GOIANIA, MACEIO'),
 ('fn_title_case',       N'RIO DE JANEIRO',  etl.fn_title_case(N'RIO DE JANEIRO'),         N'Rio de Janeiro'),
 ('fn_title_case',       N'mato grosso do sul', etl.fn_title_case(N'mato grosso do sul'),  N'Mato Grosso do Sul'),
 ('fn_title_case',       N'de souza e silva', etl.fn_title_case(N'de souza e silva'),      N'De Souza e Silva'),
 ('fn_normalizar_texto', N''' joão   PESSOA ''', etl.fn_normalizar_texto(N' joão   PESSOA '), N'Joao Pessoa'),
 ('fn_normalizar_texto', N'NULL',            etl.fn_normalizar_texto(NULL),                NULL),
 ('fn_uf_nome',          N'35',              etl.fn_uf_nome(35),                           N'São Paulo'),
 ('fn_uf_nome',          N'53',              etl.fn_uf_nome(53),                           N'Distrito Federal'),
 ('fn_uf_nome',          N'NULL',            etl.fn_uf_nome(NULL),                         N'Não aplicável'),
 ('fn_uf_nome',          N'99',              etl.fn_uf_nome(99),                           N'Não informado'),
 ('fn_uf_sigla',         N'11',              etl.fn_uf_sigla(11),                          N'RO'),
 ('fn_uf_sigla',         N'53',              etl.fn_uf_sigla(53),                          N'DF'),
 ('fn_uf_sigla',         N'NULL',            etl.fn_uf_sigla(NULL),                        N'NA'),
 ('fn_uf_sigla',         N'99',              etl.fn_uf_sigla(99),                          N'NI'),
 ('fn_municipio_nome',   N'21',              etl.fn_municipio_nome(21),                    N'São Luís'),
 ('fn_municipio_nome',   N'33',              etl.fn_municipio_nome(33),                    N'Rio de Janeiro'),
 ('fn_municipio_nome',   N'NULL',            etl.fn_municipio_nome(NULL),                  N'Demais municípios'),
 ('fn_municipio_nome',   N'99',              etl.fn_municipio_nome(99),                    N'Não informado'),
 ('normalizar(municipio)', N'21',            etl.fn_normalizar_texto(etl.fn_municipio_nome(21)),   N'Sao Luis'),
 ('normalizar(municipio)', N'NULL',          etl.fn_normalizar_texto(etl.fn_municipio_nome(NULL)), N'Demais Municipios'),
 ('fn_sexo',             N'1',               etl.fn_sexo(1),                               N'Homem'),
 ('fn_sexo',             N'2',               etl.fn_sexo(2),                               N'Mulher'),
 ('fn_sexo',             N'NULL',            etl.fn_sexo(NULL),                            N'Não aplicável'),
 ('fn_sexo',             N'3',               etl.fn_sexo(3),                               N'Não informado'),
 ('fn_cor_raca',         N'5',               etl.fn_cor_raca(5),                           N'Indígena'),
 ('fn_cor_raca',         N'9',               etl.fn_cor_raca(9),                           N'Ignorado'),
 ('fn_cor_raca',         N'NULL',            etl.fn_cor_raca(NULL),                        N'Não aplicável'),
 ('fn_cor_raca',         N'7',               etl.fn_cor_raca(7),                           N'Não informado'),
 ('fn_escolaridade',     N'1',               etl.fn_escolaridade(1),                       N'Sem instrução'),
 ('fn_escolaridade',     N'8',               etl.fn_escolaridade(8),                       N'Pós-graduação, mestrado ou doutorado'),
 ('fn_escolaridade',     N'NULL',            etl.fn_escolaridade(NULL),                    N'Não aplicável'),
 ('fn_escolaridade',     N'0',               etl.fn_escolaridade(0),                       N'Não informado'),
 ('fn_faixa_etaria',     N'17',              etl.fn_faixa_etaria(17),                      N'Criança/Adolescente'),
 ('fn_faixa_etaria',     N'18',              etl.fn_faixa_etaria(18),                      N'Jovem Adulto'),
 ('fn_faixa_etaria',     N'29',              etl.fn_faixa_etaria(29),                      N'Jovem Adulto'),
 ('fn_faixa_etaria',     N'30',              etl.fn_faixa_etaria(30),                      N'Adulto'),
 ('fn_faixa_etaria',     N'59',              etl.fn_faixa_etaria(59),                      N'Adulto'),
 ('fn_faixa_etaria',     N'60',              etl.fn_faixa_etaria(60),                      N'Idoso'),
 ('fn_faixa_etaria',     N'NULL',            etl.fn_faixa_etaria(NULL),                    N'Não aplicável'),
 ('fn_faixa_etaria',     N'-1',              etl.fn_faixa_etaria(-1),                      N'Não informado'),
 ('fn_faixa_etaria',     N'131',             etl.fn_faixa_etaria(131),                     N'Não informado'),
 ('fn_faixa_rendimento', N'0',               etl.fn_faixa_rendimento(0),                   N'0 - 100'),
 ('fn_faixa_rendimento', N'4',               etl.fn_faixa_rendimento(4),                   N'801 - 1.600'),
 ('fn_faixa_rendimento', N'9',               etl.fn_faixa_rendimento(9),                   N'Mais de 100.000'),
 ('fn_faixa_rendimento', N'NULL',            etl.fn_faixa_rendimento(NULL),                N'Não aplicável'),
 ('fn_faixa_rendimento', N'10',              etl.fn_faixa_rendimento(10),                  N'Não informado'),
 ('fn_atendimento_sus',  N'1',               etl.fn_atendimento_sus(1),                    N'Sim'),
 ('fn_atendimento_sus',  N'9',               etl.fn_atendimento_sus(9),                    N'Ignorado'),
 ('fn_atendimento_sus',  N'NULL',            etl.fn_atendimento_sus(NULL),                 N'Não aplicável'),
 ('fn_atendimento_sus',  N'3',               etl.fn_atendimento_sus(3),                    N'Não informado'),
 ('fn_internado',        N'3',               etl.fn_internado(3),                          N'Não foi atendido'),
 ('fn_internado',        N'9',               etl.fn_internado(9),                          N'Ignorado'),
 ('fn_internado',        N'NULL',            etl.fn_internado(NULL),                       N'Não aplicável'),
 ('fn_internado',        N'4',               etl.fn_internado(4),                          N'Não informado'),
 ('fn_sintoma',          N'1',               etl.fn_sintoma(1),                            N'Sim'),
 ('fn_sintoma',          N'3',               etl.fn_sintoma(3),                            N'Não sabe'),
 ('fn_sintoma',          N'NULL',            etl.fn_sintoma(NULL),                         N'Não aplicável'),
 ('fn_sintoma',          N'5',               etl.fn_sintoma(5),                            N'Não informado'),
 ('fn_nome_mes',         N'3',               etl.fn_nome_mes(3),                           N'Março'),
 ('fn_nome_mes',         N'5',               etl.fn_nome_mes(5),                           N'Maio'),
 ('fn_nome_mes',         N'NULL',            etl.fn_nome_mes(NULL),                        N'Não aplicável'),
 ('fn_nome_mes',         N'13',              etl.fn_nome_mes(13),                          N'Não informado');

-- resultado de cada teste
SELECT  id,
        funcao,
        entrada,
        resultado,
        CASE
            WHEN resultado IS NULL AND esperado IS NULL THEN 'OK'
            WHEN resultado COLLATE Latin1_General_100_BIN2
               = esperado  COLLATE Latin1_General_100_BIN2 THEN 'OK'
            ELSE 'FALHA'
        END AS status
FROM    @teste
ORDER BY id;

-- resumo (esperado: 65 testes, 65 OK, 0 falhas)
SELECT  COUNT(*) AS testes,
        SUM(CASE WHEN (resultado IS NULL AND esperado IS NULL)
                   OR resultado COLLATE Latin1_General_100_BIN2
                    = esperado  COLLATE Latin1_General_100_BIN2
                 THEN 1 ELSE 0 END) AS ok,
        SUM(CASE WHEN (resultado IS NULL AND esperado IS NULL)
                   OR resultado COLLATE Latin1_General_100_BIN2
                    = esperado  COLLATE Latin1_General_100_BIN2
                 THEN 0 ELSE 1 END) AS falhas
FROM    @teste;

-- as 27 capitais e o item "Demais" como vao para a dim_municipio
-- (no item Demais a sigla vem da UF de cada linha: aqui aparece 'UF')
SELECT  u.co                                                  AS co_capital,
        CASE WHEN u.co IS NULL THEN 'UF'
             ELSE etl.fn_uf_sigla(u.co) END                   AS sg_uf,
        etl.fn_municipio_nome(u.co)                           AS nome_mapeado,
        etl.fn_normalizar_texto(etl.fn_municipio_nome(u.co))  AS no_municipio
FROM    (VALUES (11),(12),(13),(14),(15),(16),(17),(21),(22),(23),(24),(25),(26),(27),
                (28),(29),(31),(32),(33),(35),(41),(42),(43),(50),(51),(52),(53),(NULL)) AS u(co)
ORDER BY CASE WHEN u.co IS NULL THEN 1 ELSE 0 END, u.co;

-- functions criadas (esperado: 16)
SELECT  COUNT(*) AS qtd_functions,
        STRING_AGG(o.name, ', ') WITHIN GROUP (ORDER BY o.name) AS functions
FROM    sys.objects AS o
WHERE   o.schema_id = SCHEMA_ID(N'etl')
  AND   o.type = 'FN';
GO
