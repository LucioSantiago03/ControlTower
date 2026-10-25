-- Pessoas com menos de 20% de uso nas últimas 12 semanas (depois de 24/07/2026),
-- com as horas paradas e o custo ocioso MÉDIOS por semana. custo_hora vem do cadastro.
SELECT
  u.colaborador_id,
  u.nome,
  u.papel,
  u.senioridade,
  u.projeto_id,
  try_divide(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) AS utilizacao,
  SUM(u.horas_ociosas) / COUNT(DISTINCT u.semana)              AS horas_paradas_semana,
  SUM(u.custo_ocioso)  / COUNT(DISTINCT u.semana)              AS custo_ocioso_semana,
  MAX(c.custo_hora)                                            AS custo_hora
FROM lakehouse_vertice.gold.utilizacao_pessoa_semana u
JOIN lakehouse_vertice.silver.colaboradores c ON c.colaborador_id = u.colaborador_id
WHERE u.semana > DATE'2026-07-24'
GROUP BY u.colaborador_id, u.nome, u.papel, u.senioridade, u.projeto_id
HAVING try_divide(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) < 0.2
ORDER BY custo_ocioso_semana DESC
