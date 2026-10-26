# JPT AI para KOReader — especificação funcional e regras

Data de referência: 27 de outubro de 2026.

Este documento descreve o comportamento implementado em `main.lua` e
`context_policy.lua`, incluindo as alterações de contexto e de apresentação
durante a receção da resposta. Serve de referência para desenvolvimento,
manutenção e validação. Os nomes dos controlos mantêm a grafia da interface.

## 1. Objetivo

Permitir consultar um modelo de IA sobre texto selecionado, páginas, um capítulo
ou o livro completo, sem sair do KOReader. O utilizador escolhe o conteúdo sobre
o qual pretende uma resposta e, opcionalmente, texto de apoio para o interpretar.

O plugin exige um livro aberto, acesso à rede e um endpoint compatível com
chat completions. O texto disponível depende da extração oferecida pelo KOReader;
o plugin não implementa OCR próprio.

## 2. Abertura e composição da pergunta

| Entrada | Comportamento |
| --- | --- |
| Menu → JPT AI → Ask (last settings) | Abre com as preferências guardadas. |
| Gesto Open JPT AI | Abre com as preferências guardadas e eventual seleção. |
| Seleção de palavra ou passagem | Abre diretamente o compositor JPT AI, substituindo a abertura habitual do menu de seleção/dicionário nesse fluxo. |
| Botão JPT AI no dicionário | Abre o compositor com a palavra consultada. |
| Presets minimum, medium e maximum | Escolhem um âmbito primário temporário; ver secção 7. |

O compositor abre compacto, com os quatro botões de ação, os controlos dos
contextos, Options, Close e Write question. Write question expande a área de
escrita e apresenta o teclado e o botão Ask.

Com texto selecionado, a seleção é pré-preenchida no campo de escrita. Numa
pergunta livre, esse prefixo é retirado da instrução enviada ao modelo quando
permanece no início do campo: a seleção já segue como contexto principal.
Uma pergunta vazia, ou composta apenas pela seleção e espaços, não é enviada.

Alterar contextos e abrir opções preserva o rascunho e a posição do cursor nos
fluxos previstos pelo compositor.

## 3. Separação dos contextos

| Conceito | Regra |
| --- | --- |
| Main context / Primary context | Conteúdo sobre o qual o modelo deve traduzir, resumir, explicar ou responder. |
| Secondary context | Texto de apoio para interpretar o conteúdo principal. É opcional. |

Todas as consultas instruem o modelo a basear a resposta no contexto fornecido,
a atuar sobre o Main context e a usar o Secondary context apenas como apoio.
Estas são instruções ao modelo; não constituem garantia de correção da resposta.

Não se acrescenta automaticamente texto do livro fora do âmbito escolhido.
Os contextos podem sobrepor-se: por exemplo, a seleção e a página que a contém.
Não há remoção automática dessa sobreposição.

## 4. Contexto primário

### 4.1. Com texto selecionado

MAIN CONTEXT apresenta Selected text como estado fixo. A seleção é o conteúdo
principal; os controlos Pages, Chapter e Book não são apresentados nessa linha.

### 4.2. Sem texto selecionado

| Controlo | Conteúdo |
| --- | --- |
| Pages (n) | Um total ímpar de páginas centrado na página atual. |
| Chapter | O capítulo atual, identificado pelo índice do livro. |
| Book | O livro completo extraível pelo KOReader. |

Regras de Pages (n):

- Valores: 1, 3, 5, …, 21.
- Inclui sempre a página atual.
- Para `n = 5`, inclui duas páginas anteriores, a atual e duas seguintes.
- Não tem o checkbox Only previous pages.
- O intervalo é limitado pelo início e pelo fim do livro, sem compensação no
  lado oposto; pode conter menos páginas do que o valor escolhido.
- Na normalização, valores pares descem para o ímpar anterior e os valores
  ficam limitados a 1–21.

Se o capítulo não puder ser identificado, o plugin apresenta um erro e pede
outro âmbito; não substitui silenciosamente o capítulo pelo livro completo.

## 5. Contexto secundário

A linha SECONDARY CONTEXT tem os mesmos quatro controlos com e sem seleção:

| Controlo | Conteúdo |
| --- | --- |
| None | Não envia texto secundário. |
| Pages (n) | Envia um intervalo que inclui a página atual. |
| Chapter | Envia o capítulo atual como apoio. |
| Book | Envia o livro completo como apoio. |

O antigo botão Page foi removido. A opção equivalente é Pages (1).

### 5.1. Contagem de páginas

