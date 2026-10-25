#!/usr/bin/env python3
"""Gera o dashboard do Projeto Farol (AI/BI, GRID_V1) como código.

Escreve resources/dashboard-portfolio.lvdash.json, que o recurso
resources/dashboard.dashboard.yml publica pelo bundle.

As queries da gold usam o nome PURO da tabela: o catálogo e o schema vêm do
recurso (dataset_catalog / dataset_schema). A silver.entregas_fornecedor vai com
o nome completo, porque o schema padrão do dashboard é a gold.

Uso:
  python3 scripts/gerar_dashboard.py                 # gera o JSON
  python3 scripts/gerar_dashboard.py --sql x.sql     # também escreve as queries com o
                                                     # nome completo, para conferir com run_sql.py
"""
import argparse, json, re
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SAIDA = RAIZ / "resources" / "dashboard-portfolio.lvdash.json"
TABELAS_GOLD = ["projeto_situacao_atual", "fato_projeto_semana",
                "utilizacao_pessoa_semana", "status_estruturado"]

# Cores da Jornada e da situação do projeto
AZUL, CIANO, FUNDO_ESCURO = "#0059DB", "#22C2F4", "#14141A"
SITUACAO = [("crítico", "#FF5F46"), ("atenção", "#F6C344"), ("ok", CIANO)]


# ---------------------------------------------------------------- datasets
# Toda a regra de negócio fica no SQL. Razão é SUM/SUM, nunca AVG de razão.
DATASETS = {
    # Portfólio: uma linha com os KPIs da carteira em andamento.
    # O CPI soma o AC só de quem tem EV (projeto sem cronograma não entra só de um lado da razão).
    "ds_kpis": ("KPIs da carteira", """
SELECT
  SUM(valor_contrato)                                        AS carteira,
  try_divide(SUM(ev), SUM(pv))                               AS spi,
  try_divide(SUM(ev), SUM(CASE WHEN ev IS NOT NULL THEN ac END)) AS cpi,
  SUM(estouro_previsto)                                      AS estouro_previsto,
  COUNT_IF(situacao IN ('atenção', 'crítico'))               AS em_risco,
  COUNT_IF(situacao = 'crítico')                             AS criticos,
  COUNT_IF(melancia)                                         AS melancias
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
"""),
    # Portfólio: um projeto em andamento por linha (barra, dispersão e tabela)
    "ds_projetos": ("Projetos em andamento", """
SELECT
  projeto, projeto_id, cliente, segmento, gerente_projeto, situacao,
  spi, cpi, eac, estouro_previsto, margem_projetada, atraso_projetado_dias,
  farol_do_gerente, farol_calculado,
  CASE WHEN melancia THEN 'sim' ELSE '' END AS melancia
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
ORDER BY estouro_previsto DESC
"""),
    # Portfólio: SPI e CPI da carteira por semana (só linhas com PV, para EV e PV virem do mesmo grupo)
    "ds_carteira_semanal": ("Carteira por semana", """
SELECT
  semana,
  try_divide(SUM(ev), SUM(pv)) AS spi,
  try_divide(SUM(ev), SUM(ac)) AS cpi
FROM fato_projeto_semana
WHERE semana >= DATE'2025-03-07' AND pv IS NOT NULL
GROUP BY semana
ORDER BY semana
"""),
    # Pessoas: as 15 pessoas com mais custo de hora parada nas últimas 12 semanas
    "ds_top_parados": ("Top 15 hora parada", """
SELECT
  concat(nome, ' (', papel, ')')                          AS pessoa,
  SUM(custo_ocioso)                                      AS custo_ocioso,
  try_divide(SUM(horas_apontadas), SUM(horas_disponiveis)) AS utilizacao
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY nome, papel
ORDER BY custo_ocioso DESC
LIMIT 15
"""),
    # Pessoas: utilização por pessoa e projeto, da mais parada à mais ocupada
    "ds_utilizacao": ("Utilização por pessoa e projeto", """
SELECT
  colaborador_id, nome, papel, senioridade, projeto_id,
  SUM(horas_disponiveis)                                   AS horas_disponiveis,
  SUM(horas_apontadas)                                     AS horas_apontadas,
  SUM(horas_ociosas)                                       AS horas_ociosas,
  try_divide(SUM(horas_apontadas), SUM(horas_disponiveis)) AS utilizacao,
  SUM(custo_ocioso)                                        AS custo_ocioso,
  try_divide(SUM(spi_do_projeto * horas_disponiveis), SUM(horas_disponiveis)) AS spi_do_projeto
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY colaborador_id, nome, papel, senioridade, projeto_id
ORDER BY utilizacao ASC, custo_ocioso DESC
"""),
    # Pessoas: a causa do bloqueio que o gerente escreveu, nos últimos 90 dias
    "ds_causas": ("Causas de bloqueio (90 dias)", """
SELECT projeto_id, causa_bloqueio, COUNT(*) AS semanas, SUM(dias_impacto) AS dias_impacto
FROM status_estruturado
WHERE data_status >= DATE'2026-07-18'
  AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
GROUP BY projeto_id, causa_bloqueio
ORDER BY projeto_id
"""),
    # Fornecedores: um resumo por consultoria
    "ds_fornecedores": ("Fornecedores", """
SELECT
  fornecedor,
  COUNT(DISTINCT fornecedor_como_veio)                       AS grafias,
  concat_ws(' | ', sort_array(collect_set(fornecedor_como_veio))) AS grafias_no_cadastro,
  COUNT(*)                                                   AS entregas,
  try_divide(SUM(CASE WHEN NOT em_aberto THEN prazo_real_dias END),
             SUM(CASE WHEN NOT em_aberto THEN prazo_prometido_dias END)) AS prazo_real_sobre_prometido,
  try_divide(COUNT_IF(NOT em_aberto AND data_entrega <= data_prometida),
             COUNT_IF(NOT em_aberto))                        AS pct_no_prazo,
  COUNT_IF(em_atraso)                                        AS em_atraso_hoje
FROM lakehouse_vertice.silver.entregas_fornecedor
GROUP BY fornecedor
ORDER BY prazo_real_sobre_prometido DESC
"""),
    # Fornecedores: o que está atrasado hoje (16/10/2026)
    "ds_entregas_atraso": ("Entregas em atraso hoje", """
SELECT
  entrega_id, projeto_id, fornecedor, item, valor, data_pedido, data_prometida,
  datediff(DATE'2026-10-16', data_prometida) AS dias_em_atraso
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE em_atraso
ORDER BY dias_em_atraso DESC
"""),
}


