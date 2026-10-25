-- gold.projeto_situacao_atual: a FOTOGRAFIA de hoje (16/10/2026), uma linha por projeto.
-- Já traz o cadastro (não existe dim_projeto) e os KPIs calculados sobre as tarefas das
-- três ferramentas (silver.tarefas, o % de hoje). Responde às perguntas 1 e 2 do dono.
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.projeto_situacao_atual
COMMENT 'Situação de cada um dos 60 projetos em 16/10/2026: cadastro (cliente, segmento, tipo, ferramenta, gerente, valor do contrato, orçamento, prazo baseline e status) e os KPIs calculados sobre as tarefas das ferramentas: pv, ev, ac, SPI, CPI, EAC, estouro previsto (EAC - orçamento, só quando positivo), margem projetada, atraso projetado em dias e término projetado. situacao: crítico (SPI ou CPI < 0,8), atenção (< 0,9), ok ou concluído. farol_do_gerente é o último farol publicado, farol_calculado segue o manual da Vértice (verde >= 0,95, amarelo >= 0,90) e melancia marca projeto em andamento com farol verde e SPI < 0,9.'
AS
WITH avanco AS (
  -- Σ horas × % do prazo baseline decorrido (PV) e Σ horas × % concluído (EV), em horas
  SELECT
    projeto_id,
    sum(horas * greatest(0, least(1,
          datediff(DATE'2026-10-16', inicio_baseline) / datediff(fim_baseline, inicio_baseline)))) AS horas_planejadas,
    sum(horas * pct_concluido / 100) AS horas_agregadas,
    sum(horas)                       AS horas_totais
  FROM tarefas
  GROUP BY projeto_id
),

custo_ate_hoje AS (
  SELECT projeto_id, sum(valor) AS ac
  FROM custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id
),

ultimo_status AS (
  -- o farol mais recente que o gerente publicou (para quem está em andamento, o de hoje)
  SELECT projeto_id, max_by(farol, data_status) AS farol_do_gerente
  FROM status_semanal
  WHERE data_status <= DATE'2026-10-16'
  GROUP BY projeto_id
),

valores AS (
  SELECT
    concat(p.projeto_id, ' · ', p.nome_projeto) AS projeto,
    p.projeto_id,
    p.nome_projeto,
    p.cliente,
    p.segmento,
    p.tipo_projeto,
    p.ferramenta,
    p.gerente_projeto,
    p.valor_contrato,
    p.orcamento_custo                            AS orcamento,
    p.data_inicio,
    p.data_fim_baseline,
    datediff(p.data_fim_baseline, p.data_inicio) AS duracao_baseline_dias,
    p.status,
    round(p.orcamento_custo * a.horas_planejadas / a.horas_totais, 2) AS pv,
    round(p.orcamento_custo * a.horas_agregadas  / a.horas_totais, 2) AS ev,
    coalesce(c.ac, 0)                            AS ac,
    s.farol_do_gerente
  FROM projetos p
  LEFT JOIN avanco         a ON a.projeto_id = p.projeto_id
  LEFT JOIN custo_ate_hoje c ON c.projeto_id = p.projeto_id
  LEFT JOIN ultimo_status  s ON s.projeto_id = p.projeto_id
),

indices AS (
  SELECT
    *,
    round(try_divide(ev, pv), 4) AS spi,
    round(try_divide(ev, ac), 4) AS cpi
  FROM valores
),

projecao AS (
  SELECT
    *,
    round(try_divide(orcamento, cpi), 2)                              AS eac,
    round(duracao_baseline_dias / spi - duracao_baseline_dias)        AS atraso_projetado_dias
  FROM indices
)

SELECT
  projeto,
  projeto_id,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  ferramenta,
  gerente_projeto,
  valor_contrato,
  orcamento,
  data_inicio,
  data_fim_baseline,
  duracao_baseline_dias,
  status,
  pv,
  ev,
  ac,
  spi,
  cpi,
  eac,
  greatest(eac - orcamento, 0)                                    AS estouro_previsto,
  round(try_divide(valor_contrato - eac, valor_contrato), 4)       AS margem_projetada,
  atraso_projetado_dias,
  date_add(data_fim_baseline, CAST(atraso_projetado_dias AS INT)) AS termino_projetado,
  CASE
    WHEN status <> 'em_andamento'  THEN 'concluído'
    WHEN spi < 0.8 OR cpi < 0.8    THEN 'crítico'
    WHEN spi < 0.9 OR cpi < 0.9    THEN 'atenção'
    ELSE 'ok'
  END                                                              AS situacao,
  farol_do_gerente,
  -- a regra do manual da Vértice, aplicada ao SPI calculado
  CASE
    WHEN spi IS NULL THEN NULL        -- sem cronograma, sem farol
    WHEN spi >= 0.95 THEN 'verde'
    WHEN spi >= 0.90 THEN 'amarelo'
    ELSE 'vermelho'
  END                                                              AS farol_calculado,
  -- melancia: verde por fora (o gerente), vermelho por dentro (o SPI)
  coalesce(status = 'em_andamento' AND farol_do_gerente = 'verde' AND spi < 0.9, false) AS melancia
FROM projecao;


-- gold.utilizacao_pessoa_semana: a pergunta 3 (gente parada enquanto outro projeto pede gente).
-- Uma linha por pessoa, projeto e semana, com o SPI do projeto naquela semana ao lado.
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.utilizacao_pessoa_semana
COMMENT 'Utilização semanal de cada pessoa em cada projeto (timesheet): nome, papel, senioridade, horas disponíveis, apontadas e ociosas, utilização (apontadas / disponíveis, de 0 a 1), custo ocioso (horas ociosas x custo por hora, em reais) e o SPI do projeto naquela semana. semana é a sexta-feira.'
AS SELECT
  a.colaborador_id,
  c.nome,
  c.papel,
  c.senioridade,
  a.projeto_id,
  a.semana,
  a.horas_disponiveis,
  a.horas_apontadas,
  a.horas_disponiveis - a.horas_apontadas                          AS horas_ociosas,
  round(try_divide(a.horas_apontadas, a.horas_disponiveis), 4)     AS utilizacao,
  round((a.horas_disponiveis - a.horas_apontadas) * c.custo_hora, 2) AS custo_ocioso,
  f.spi                                                            AS spi_do_projeto
FROM apontamentos a
LEFT JOIN colaboradores c
  ON c.colaborador_id = a.colaborador_id
LEFT JOIN lakehouse_vertice.gold.fato_projeto_semana f
  ON f.projeto_id = a.projeto_id AND f.semana = a.semana;
