-- gold.fato_projeto_semana: o FILME de cada projeto, uma linha por sexta-feira.
-- Da semana do início até hoje (16/10/2026), com PV, EV, AC, SPI, CPI e as horas do timesheet.
-- O avanço (EV) vem do status semanal: as ferramentas só guardam o % de hoje.
-- (cada função de janela fica num CTE e a agregação/junção no seguinte)
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.fato_projeto_semana (
  CONSTRAINT pv_nao_negativo  EXPECT (coalesce(pv, 0) >= 0) ON VIOLATION FAIL UPDATE,   -- pv vazio = projeto sem cronograma (o teste 1 pega)
  CONSTRAINT ev_ate_orcamento EXPECT (ev <= orcamento)      ON VIOLATION FAIL UPDATE
)
COMMENT 'Histórico semanal de cada projeto (uma linha por sexta-feira, do início até 16/10/2026): orçamento, % concluído do status semanal, valor planejado (pv), valor agregado (ev), custo real acumulado (ac), SPI = ev/pv, CPI = ev/ac, EAC = orçamento/CPI, farol declarado pelo gerente e horas disponíveis, apontadas e ociosas no timesheet da semana. Valores em reais.'
AS
WITH semanas AS (
  -- uma linha por projeto e sexta: da sexta da semana do início até hoje
  SELECT
    projeto_id,
    orcamento_custo AS orcamento,
    explode(sequence(
      date_add(to_date(date_trunc('WEEK', data_inicio)), 4),   -- date_trunc cai na segunda; +4 = sexta
      DATE'2026-10-16',
      INTERVAL 1 WEEK
    )) AS semana
  FROM projetos
),

pv_semana AS (
  -- quanto do trabalho (em horas) o baseline mandava ter feito até a semana
  SELECT
    s.projeto_id,
    s.semana,
    sum(t.horas * greatest(0, least(1,
          datediff(s.semana, t.inicio_baseline) / datediff(t.fim_baseline, t.inicio_baseline)))) AS horas_planejadas,
    sum(t.horas) AS horas_totais
  FROM semanas s
  JOIN tarefas t ON t.projeto_id = s.projeto_id
  GROUP BY s.projeto_id, s.semana
),

status_semana AS (
  -- o % e o farol daquela sexta. Projeto concluído para de publicar: fica o último valor.
  -- Antes do 1º status (projeto que começou no meio da semana) o avanço é 0%.
  SELECT
    s.projeto_id,
    s.semana,
    coalesce(last_value(st.pct_concluido, true) OVER janela, 0) AS pct_concluido,
    last_value(st.farol, true)         OVER janela AS farol_do_gerente
  FROM semanas s
  LEFT JOIN status_semanal st
    ON st.projeto_id = s.projeto_id AND st.data_status = s.semana
  WINDOW janela AS (PARTITION BY s.projeto_id ORDER BY s.semana)
),

custo_semana AS (
  -- custo da semana; lançamento anterior à 1ª semana do projeto entra na 1ª semana
  SELECT
    c.projeto_id,
    greatest(c.semana, inicio.primeira_semana) AS semana,
    sum(c.valor) AS custo
  FROM custos c
  JOIN (SELECT projeto_id, min(semana) AS primeira_semana FROM semanas GROUP BY projeto_id) inicio
    ON inicio.projeto_id = c.projeto_id
  WHERE c.data <= DATE'2026-10-16'
  GROUP BY c.projeto_id, greatest(c.semana, inicio.primeira_semana)
),

ac_semana AS (
  -- AC = custo real ACUMULADO até a semana
  SELECT
    s.projeto_id,
    s.semana,
    sum(coalesce(cs.custo, 0)) OVER (
      PARTITION BY s.projeto_id ORDER BY s.semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ac
  FROM semanas s
  LEFT JOIN custo_semana cs
    ON cs.projeto_id = s.projeto_id AND cs.semana = s.semana
),

horas_semana AS (
  -- o timesheet da semana, somado no projeto
  SELECT
    projeto_id,
    semana,
    sum(horas_disponiveis) AS horas_disponiveis,
    sum(horas_apontadas)   AS horas_apontadas
  FROM apontamentos
  GROUP BY projeto_id, semana
),

valores AS (
  SELECT
    s.projeto_id,
    s.semana,
    s.orcamento,
    st.pct_concluido,
    round(s.orcamento * pv.horas_planejadas / pv.horas_totais, 2) AS pv,
    round(s.orcamento * st.pct_concluido / 100, 2)                AS ev,
    ac.ac,
    st.farol_do_gerente,
    coalesce(h.horas_disponiveis, 0) AS horas_disponiveis,
    coalesce(h.horas_apontadas, 0)   AS horas_apontadas
  FROM semanas s
  LEFT JOIN pv_semana     pv ON pv.projeto_id = s.projeto_id AND pv.semana = s.semana
  LEFT JOIN status_semana st ON st.projeto_id = s.projeto_id AND st.semana = s.semana
  LEFT JOIN ac_semana     ac ON ac.projeto_id = s.projeto_id AND ac.semana = s.semana
  LEFT JOIN horas_semana  h  ON h.projeto_id  = s.projeto_id AND h.semana  = s.semana
),

indices AS (
  SELECT
    *,
    round(try_divide(ev, pv), 4) AS spi,     -- < 1 = atrasado
    round(try_divide(ev, ac), 4) AS cpi      -- < 1 = gastando mais do que agrega
  FROM valores
)

SELECT
  projeto_id,
  semana,
  orcamento,
  pct_concluido,
  pv,
  ev,
  ac,
  spi,
  cpi,
  round(try_divide(orcamento, cpi), 2)   AS eac,
  farol_do_gerente,
  horas_disponiveis,
  horas_apontadas,
  horas_disponiveis - horas_apontadas    AS horas_ociosas
FROM indices;