def dataset(nome: str) -> dict:
    titulo, sql = DATASETS[nome]
    linhas = [l + "\n" for l in sql.strip().splitlines()]   # cada linha termina em \n
    return {"name": nome, "displayName": titulo, "queryLines": linhas}


# ---------------------------------------------------------------- widgets
MOEDA = {"type": "number-currency", "currencyCode": "BRL", "abbreviation": "compact",
         "decimalPlaces": {"type": "max", "places": 2}}
INDICE = {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}}
PERCENTUAL = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}
CORES_SITUACAO = {"type": "categorical",
                  "mappings": [{"value": v, "color": c} for v, c in SITUACAO]}


def campo(nome: str) -> dict:
    return {"name": nome, "expression": f"`{nome}`"}


def pos(x, y, w, h) -> dict:
    return {"x": x, "y": y, "width": w, "height": h}


def titulo(nome: str, pergunta: str, subtitulo: str, y: int = 0) -> dict:
    return {"widget": {"name": nome, "multilineTextboxSpec": {
                "lines": [f"## {pergunta}\n", "\n", subtitulo]}},
            "position": pos(0, y, 12, 2)}


def kpi(nome, campo_valor, titulo_kpi, formato, posicao, descricao=None) -> dict:
    valor = {"fieldName": campo_valor, "displayName": titulo_kpi}
    if formato:
        valor["format"] = formato
    frame = {"title": titulo_kpi, "showTitle": True}
    if descricao:
        frame.update(description=descricao, showDescription=True)
    return {"widget": {
                "name": nome,
                "queries": [{"name": "main_query", "query": {
                    "datasetName": "ds_kpis", "fields": [campo(campo_valor)], "disaggregated": True}}],
                "spec": {"version": 2, "widgetType": "counter",
                         "encodings": {"value": valor}, "frame": frame}},
            "position": posicao}


def tabela(nome, ds, colunas, titulo_tab, posicao, descricao=None) -> dict:
    """colunas: lista de (campo, rótulo, formato ou None)"""
    encs = []
    for c, rotulo, formato in colunas:
        e = {"fieldName": c, "displayName": rotulo}
        if formato:
            e["format"] = formato
        encs.append(e)
    frame = {"showTitle": True, "title": titulo_tab}
    if descricao:
        frame.update(description=descricao, showDescription=True)
    return {"widget": {
                "name": nome,
                "queries": [{"name": "main_query", "query": {
                    "datasetName": ds, "fields": [campo(c) for c, _, _ in colunas],
                    "disaggregated": True}}],
                "spec": {"version": 2, "widgetType": "table",
                         "encodings": {"columns": encs}, "frame": frame}},
            "position": posicao}


