-- silver.status_semanal: o status que cada gerente manda toda sexta.
-- É daqui que sai o HISTÓRICO do avanço (as ferramentas só guardam o % de hoje).
CREATE OR REFRESH MATERIALIZED VIEW status_semanal (
  CONSTRAINT farol_conhecido EXPECT (farol IN ('verde', 'amarelo', 'vermelho')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Status semanal de cada projeto (toda sexta): farol declarado pelo gerente (verde, amarelo ou vermelho), % concluído informado e o texto livre com entregas e bloqueios. status_vazio marca os textos sem conteúdo, que ficam na tabela.'
AS SELECT
  projeto_id,
  to_date(data_status)                       AS data_status,
  gerente,
  -- sujeira 17: 'Verde', 'VERDE', ' verde '
  lower(trim(farol))                         AS farol,
  CAST(CAST(pct_concluido AS DOUBLE) AS INT) AS pct_concluido,
  texto_status,
  -- sujeira 18: status vazio NÃO é descartado (a semana existiu), só sinalizado
  coalesce(trim(texto_status), '') IN ('', 'N/A', 'ver ata da reunião') AS status_vazio
FROM lakehouse_vertice.bronze.status_semanal;


-- silver.custos: os lançamentos de custo real.
-- O teste da limpeza: a soma aqui tem que bater com a da bronze (R$ 193,35 mi).
CREATE OR REFRESH MATERIALIZED VIEW custos
COMMENT 'Lançamentos de custo real por projeto (pessoal, consultoria, cloud, licenças, despesas), em reais. Estornos ficam como valor negativo (o custo é líquido) e são marcados em estorno. semana é a sexta da semana do lançamento.'
AS SELECT
  lancamento_id,
  projeto_id,
  to_date(data)                                   AS data,
  -- a sexta da semana (date_trunc('WEEK') cai na segunda)
  date_add(to_date(date_trunc('WEEK', to_date(data))), 4) AS semana,
  categoria,
  descricao,
  centro_custo,
  -- sujeira 13: 671 valores com vírgula decimal. replace ANTES do CAST.
  -- (try_cast transformaria esses valores em NULL e sumiria com R$ 5,4 mi em silêncio)
  CAST(replace(valor, ',', '.') AS DECIMAL(14, 2)) AS valor,
  -- sujeira 14: estorno FICA (o custo é líquido), só ganha a marca
  CAST(replace(valor, ',', '.') AS DECIMAL(14, 2)) < 0 AS estorno
FROM lakehouse_vertice.bronze.custos;
