#!/usr/bin/env python3
"""Gera o Genie "Farol · Diretoria" como código.

Escreve resources/farol.geniespace.json (serialized_space versão 2), que o recurso
resources/genie.genie_space.yml publica pelo bundle.

O score do modelo (gold.score_estouro_30d) só entra se a tabela existir no workspace:
sem ela, nenhuma instrução nem exemplo fala de score.

Uso:
  python3 scripts/gerar_genie.py --profile <perfil>        # confere o score no workspace
  python3 scripts/gerar_genie.py --sem-score               # gera sem consultar o workspace
"""
import argparse, json, subprocess
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SAIDA = RAIZ / "resources" / "farol.geniespace.json"
CAT = "lakehouse_vertice"
SCORE = f"{CAT}.gold.score_estouro_30d"


def score_existe(perfil: str) -> bool:
    r = subprocess.run(["databricks", "tables", "exists", SCORE, "--profile", perfil, "-o", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"não deu para conferir {SCORE}: {r.stderr.strip()}")
    return bool(json.loads(r.stdout).get("table_exists"))


# ids de 32 caracteres hex, únicos e em ordem: 2 dígitos de grupo + 30 de sequência
def ids(grupo: int):
    n = 0
    while True:
        n += 1
        yield f"{grupo:02x}{n:030x}"


# ---------------------------------------------------------------- as 4 perguntas do dono
PERGUNTAS_DO_DONO = [
    "Quais projetos estão atrasados, e de quais clientes?",
    "Quanto esse atraso vai me custar?",
    "Tenho gente parada enquanto outro projeto pede gente?",
    "O que vai dar errado no próximo mês?",
]

# Projetos de e-commerce (a regra do change freeze do varejo)
E_COMMERCE = ("(lower(tipo_projeto) LIKE '%commerce%' OR lower(tipo_projeto) LIKE '%checkout%' "
              "OR lower(tipo_projeto) LIKE '%marketplace%')")


def instrucoes(com_score: bool) -> list[str]:
    linhas = [
        "QUEM PERGUNTA: o dono e a diretoria da Vértice Tecnologia, que não escrevem SQL. Responda em português, "
        "direto, com números em reais (R$) e índices com 2 casas. Termine com o que fazer agora quando a pergunta pedir.",

        "HOJE = 2026-10-16 (sexta). Nunca use current_date(). 'Últimos 90 dias' = data_status >= DATE'2026-07-18'. "
        "'Últimas 12 semanas' = semana > DATE'2026-07-24'. 'Próximo mês' = de 2026-10-17 a 2026-11-16. "
        "Toda coluna semana e data_status é uma sexta-feira.",

        "FÓRMULAS: SPI = EV ÷ PV (abaixo de 1 é atraso). CPI = EV ÷ AC (abaixo de 1 é estouro). EAC = orçamento ÷ CPI. "
        "Estouro previsto = EAC − orçamento, só quando positivo. Margem projetada = (contrato − EAC) ÷ contrato. "
        "Atraso projetado (dias) = duração baseline ÷ SPI − duração baseline. Razão da carteira é SUM ÷ SUM, nunca média de razão.",

        "REGRAS DE CORTE: SPI ou CPI abaixo de 0,8 = 'crítico'. Abaixo de 0,9 = 'atenção'. Senão 'ok'. A coluna situacao "
        "já traz isso ('crítico', 'atenção', 'ok', 'concluído'), com acento. 'Em risco' = atenção + crítico. "
        "Projeto em andamento = status = 'em_andamento'.",

        "ONDE BUSCAR: para totais da carteira de hoje (SPI, CPI, estouro previsto, EAC, margem, contagens) use a metric "
        "view gold.mv_projetos com MEASURE(...): ela já filtra os projetos em andamento. Para ranking, lista ou um "
        "projeto específico use gold.projeto_situacao_atual com status = 'em_andamento'. Para a história semana a "
        "semana use gold.fato_projeto_semana.",

        "AO LISTAR PROJETOS, sempre devolva a coluna projeto (código e nome, como 'PRJ-011 · Nome') da "
        "gold.projeto_situacao_atual. Para achar um projeto pelo código use projeto_id = 'PRJ-011'. "
        "'Quais clientes' devolve cada cliente uma vez (SELECT DISTINCT cliente).",

        "FATO SEMANAL: pv, ev e ac da gold.fato_projeto_semana já são ACUMULADOS até a semana. Nunca some semanas. "
        "Para o valor de uma semana, filtre semana = a sexta pedida. Para hoje, semana = DATE'2026-10-16'.",

        "FAROL E MELANCIA: farol_do_gerente é o que o gerente declarou. farol_calculado é a regra do manual (verde com "
        "SPI a partir de 0,95, amarelo a partir de 0,90, senão vermelho). Melancia = farol do gerente verde e SPI "
        "abaixo de 0,9 (coluna melancia). 'Farol verde mas atrasado' = melancia.",

        "POR QUE O PROJETO X ATRASOU: responda com gold.status_estruturado dos últimos 90 dias, sem causa_bloqueio "
        "'sem_bloqueio' e 'nao_reportado': a causa mais frequente (contagem de semanas), os dias_impacto declarados, "
        "o bloqueio e quem_destrava. Junte o SPI e o CPI de hoje do projeto. Se a causa for 'falta_sre', mostre também "
        "os SREs ociosos (papel = 'sre' com utilização abaixo de 20% nas últimas 12 semanas).",

        "GENTE PARADA: utilização = SUM(horas_apontadas) ÷ SUM(horas_disponiveis) na gold.utilizacao_pessoa_semana, "
        "nas últimas 12 semanas, agrupando por colaborador_id. Parada = utilização abaixo de 20%. "
        "Custo da hora parada = SUM(custo_ocioso). Compare com os projetos em atenção ou crítico que reclamam de "
        "'falta_sre' no status.",

        "FORNECEDOR: use silver.entregas_fornecedor (não há tabela gold). O quanto atrasa = prazo_real_dias ÷ "
        "prazo_prometido_dias (média por fornecedor, maior = mais atrasa). em_atraso = entrega em aberto com data "
        "prometida já vencida em 16/10/2026. A CodeForge Consultoria Ltda é o fornecedor que mais atrasa.",

        "O QUE VAI DAR ERRADO NO PRÓXIMO MÊS: junte (1) as entregas de consultoria em atraso hoje (em_atraso), com "
        "projeto e fornecedor, e (2) o change freeze de varejo, de 01/11/2026 a 10/01/2027, que trava deploy nos "
        f"projetos de e-commerce em andamento: {E_COMMERCE}.",
    ]
    if com_score:
        linhas.append(
            "MODELO (gold.score_estouro_30d): prob_estouro_30d é a chance de o projeto terminar o próximo mês com SPI ou "
            "CPI abaixo de 0,9. Use sempre a data_referencia mais recente. Faixas: alto (a partir de 0,5), medio (a "
            "partir de 0,2), baixo. Em 'o que vai dar errado no próximo mês' some (3) os projetos com situacao = 'ok' "
            "hoje e faixa_risco alto ou medio, com principais_fatores.")
    return linhas


def exemplos(com_score: bool) -> list[tuple[str, str]]:
    g = f"{CAT}.gold"
    lista = [
        (PERGUNTAS_DO_DONO[0],
         f"SELECT projeto, cliente, situacao, ROUND(spi, 2) AS spi, ROUND(cpi, 2) AS cpi, "
         f"ROUND(atraso_projetado_dias) AS atraso_projetado_dias\n"
         f"FROM {g}.projeto_situacao_atual\n"
         f"WHERE status = 'em_andamento' AND situacao IN ('crítico', 'atenção')\n"
         f"ORDER BY CASE situacao WHEN 'crítico' THEN 1 ELSE 2 END, spi"),
        (PERGUNTAS_DO_DONO[1],
         f"SELECT ROUND(MEASURE(estouro_previsto), 2) AS estouro_previsto, ROUND(MEASURE(eac), 2) AS eac,\n"
         f"       ROUND(MEASURE(margem_projetada), 4) AS margem_projetada, MEASURE(projetos_em_risco) AS projetos_em_risco\n"
         f"FROM {g}.mv_projetos"),
        (PERGUNTAS_DO_DONO[2],
         f"SELECT colaborador_id, nome, papel, projeto_id,\n"
         f"       ROUND(SUM(horas_apontadas) / SUM(horas_disponiveis), 3) AS utilizacao,\n"
         f"       ROUND(SUM(custo_ocioso), 2) AS custo_ocioso_12_semanas\n"
         f"FROM {g}.utilizacao_pessoa_semana\n"
         f"WHERE semana > DATE'2026-07-24'\n"
         f"GROUP BY colaborador_id, nome, papel, projeto_id\n"
         f"HAVING SUM(horas_apontadas) / SUM(horas_disponiveis) < 0.2\n"
         f"ORDER BY custo_ocioso_12_semanas DESC"),
        (PERGUNTAS_DO_DONO[3],
         f"SELECT 'entrega de consultoria em atraso' AS risco, e.projeto_id, e.fornecedor AS detalhe,\n"
         f"       datediff(DATE'2026-10-16', e.data_prometida) AS dias\n"
         f"FROM {CAT}.silver.entregas_fornecedor e\n"
         f"WHERE e.em_atraso\n"
         f"UNION ALL\n"
         f"SELECT 'change freeze do varejo (01/11/2026 a 10/01/2027)', p.projeto_id, p.projeto,\n"
         f"       datediff(DATE'2027-01-10', DATE'2026-11-01') AS dias\n"
         f"FROM {g}.projeto_situacao_atual p\n"
         f"WHERE p.status = 'em_andamento' AND {E_COMMERCE.replace('tipo_projeto', 'p.tipo_projeto')}"),
    ]
    if com_score:
        lista.append((
            "Qual a chance de o PRJ-024 estourar?",
            f"SELECT projeto_id, ROUND(prob_estouro_30d, 2) AS prob_estouro_30d, faixa_risco, principais_fatores\n"
            f"FROM {SCORE}\n"
            f"WHERE projeto_id = 'PRJ-024' AND data_referencia = (SELECT MAX(data_referencia) FROM {SCORE})"))
    return lista


def colunas(*cfgs: dict) -> list[dict]:
    return sorted(cfgs, key=lambda c: c["column_name"])


def espaco(com_score: bool) -> dict:
    g, s = f"{CAT}.gold", f"{CAT}.silver"
    tabelas = [
        {"identifier": f"{g}.fato_projeto_semana"},
        {"identifier": f"{g}.projeto_situacao_atual", "column_configs": colunas(
            {"column_name": "cliente", "enable_entity_matching": True, "enable_format_assistance": True},
            {"column_name": "projeto", "description": ["Código e nome do projeto ('PRJ-011 · Nome'). Devolva ao listar projetos."]},
            {"column_name": "situacao", "enable_entity_matching": True, "enable_format_assistance": True},
            {"column_name": "tipo_projeto", "enable_format_assistance": True},
        )},
        {"identifier": f"{g}.status_estruturado", "column_configs": colunas(
            {"column_name": "causa_bloqueio", "enable_entity_matching": True, "enable_format_assistance": True},
        )},
        {"identifier": f"{g}.utilizacao_pessoa_semana", "column_configs": colunas(
            {"column_name": "papel", "enable_entity_matching": True, "enable_format_assistance": True},
        )},
        {"identifier": f"{s}.entregas_fornecedor", "column_configs": colunas(
            {"column_name": "fornecedor", "enable_entity_matching": True, "enable_format_assistance": True},
        )},
    ]
    if com_score:
        tabelas.append({"identifier": SCORE})

    id_pergunta, id_exemplo, id_texto = ids(1), ids(2), ids(3)
    return {
        "version": 2,
        "config": {"sample_questions": [{"id": next(id_pergunta), "question": [p]} for p in PERGUNTAS_DO_DONO]},
        "data_sources": {
            "tables": sorted(tabelas, key=lambda t: t["identifier"]),
            "metric_views": [{"identifier": f"{g}.mv_projetos"}],
        },
        "instructions": {
            "text_instructions": [{"id": next(id_texto), "content": [l + "\n" for l in instrucoes(com_score)]}],
            "example_question_sqls": [
                {"id": next(id_exemplo), "question": [q], "sql": [l + "\n" for l in sql.split("\n")]}
                for q, sql in exemplos(com_score)
            ],
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    grupo = ap.add_mutually_exclusive_group(required=True)
    grupo.add_argument("--profile", help="perfil do ~/.databrickscfg (confere se o score existe)")
    grupo.add_argument("--sem-score", action="store_true", help="gera sem o score, sem consultar o workspace")
    a = ap.parse_args()

    com_score = False if a.sem_score else score_existe(a.profile)
    corpo = espaco(com_score)
    SAIDA.write_text(json.dumps(corpo, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{SAIDA.relative_to(RAIZ)}: {len(corpo['data_sources']['tables'])} tabelas + 1 metric view, "
          f"{len(corpo['instructions']['example_question_sqls'])} exemplos de SQL, "
          f"score {'incluído' if com_score else 'fora (a tabela não existe)'}")


if __name__ == "__main__":
    main()