- O seletor oferece 1, 2, 4, 8, 16, 32, 64, 128, …, até `2^52`.
- O valor é o total pretendido, incluindo a página atual.
- Não existe um limite de interface em 32 páginas.
- A extração termina nos limites do livro; não se desloca o intervalo para
  compensar páginas em falta.
- Valores antigos fora da sequência são arredondados para a potência de dois
  seguinte, dentro dos limites do seletor.

### 5.2. Checkbox Only previous pages

| Estado | Regra |
| --- | --- |
| Marcado | Página atual e até `n − 1` páginas anteriores; nenhuma seguinte. |
| Desmarcado | Páginas dos dois lados: `floor(n / 2)` anteriores e `n − floor(n / 2) − 1` seguintes. |

Exemplos para a página atual 245:

| Contagem | Checkbox | Intervalo |
| --- | --- | --- |
| 1 | Qualquer | 245 |
| 4 | Marcado | 242–245 |
| 4 | Desmarcado | 243–246 |
| 32 | Marcado | 214–245 |

O checkbox é partilhado entre consultas com e sem seleção. A contagem de páginas
e o tipo de contexto secundário são guardados separadamente para esses dois casos.

Ao tocar em Pages (n), esse tipo de contexto fica imediatamente selecionado.
Fechar o seletor sem aplicar mantém essa escolha, mas não aplica alterações
pendentes à contagem ou ao checkbox. Apply guarda a contagem e o checkbox.

O texto de ajuda do seletor deve ser genérico: indica que a contagem inclui
a página atual, sem enumerar valores nem explicar o checkbox nesse texto.

### 5.3. Apresentação do intervalo

O cabeçalho identifica a página atual dentro do intervalo e omite Nearby pages:

```text
Secondary context: 214 - 245 (current page)
Secondary context: 243 - 245 (current page) - 247
Secondary context: 245 (current page) - 248
Secondary context: 245 (current page)
```

Os exemplos ilustram o formato; os extremos reais resultam da contagem escolhida
e dos limites do livro. A página atual não deve aparecer duplicada no intervalo.
O formato é usado tanto no contexto enviado como no cabeçalho apresentado.

## 6. Ações rápidas e perguntas livres

| Botão | Instrução funcional |
| --- | --- |
| Translate | Traduzir o Main context para a língua configurada, preservando significado e tom. Usar o secundário para resolver ambiguidades, sem o traduzir. |
| Summarize | Resumir o Main context, preservando ideias principais e detalhes relevantes. |
| Explain | Explicar o Main context com clareza, recorrendo ao apoio e a exemplos quando úteis. |
| Meaning | Explicar o significado contextual da palavra ou expressão e dar exemplos com o mesmo sentido. |

As instruções detalhadas são enviadas ao modelo. A interface identifica a ação
e o alvo, por exemplo `Translate: <texto selecionado>` ou
`Explain: current chapter (<capítulo>)`.

Não existe uma ação selecionada persistente: cada toque executa a ação
correspondente. As quatro ações partilham as preferências dos contextos.
Não existe um contexto primário/secundário próprio para cada botão.

Perguntas livres usam o texto introduzido. A instrução geral pede resposta na
mesma língua da pergunta; Translate inclui explicitamente a língua de destino.

## 7. Presets do menu

| Preset | Âmbito primário sem seleção |
| --- | --- |
| minimum | Página atual: 1 página. |
| medium | 3 páginas centradas na atual. |
| maximum | Livro completo. |

Com seleção, o conteúdo principal continua a ser o texto selecionado.
Os presets não gravam por si as preferências primárias.

**Particularidade da implementação atual:** o compositor dá prioridade ao
contexto secundário passado explicitamente e depois à preferência secundária
guardada. Só depois considera o secundário definido pelo preset. Como a
preferência guardada tem sempre um valor, incluindo None, na abertura habitual
prevalece essa preferência. Não se deve assumir que minimum desativa o secundário
ou que maximum seleciona Book no secundário.

## 8. Comprimento das respostas

| Opção | Instrução de detalhe | Limite de saída da opção |
| --- | --- | --- |
| Short | Parágrafo curto ou lista compacta. | 1 024 tokens |
| Medium | Resposta desenvolvida com detalhes relevantes. | 2 500 tokens |
| Long | Resposta detalhada, com raciocínio e exemplos quando adequados. | 7 500 tokens |
| Very long | Resposta muito detalhada, abrangendo nuances e exemplos. | 12 000 tokens |

O limite efetivo enviado é o menor entre o limite da opção e
`max_output_tokens` da configuração. Estes valores são limites de tokens,
não metas de palavras nem garantias de comprimento.

