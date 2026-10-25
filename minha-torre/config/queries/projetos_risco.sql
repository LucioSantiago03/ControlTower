-- Projetos em andamento, do pior para o melhor, com o que o gerente escreveu no status.
-- A causa vem do gold.status_estruturado dos últimos 90 dias (desde 18/07/2026).
WITH bloqueios AS (
  SELECT projeto_id, causa_bloqueio, COUNT(*) AS semanas, SUM(dias_impacto) AS dias
  FROM lakehouse_vertice.gold.status_estruturado
  WHERE data_status >= DATE'2026-07-18'
    AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
  GROUP BY projeto_id, causa_bloqueio
),
por_projeto AS (
  SELECT
    projeto_id,
    max_by(causa_bloqueio, semanas)                                   AS causa_principal,
    coalesce(SUM(CASE WHEN causa_bloqueio = 'falta_sre'    THEN dias END), 0) AS dias_falta_sre,
    coalesce(SUM(CASE WHEN causa_bloqueio = 'rotatividade' THEN dias END), 0) AS dias_rotatividade
  FROM bloqueios
  GROUP BY projeto_id
)
SELECT
  p.projeto_id,
  p.projeto,
  p.cliente,
  p.situacao,
  p.spi,
  p.cpi,
  p.estouro_previsto,
  p.atraso_projetado_dias,
  p.farol_do_gerente,
  p.farol_calculado,
  p.melancia,
  b.causa_principal,
  coalesce(b.dias_falta_sre, 0)    AS dias_falta_sre,
  coalesce(b.dias_rotatividade, 0) AS dias_rotatividade
FROM lakehouse_vertice.gold.projeto_situacao_atual p
LEFT JOIN por_projeto b ON b.projeto_id = p.projeto_id
WHERE p.status = 'em_andamento'
ORDER BY
  CASE p.situacao WHEN 'crítico' THEN 1 WHEN 'atenção' THEN 2 ELSE 3 END,
  p.spi ASC NULLS FIRST,
  p.projeto_id