def linha_limite(eixo: str, valor: str, rotulo: str) -> dict:
    """Linha de referência (o corte de atenção do SPI/CPI)."""
    return {"type": "horizontal-line" if eixo == "y" else "vertical-line",
            "encodings": {eixo: {"dataValue": valor, "dataType": "DOUBLE"},
                          "label": {"value": rotulo}, "color": {"value": "#F6C344"}}}


# ---------------------------------------------------------------- página 1: Portfólio
def pagina_portfolio() -> dict:
    layout = [
        titulo("titulo_portfolio",
               "Quais projetos estão atrasados, de quais clientes, e quanto isso vai custar?",
               "Carteira em andamento em 16/10/2026. SPI ou CPI abaixo de 0,9 = atenção, abaixo de 0,8 = crítico. "
               "Melancia = farol do gerente verde com SPI abaixo de 0,9."),
        kpi("kpi_carteira", "carteira", "Carteira em andamento", MOEDA, pos(0, 2, 3, 3), "Soma do valor dos contratos"),
        kpi("kpi_spi", "spi", "SPI da carteira", INDICE, pos(3, 2, 3, 3), "Σ EV ÷ Σ PV (abaixo de 1 = atraso)"),
        kpi("kpi_cpi", "cpi", "CPI da carteira", INDICE, pos(6, 2, 3, 3), "Σ EV ÷ Σ AC (abaixo de 1 = estouro)"),
        kpi("kpi_estouro", "estouro_previsto", "Estouro previsto", MOEDA, pos(9, 2, 3, 3), "Σ (EAC − orçamento), quando positivo"),
        kpi("kpi_em_risco", "em_risco", "Projetos em risco", None, pos(0, 5, 4, 3), "Atenção + crítico"),
        kpi("kpi_criticos", "criticos", "Críticos", None, pos(4, 5, 4, 3), "SPI ou CPI abaixo de 0,8"),
        kpi("kpi_melancias", "melancias", "Melancias", None, pos(8, 5, 4, 3), "Verde por fora, vermelho por dentro"),

        # barra horizontal: estouro previsto por projeto, colorida pela situação
        {"widget": {
            "name": "barra_estouro",
            "queries": [{"name": "main_query", "query": {
                "datasetName": "ds_projetos",
                "fields": [campo("projeto"), campo("situacao"),
                           {"name": "sum(estouro_previsto)", "expression": "SUM(`estouro_previsto`)"}],
                "filters": [{"expression": "`estouro_previsto` > 0"}],
                "disaggregated": False}}],
            "spec": {"version": 3, "widgetType": "bar",
                     "encodings": {
                         "x": {"fieldName": "sum(estouro_previsto)", "scale": {"type": "quantitative"},
                               "displayName": "Estouro previsto", "format": MOEDA},
                         "y": {"fieldName": "projeto", "displayName": "Projeto",
                               "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}},
                         "color": {"fieldName": "situacao", "displayName": "Situação", "scale": CORES_SITUACAO}},
                     "frame": {"showTitle": True, "title": "Estouro previsto por projeto",
                               "description": "EAC − orçamento, só dos projetos que vão estourar",
                               "showDescription": True}}},
         "position": pos(0, 8, 6, 7)},

        # dispersão SPI × CPI: um ponto por projeto
        {"widget": {
            "name": "dispersao_spi_cpi",
            "queries": [{"name": "main_query", "query": {
                "datasetName": "ds_projetos",
                "fields": [campo("spi"), campo("cpi"), campo("situacao"), campo("projeto")],
                "disaggregated": True}}],
            "spec": {"version": 3, "widgetType": "scatter",
                     "encodings": {
                         "x": {"fieldName": "spi", "displayName": "SPI", "scale": {"type": "quantitative"}},
                         "y": {"fieldName": "cpi", "displayName": "CPI", "scale": {"type": "quantitative"}},
                         "color": {"fieldName": "situacao", "displayName": "Situação", "scale": CORES_SITUACAO},
                         "extra": [{"fieldName": "projeto", "displayName": "Projeto"}]},
                     "annotations": [linha_limite("x", "0.9", "SPI 0,9"), linha_limite("y", "0.9", "CPI 0,9")],
                     "frame": {"showTitle": True, "title": "SPI × CPI, um ponto por projeto",
                               "description": "Embaixo e à esquerda: atrasado e estourando",
                               "showDescription": True}}},
         "position": pos(6, 8, 6, 7)},

        # linha: SPI e CPI semanais da carteira
        {"widget": {
            "name": "linha_spi_cpi_semanal",
            "queries": [{"name": "main_query", "query": {
                "datasetName": "ds_carteira_semanal",
                "fields": [campo("semana"), campo("spi"), campo("cpi")],
                "disaggregated": True}}],
            "spec": {"version": 3, "widgetType": "line",
                     "encodings": {
                         "x": {"fieldName": "semana", "displayName": "Semana", "scale": {"type": "temporal"}},
                         "y": {"scale": {"type": "quantitative"},
                               "fields": [{"fieldName": "spi", "displayName": "SPI"},
                                          {"fieldName": "cpi", "displayName": "CPI"}]}},
                     "annotations": [linha_limite("y", "0.9", "limite de atenção (0,9)")],
                     "frame": {"showTitle": True, "title": "SPI e CPI da carteira, semana a semana",
                               "description": "Σ EV ÷ Σ PV e Σ EV ÷ Σ AC de todos os projetos em cada sexta",
                               "showDescription": True}}},
         "position": pos(0, 15, 12, 6)},

        tabela("tabela_projetos", "ds_projetos", [
            ("projeto", "Projeto", None),
            ("cliente", "Cliente", None),
            ("gerente_projeto", "Gerente", None),
            ("situacao", "Situação", None),
            ("spi", "SPI", INDICE),
            ("cpi", "CPI", INDICE),
            ("farol_do_gerente", "Farol do gerente", None),
            ("farol_calculado", "Farol pelo número", None),
            ("melancia", "Melancia", None),
            ("estouro_previsto", "Estouro previsto", MOEDA),
            ("atraso_projetado_dias", "Atraso projetado (dias)", None),
            ("margem_projetada", "Margem projetada", PERCENTUAL),
        ], "Projetos em andamento: o farol do gerente ao lado do farol pelo número",
           pos(0, 21, 12, 9)),
    ]
    return {"name": "portfolio", "displayName": "Portfólio", "pageType": "PAGE_TYPE_CANVAS",
            "layoutVersion": "GRID_V1", "layout": layout}


# ---------------------------------------------------------------- página 2: Pessoas
def pagina_pessoas() -> dict:
    layout = [
        titulo("titulo_pessoas",
               "Tenho gente parada enquanto outro projeto pede gente?",
               "Timesheet das últimas 12 semanas (depois de 24/07/2026) e a causa que o gerente escreveu no status, "
               "lida pela IA, nos últimos 90 dias."),

        {"widget": {
            "name": "barra_top_parados",
            "queries": [{"name": "main_query", "query": {
                "datasetName": "ds_top_parados",
                "fields": [campo("pessoa"),
                           {"name": "sum(custo_ocioso)", "expression": "SUM(`custo_ocioso`)"}],
                "disaggregated": False}}],
            "spec": {"version": 3, "widgetType": "bar",
                     "encodings": {
                         "x": {"fieldName": "sum(custo_ocioso)", "scale": {"type": "quantitative"},
                               "displayName": "Custo da hora parada", "format": MOEDA},
                         "y": {"fieldName": "pessoa", "displayName": "Pessoa",
                               "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}}},
                     "frame": {"showTitle": True, "title": "Top 15: custo da hora parada (12 semanas)",
                               "description": "Horas ociosas × custo por hora",
                               "showDescription": True}}},
         "position": pos(0, 2, 6, 8)},

        {"widget": {
            "name": "barra_causas",
            "queries": [{"name": "main_query", "query": {
                "datasetName": "ds_causas",
                "fields": [campo("projeto_id"), campo("causa_bloqueio"),
                           {"name": "sum(semanas)", "expression": "SUM(`semanas`)"}],
                "disaggregated": False}}],
            "spec": {"version": 3, "widgetType": "bar",
                     "encodings": {
                         "x": {"fieldName": "sum(semanas)", "scale": {"type": "quantitative"},
                               "displayName": "Semanas com bloqueio"},
                         "y": {"fieldName": "projeto_id", "displayName": "Projeto",
                               "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}},
                         "color": {"fieldName": "causa_bloqueio", "displayName": "Causa",
                                   "scale": {"type": "categorical"}}},
                     "frame": {"showTitle": True, "title": "Causas de bloqueio por projeto (90 dias)",
                               "description": "Semanas em que o status trouxe bloqueio, por causa",
                               "showDescription": True}}},
         "position": pos(6, 2, 6, 8)},

        tabela("tabela_utilizacao", "ds_utilizacao", [
            ("nome", "Pessoa", None),
            ("colaborador_id", "ID", None),
            ("papel", "Papel", None),
            ("senioridade", "Senioridade", None),
            ("projeto_id", "Projeto", None),
            ("horas_disponiveis", "Horas disponíveis", None),
            ("horas_apontadas", "Horas apontadas", None),
            ("utilizacao", "Utilização", PERCENTUAL),
            ("custo_ocioso", "Custo ocioso", MOEDA),
            ("spi_do_projeto", "SPI do projeto", INDICE),
        ], "Utilização por pessoa e projeto, da mais parada à mais ocupada", pos(0, 10, 12, 9),
           "Últimas 12 semanas"),
    ]
    return {"name": "pessoas", "displayName": "Pessoas", "pageType": "PAGE_TYPE_CANVAS",
            "layoutVersion": "GRID_V1", "layout": layout}


# ---------------------------------------------------------------- página 3: Fornecedores
def pagina_fornecedores() -> dict:
    layout = [
        titulo("titulo_fornecedores",
               "O que vai dar errado no próximo mês?",
               "As consultorias que já atrasam hoje: prazo real ÷ prometido, entregas no prazo e o que está em aberto "
               "depois da data prometida (16/10/2026)."),
        tabela("tabela_fornecedores", "ds_fornecedores", [
            ("fornecedor", "Fornecedor", None),
            ("grafias", "Grafias no cadastro", None),
            ("grafias_no_cadastro", "Como veio escrito", None),
            ("entregas", "Entregas", None),
            ("prazo_real_sobre_prometido", "Prazo real ÷ prometido", INDICE),
            ("pct_no_prazo", "% no prazo", PERCENTUAL),
            ("em_atraso_hoje", "Em atraso hoje", None),
        ], "Fornecedores", pos(0, 2, 12, 6)),
        tabela("tabela_entregas_atraso", "ds_entregas_atraso", [
            ("entrega_id", "Entrega", None),
            ("projeto_id", "Projeto", None),
            ("fornecedor", "Fornecedor", None),
            ("item", "Item", None),
            ("valor", "Valor", MOEDA),
            ("data_pedido", "Pedido em", None),
            ("data_prometida", "Prometida para", None),
            ("dias_em_atraso", "Dias em atraso", None),
        ], "Entregas em atraso hoje", pos(0, 8, 12, 6)),
    ]
    return {"name": "fornecedores", "displayName": "Fornecedores", "pageType": "PAGE_TYPE_CANVAS",
            "layoutVersion": "GRID_V1", "layout": layout}


# ---------------------------------------------------------------- tema e saída
TEMA = {
    "canvasBackgroundColor": {"light": "#F5F7FA", "dark": FUNDO_ESCURO},
    "widgetBackgroundColor": {"light": "#FFFFFF", "dark": "#1D1D25"},
    "widgetBorderColor":     {"light": "#FFFFFF", "dark": "#1D1D25"},
    "fontColor":             {"light": FUNDO_ESCURO, "dark": "#EDEFF5"},
    "selectionColor":        {"light": AZUL, "dark": CIANO},
    "visualizationColors":   [AZUL, CIANO, "#F6C344", "#FF5F46", "#8E7CF0", "#2ECC9A", "#A0A7B4"],
    "widgetHeaderAlignment": "LEFT",
}


def dashboard() -> dict:
    return {"datasets": [dataset(n) for n in DATASETS],
            "pages": [pagina_portfolio(), pagina_pessoas(), pagina_fornecedores()],
            "uiSettings": {"theme": TEMA}}


def sql_de_conferencia() -> str:
    """Cada query com o nome completo da gold: a contagem de linhas e, para os KPIs, os valores."""
    padrao = re.compile(r"\b(FROM|JOIN)\s+(" + "|".join(TABELAS_GOLD) + r")\b")
    partes = []
    for nome, (_, sql) in DATASETS.items():
        completo = padrao.sub(r"\1 lakehouse_vertice.gold.\2", sql.strip())
        partes.append(f"SELECT '{nome}' AS dataset, count(*) AS linhas FROM (\n{completo}\n)")
        if nome == "ds_kpis":
            partes.append(completo)
    return ";\n\n".join(partes) + ";\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", help="escreve também as queries com o nome completo neste arquivo")
    args = ap.parse_args()

    SAIDA.write_text(json.dumps(dashboard(), ensure_ascii=False, indent=2), encoding="utf-8")
    widgets = sum(len(p["layout"]) for p in dashboard()["pages"])
    print(f"{SAIDA.relative_to(RAIZ)}: {len(DATASETS)} datasets, 3 páginas, {widgets} widgets")

    if args.sql:
        Path(args.sql).write_text(sql_de_conferencia(), encoding="utf-8")
        print(f"{args.sql}: queries de conferência")


if __name__ == "__main__":
    main()
