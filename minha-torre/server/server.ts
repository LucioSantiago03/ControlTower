import { createApp, analytics, genie, server } from '@databricks/appkit';
import { z } from 'zod';

// O score do modelo (noite 4, bônus) pode NÃO existir no workspace.
// Por isso ele não fica em config/queries (uma tabela inexistente ali quebra o build):
// a rota tenta ler e, se der qualquer erro, responde {disponivel: false} e a tela mostra "—".
const SQL_SCORE = `
  SELECT projeto_id, prob_estouro_30d, ranking, faixa_risco, principais_fatores
  FROM lakehouse_vertice.gold.score_estouro_30d
`;

// O warehouse devolve número como string: z.coerce.number() converte
const linhaScore = z.object({
  projeto_id: z.string(),
  prob_estouro_30d: z.coerce.number(),
  ranking: z.coerce.number(),
  faixa_risco: z.string(),
  principais_fatores: z.string().nullish(),
});

const resultadoScore = z.object({ data: z.array(linhaScore) });

createApp({
  // sem cache: o app lê sempre o que a gold tem agora.
  // genie(): o "Farol · Diretoria" no alias "default" (DATABRICKS_GENIE_SPACE_ID, do app.yaml)
  plugins: [analytics(), genie(), server()],
  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      app.get('/api/score-estouro', async (_req, res) => {
        try {
          const resultado = resultadoScore.parse(await appkit.analytics.query(SQL_SCORE));
          res.json({ disponivel: true, linhas: resultado.data });
        } catch (erro) {
          console.warn('score_estouro_30d indisponível:', erro instanceof Error ? erro.message : erro);
          res.json({ disponivel: false, linhas: [] });
        }
      });
    });
  },
}).catch(console.error);
