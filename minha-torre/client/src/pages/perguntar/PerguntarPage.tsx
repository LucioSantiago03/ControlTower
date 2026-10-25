import { GenieChat } from '@databricks/appkit-ui/react';

// A tela Perguntar: o Genie "Farol · Diretoria" (alias "default" do plugin genie no servidor).
export function PerguntarPage() {
  return (
    <div className="space-y-4 w-full max-w-5xl mx-auto">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Perguntar</h2>
        <p className="text-sm text-muted-foreground">
          Pergunte em português sobre a carteira da Vértice. O Genie consulta a gold em seu nome (com as suas
          permissões) e mostra o SQL de cada resposta.
        </p>
      </div>
      <div className="h-[640px] rounded-md border">
        <GenieChat alias="default" />
      </div>
      <p className="text-xs text-muted-foreground">
        Resposta gerada por IA: confira o SQL antes de decidir. Os números de hoje são da fotografia de 16/10/2026.
      </p>
    </div>
  );
}
