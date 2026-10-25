import { useEffect, useState } from 'react';

// Lê o score do modelo pela rota do servidor (GET /api/score-estouro).
// Se a tabela gold.score_estouro_30d não existir, a rota responde {disponivel: false}
// e a tela mostra "—" em vez de quebrar.

export interface LinhaScore {
  projeto_id: string;
  prob_estouro_30d: number;
  ranking: number;
  faixa_risco: string;
  principais_fatores?: string | null;
}

export interface EstadoScore {
  carregando: boolean;
  disponivel: boolean;
  porProjeto: Map<string, LinhaScore>;
  altoRisco: number | null;
}

function ehResposta(v: unknown): v is { disponivel: boolean; linhas: LinhaScore[] } {
  return typeof v === 'object' && v !== null && 'disponivel' in v && 'linhas' in v && Array.isArray(v.linhas);
}

export function useScoreEstouro(): EstadoScore {
  const [estado, setEstado] = useState<EstadoScore>({
    carregando: true,
    disponivel: false,
    porProjeto: new Map(),
    altoRisco: null,
  });

  useEffect(() => {
    let ativo = true;
    fetch('/api/score-estouro')
      .then((r) => r.json())
      .then((corpo: unknown) => {
        if (!ativo) return;
        if (!ehResposta(corpo) || !corpo.disponivel) {
          setEstado({ carregando: false, disponivel: false, porProjeto: new Map(), altoRisco: null });
          return;
        }
        const linhas = corpo.linhas.map((l) => ({
          ...l,
          prob_estouro_30d: Number(l.prob_estouro_30d),
          ranking: Number(l.ranking),
        }));
        setEstado({
          carregando: false,
          disponivel: true,
          porProjeto: new Map(linhas.map((l) => [l.projeto_id, l])),
          altoRisco: linhas.filter((l) => l.faixa_risco === 'alto').length,
        });
      })
      .catch(() => {
        if (ativo) setEstado({ carregando: false, disponivel: false, porProjeto: new Map(), altoRisco: null });
      });
    return () => {
      ativo = false;
    };
  }, []);

  return estado;
}
