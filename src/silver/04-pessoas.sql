-- silver.colaboradores: as 520 pessoas, uma linha por pessoa.
-- Sujeira 16: COL0102, COL0257 e COL0433 aparecem duas vezes (a cópia vem com nome e papel em CAIXA ALTA).
-- A janela fica num CTE e o filtro no seguinte.
CREATE OR REFRESH MATERIALIZED VIEW colaboradores
COMMENT 'As 520 pessoas da Vértice, sem duplicatas: papel (dev, qa, sre, product_owner...), senioridade, custo por hora, data de admissão e de desligamento (vazia = ativa).'
AS
WITH numerado AS (
  SELECT
    *,
    -- o cadastro bom é o que tem o papel em minúsculas: ele fica em 1º
    row_number() OVER (
      PARTITION BY colaborador_id
      ORDER BY CASE WHEN papel = lower(papel) THEN 0 ELSE 1 END
    ) AS ordem
  FROM lakehouse_vertice.bronze.colaboradores
)
SELECT
  colaborador_id,
  nome,
  papel,
  senioridade,
  CAST(custo_hora AS DECIMAL(10, 2))       AS custo_hora,
  to_date(nullif(trim(data_admissao), ''))     AS data_admissao,
  to_date(nullif(trim(data_desligamento), '')) AS data_desligamento
FROM numerado
WHERE ordem = 1;


-- silver.apontamentos: o timesheet semanal (horas disponíveis × apontadas por pessoa e projeto)
CREATE OR REFRESH MATERIALIZED VIEW apontamentos
COMMENT 'Timesheet semanal: horas disponíveis e horas apontadas por pessoa e projeto. semana_inicio é a segunda e semana é a sexta (o mesmo dia do status semanal). Base da utilização de cada pessoa.'
AS SELECT
  colaborador_id,
  projeto_id,
  to_date(semana_inicio)               AS semana_inicio,
  date_add(to_date(semana_inicio), 4)  AS semana,          -- a sexta da semana
  CAST(horas_disponiveis AS DOUBLE)    AS horas_disponiveis,
  CAST(horas_apontadas   AS DOUBLE)    AS horas_apontadas
FROM lakehouse_vertice.bronze.apontamentos;