### 8.1. Memória por ação

1. O utilizador escolhe Response length nas opções.
2. A escolha fica pendente para a próxima submissão.
3. Se a próxima submissão for Translate, Summarize, Explain ou Meaning, essa
   ação guarda o novo comprimento; as restantes mantêm os seus valores.
4. Sem nova escolha pendente, cada ação usa o seu comprimento guardado.
5. Uma pergunta livre consome a escolha pendente, mas não altera os valores
   guardados das quatro ações.

Exemplo: escolher Short e executar Translate guarda Short para Translate;
escolher Long e executar Explain guarda Long para Explain. Translate continua
a usar Short depois de reiniciar o KOReader.

As opções apresentam o comprimento global/corrente, não uma grelha com os quatro
valores guardados. Executar uma ação atualiza esse valor corrente em memória.
A escolha pendente não sobrevive a um reinício; o comprimento global escolhido
é persistido quando se altera a opção.

## 9. Preferências e migração

As preferências são guardadas em `jpt_ai.lua` na pasta de definições do KOReader.
Na instalação Android usada neste projeto: `/sdcard/koreader/settings/jpt_ai.lua`.
São preferências do plugin, não configurações separadas por livro.

| Chave | Significado / valor inicial sem preferências anteriores |
| --- | --- |
| `primary_context` | Tipo primário; `pages`. |
| `primary_page_count` | Contagem primária; 1. |
| `secondary_context` | Tipo secundário sem seleção; `chapter`. |
| `secondary_page_count` | Contagem secundária sem seleção; 4 após conversão do raio inicial. |
| `selection_secondary_context` | Tipo secundário com seleção; `none`. |
| `selection_secondary_page_count` | Contagem secundária com seleção; 4 após conversão do raio inicial. |
| `secondary_only_previous_pages` | Checkbox partilhado; falso, salvo migração. |
| `response_length` | Comprimento global; `medium`. |
| `action_response_lengths` | Comprimento individual de `translate`, `summarize`, `explain` e `meaning`. |
| `translation_language` | Língua de tradução; `Portuguese (Portugal)`. |
| `font_multiplier` | Multiplicador da fonte; 1,0. |

Regras de compatibilidade:

- Raios secundários antigos são convertidos para totais `2 × raio + 1`,
  arredondados para a potência de dois seguinte.
- O antigo contexto de seleção `current_page` passa a `nearby_pages` com
  contagem 1; a escolha equivalente aparece como Pages (1).
- Na ausência da nova chave do checkbox, recupera-se a antiga
  `primary_only_previous_pages`; o primário deixa de a utilizar.
- Comprimentos por ação ausentes ou inválidos são inicializados com o
  comprimento global válido. Um comprimento global inválido passa a Medium.
- Chaves antigas de raio podem continuar no ficheiro para compatibilidade;
  os seletores atuais usam as contagens novas.

## 10. Envio, receção e navegação

### 10.1. Pedido ao modelo

O plugin envia um POST ao endpoint configurado, com autenticação Bearer e corpo
JSON contendo modelo, temperatura, limite de saída, esforço de raciocínio e
mensagens system/user. O contexto é texto extraído pelo KOReader, normalizado
quanto a quebras de linha e espaços.

O pedido corre num processo de trabalho separado para manter a interface
responsiva. O KOReader evita entrar em standby enquanto o pedido está ativo
e liberta esse bloqueio no fim ou no cancelamento.

### 10.2. Progresso e streaming

- Mostra espera/receção e tempo decorrido.
- Processa conteúdo incremental de eventos SSE quando o serviço o fornece.
- Atualiza a apresentação em lotes: nunca mais de uma vez por segundo; pode
  atualizar após cerca de 300 bytes adicionais ou ao fim de cinco segundos.
- Cancel request fecha a espera e termina o processo de trabalho.
- Se o serviço rejeitar streaming com HTTP 400/422 e a resposta mencionar
  `stream`, tenta uma única vez sem streaming.
- O tempo total continua sujeito ao mesmo limite, incluindo a segunda tentativa.
- Erros comuns de autenticação, rede, TLS, limite, serviço e tempo são
  apresentados com explicação e informação original disponível.

### 10.3. Posição da janela de resposta

**Cada atualização do conteúdo mantém a janela na página 1.** Não deve seguir
automaticamente a última página quando a resposta cresce. A resposta final
abre igualmente no início.

Esta regra aplica-se à paginação da janela de resposta, não à página de leitura
do livro. Se o utilizador navegar durante a receção, a atualização seguinte
volta à página 1. Depois de concluída a resposta, pode navegar normalmente.

### 10.4. Formatação e continuação

As respostas são apresentadas como Markdown convertido para HTML, incluindo
tratamento de tabelas. Se a conversão falhar, usa-se texto escapado. O tamanho
da fonte parte do livro e recebe o multiplicador configurado (0,1× a 2,0×).

| Botão na resposta concluída | Comportamento |
| --- | --- |
| Back | Reabre o compositor e recupera a seleção original quando aplicável. |
| Continue | Reabre o compositor para nova pergunta com a transcrição anterior como histórico. A seleção original deixa de ser o alvo ativo. |
| Close | Fecha a janela. |

O histórico de conversa é mantido em memória nesse fluxo; não há arquivo
persistente de conversas implementado. As preferências guardadas não equivalem
a histórico de perguntas/respostas.

## 11. Configuração, limites e dados enviados

O ficheiro privado `jpt_ai_config.lua` contém os parâmetros do serviço.
O modelo público é `jpt_ai_config.example.lua`.

| Parâmetro | Regra / valor de referência |
| --- | --- |
| `base_url` | URL completa do endpoint de chat completions. |
| `api_key` | Credencial de autenticação do serviço. |
| `model` | Identificador do modelo enviado ao serviço. |
| `temperature` | 0,2 quando ausente. |
| `max_output_tokens` | 12 000 quando ausente; combinado com o limite do comprimento escolhido. |
| `request_timeout` | 180 segundos quando ausente; limitado pelo código a 20–600 segundos. |
| `context_warning_tokens` | 24 000 quando ausente; mínimo 1. |
| `reasoning_effort` | `low` quando ausente. |

A estimativa de dimensão é `ceil(bytes / 3)` para o material estimado do pedido.
Não é uma contagem pelo tokenizer do modelo. Acima do limiar, pede confirmação
com Send anyway ou Review context. Aceitar envia o contexto completo; não há
truncagem automática para respeitar a janela do modelo.

Seleção, contexto escolhido, pergunta e eventual histórico são enviados ao
serviço configurado. Esse serviço pode ser local ou remoto conforme a URL.
As políticas de retenção do serviço estão fora do controlo do plugin.
O ficheiro privado de configuração está excluído do Git e não deve ser incluído
em commits, exemplos ou documentação com credenciais reais.

## 12. Organização e validação

| Ficheiro | Responsabilidade |
| --- | --- |
| `main.lua` | Integração com KOReader, interface, preferências, pedidos e apresentação. |
| `context_policy.lua` | Contagens, intervalos, presets, extração auxiliar, composição e classificação de erros. |
| `_meta.lua` | Metadados do plugin. |
| `jpt_ai_config.example.lua` | Exemplo de configuração sem credenciais reais. |
| `tests/test_context_policy.lua` | Intervalos, contagens, presets, extração e categorias de erro. |
| `tests/test_response_lengths.lua` | Preferências por ação, callbacks dos seletores, migração, cabeçalhos e recarregamento com stubs do KOReader. |

Executar a partir da pasta do plugin:

```sh
luajit tests/test_context_policy.lua
luajit tests/test_response_lengths.lua
git diff --check
```

Critérios de aceitação para alterações nestas funcionalidades:

1. Primário com contagens ímpares 1–21, centrado e sem checkbox.
2. Secundário com None, Pages (n), Chapter e Book; Pages (1) substitui Page.
3. Checkbox e contagens persistem com as separações descritas neste documento.
4. Intervalos não ultrapassam o livro e identificam a página atual no cabeçalho.
5. Alterar o comprimento de uma ação não altera os das outras três.
6. A receção de uma resposta longa mantém a janela na primeira página.
7. Cancelar termina o trabalho e liberta os recursos do pedido.
8. Credenciais e estado privado ficam fora dos commits.

Testes com stubs validam lógica e callbacks, mas não substituem a interação real
no leitor. Na instalação, fazer backup do plugin e preferências, copiar os
ficheiros alterados, verificar os hashes e reiniciar KOReader. A correspondência
de hashes comprova a instalação; a apresentação e navegação exigem confirmação
no dispositivo.

## 13. Manutenção desta especificação

Qualquer alteração aos controlos, regras de intervalo, preferências, limites,
formato dos cabeçalhos ou comportamento de navegação deve atualizar este
documento e as secções correspondentes do README. Particularidades da
implementação devem ser identificadas explicitamente, sem as apresentar como
funcionalidades já corrigidas ou validadas no dispositivo.
