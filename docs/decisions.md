# Architectural Decision Records (ADRs)

Este documento registra as decisões arquiteturais estruturais tomadas durante o desenvolvimento do compilador Aether.

## ADR 01: C Transpiler Backend para Desenvolvimento (`run`)
**Data:** Fase 02
**Contexto:** Precisávamos de uma forma rápida de iterar e testar código Aether sem a complexidade de compilar LLVM IR em tempo de desenvolvimento.
**Decisão:** O comando `aether run` atua como um Transpilador puro, gerando código C intermediário e invocando `zig cc -O0`.
**Razão:** O C age como uma "Assembly de alto nível". É incrivelmente portável, extremamente otimizado e drásticamente mais fácil de debugar. Isso garante compilações sub-segundo no ciclo de feedback do dev.

## ADR 02: Operator Overloading via Modifiers
**Data:** Fase 11 e 12
**Contexto:** Queríamos permitir a sobrecarga de operadores matemáticos (`+`, `-`) em classes personalizadas (ex: `Vector`).
**Decisão:** O Aether adota uma abordagem estrita baseada em Kotlin. Para sobrecarregar um operador, o método deve ter um nome de contrato exato (ex: `plus`) e **obrigatoriamente** possuir o modificador `operator`.
**Razão:** Evita sobrecargas acidentais de funções comuns chamadas "plus". Traz clareza semântica: ao ler a classe, você sabe imediatamente que aquela função altera o comportamento matemático da linguagem.

## ADR 03: Null Safety as Compile-Time Union Types
**Data:** Fase 13
**Contexto:** C (o nosso alvo de transpilação) é notório por Segmentation Faults causados por ponteiros nulos. Precisávamos de um mecanismo para blindar isso.
**Decisão:** Implementar *Null Safety* rigoroso no TypeChecker. Tipos com `?` (ex: `String?`) são internamente tratados como *Union Types* (`.String | .Null`). O compilador bloqueia *hard* o acesso de propriedades ou métodos nesses tipos, exigindo o uso de operadores seguros (`?.`, `?:` ou `!!`).
**Razão:** Prevenção total de SegFaults por Null Pointers. O Transpilador emite macros ternárias em C que verificam a nulidade antes do acesso, garantindo a segurança de memória em tempo de execução ditada estaticamente.

## ADR 04: Memory Management via Boehm GC
**Data:** Fase 14 (Aprovado, Implementação Pendente)
**Contexto:** O Aether gera código C que usa `malloc` extensivamente para construir strings nativas e instanciar classes. No entanto, não geramos chamadas `free()`, causando vazamentos crônicos de memória (*Memory Leaks*).
**Decisão:** Em vez de poluir o código C final com milhares de rotinas de *Reference Counting* injetadas pelo TypeChecker, adotaremos a integração com o **Boehm-Demers-Weiser Conservative Garbage Collector** (Mesma arquitetura do compilador Crystal).
**Razão:** Máximo pragmatismo. Apenas trocamos `malloc` por `GC_MALLOC` no emissor C e linkamos a biblioteca `-lgc`. O coletor de lixo atua perfeitamente em background com impacto estrutural quase zero na arquitetura do nosso AST/TypeChecker.

## ADR 05: LLVM Native Emitter para Produção (`build --release`)
**Data:** Concepção Original da Spec
**Contexto:** Enquanto o C Transpiler é rápido para desenvolver, precisamos de otimizações de ponta para binários de produção sem a sobrecarga de macros pesadas ou dependências externas difíceis de controlar.
**Decisão:** O comando `aether build --release` desviará do backend C e invocará um emissor focado em **LLVM IR**. Usaremos as APIs/Bindings do LLVM direto no Zig para traduzir a AST Resolvida para IR e deixar o LLVM otimizá-lo.
**Razão:** LLVM garante performance de estado da arte (comparável a C/C++ ou Rust). Uma linguagem moderna orientada a performance necessita dessa via direta para gerar binários monolíticos ultrarrápidos para servidores.

## ADR 06: File-based Namespaces e Native Test System
**Data:** Fase 16 e 21
**Contexto:** Queríamos evitar a complexidade do ecossistema de bibliotecas de teste (como JUnit ou vitest) e manter a filosofia minimalista e pragmática do Aether.
**Decisão:** Criar uma suite de testes de primeira classe nativa (`aether test`), aliada a um sistema de importação baseado puramente em arquivos (ES6/Go style). O compilador condensa testes dinamicamente da árvore de arquivos e resolve o name mangling dos módulos C para evitar colisões entre as suítes, abstraindo e ignorando automaticamente as funções `main` de desenvolvimento da compilação de testes. As extensões `.ae` nos imports se tornam opcionais.
**Razão:** Máxima fluidez para o desenvolvedor. Testes integrados desde a linguagem base elevam a qualidade do código criado no ecossistema Aether sem nenhum tipo de boilerplate ou configuração de build necessária.

## ADR 07: Top-Level Statements (Fim da obrigatoriedade do `main`)
**Data:** Fase 22
**Contexto:** O Aether utilizava `fun main()` obrigatoriamente como ponto de entrada por herança estrita do C. Contudo, isso gerava um *boilerplate* indesejado para o desenvolvedor durante a criação de scripts rápidos ou arquivos leves, indo contra a filosofia dinâmica do comando `aether run`.
**Decisão:** Adotar a **Abordagem Híbrida** para a inicialização do programa (semelhante ao C# 9+). O desenvolvedor não precisa mais de `fun main()`. Instruções soltas (ex: `print("Hello")`) escritas na raiz do arquivo compilado serão agrupadas silenciosamente pelo compilador e injetadas dentro do `main` nativo em C. Se o desenvolvedor optar por criar um `fun main()` explicitamente, o compilador o respeitará. Argumentos de CLI e saídas de erro serão tratados com uma variável global injetada `args` e uma função de sistema `exit(code)`.
**Razão:** Entrega o melhor dos dois mundos. Scripting ultrarrápido com poucas linhas para ferramentas simples, e o padrão estrutural coeso e robusto do `main` tradicional para aplicações grandes e complexas em produção.

## ADR 08: Interoperabilidade Nativa C e C-Macros via Tipo `Unknown`
**Data:** Fase 17
**Contexto:** Ao construir a linguagem Aether (focada em extrema performance e baixo nível), integrá-la sem atritos ao ecossistema C é essencial. Além disso, as funções intrínsecas (como `print`) estavam engessadas diretamente no TypeChecker do compilador. Precisávamos da fundação para a primeira "Standard Library" (`core.ae`).
**Decisão:** Introduzir o bloco `lib` para declarar *bindings* de C, combinado com **Anotações Estruturais** (`@Header`) consumidas pelo CTranspiler para ejetar as diretivas `#include`. Para manter a flexibilidade de C macros (como a nossa macro C interna `_Generic` do `print`, que aceita Int, String, Bool), implementamos um tipo mágico `Unknown` em Aether que burla temporariamente o TypeChecker para aqueles parâmetros específicos. (Nota: Substituído parcialmente pelo ADR 09).
**Razão:** Remove a complexidade do compilador, isola as definições base da linguagem em código "user-space" (o arquivo `core.ae` usa `lib System` para injetar `print`), e permite que a própria Stdlib do Aether usufrua de ponteiros C diretos no transpilador com total zero-overhead. Planejamos no futuro evoluir as anotações para o nível de linguagem estrita (Fase 24), mas esta base estrutural garante entregas de produto rápidas na iteração atual.

## ADR 09: Function Overloading e Implicit Standard Library
**Data:** Fase 23
**Contexto:** O uso da macro `_Generic` em C e o tipo mágico `Unknown` eram gambiarras arquiteturais instáveis e difíceis de manter. Além disso, os desenvolvedores precisavam importar explicitamente funções essenciais (ex: `import { print } from "system"`) em todos os arquivos.
**Decisão:** 
1. Implementar **Function Overloading** nativo no TypeChecker, permitindo múltiplas assinaturas para a mesma função (ex: `print(String)`, `print(Int)`), com **Name Mangling** dinâmico (ex: `system_print_String`) na emissão C para evitar colisões. O tipo `Unknown` perde sua obrigatoriedade como muleta arquitetural.
2. Implementar **Wildcard Imports** (`import *`) na camada semântica e injetar uma importação implícita (`import {} from "system"`) no início de todo arquivo compilado.
**Razão:** Traz robustez absurda para o sistema de tipos (verificando os tipos de funções no *compile-time* em vez de falhar no GCC) e melhora massivamente a ergonomia (*Developer Experience*) ao fornecer as APIs de sistema automaticamente de forma transparente.

## ADR 10: Arrays Nativos Estritamente Imutáveis
**Data:** Fase 24 (Início)
**Contexto:** Ao desenhar o suporte nativo para arrays dinâmicos (`[Type]`), questionamos se o Aether deveria permitir métodos de mutação (ex: `.push()`, `.pop()`) vinculados a `val`/`var` (Estilo Rust/Swift) ou criar tipos explícitos distintos (Estilo Kotlin).
**Decisão:** O tipo nativo `[Type]` é **estritamente imutável** do ponto de vista do TypeChecker do Aether e atua puramente como um "Syntactic Sugar" para `List<Type>`. Modificações requerem estruturas de dados explícitas separadas no futuro (ex: `MutableList<Type>`).
**Razão:** Máxima aderência à filosofia de segurança de tipos do Kotlin. Garante previsibilidade (um array recebido por função nunca terá seu tamanho/dados alterados acidentalmente). Embora internamente o C Transpiler gere *structs* C dinâmicos capazes de crescer, o compilador restringe essa capacidade estaticamente no nível da linguagem.

## ADR 11: Standard Library Packages e Epoch-First Time API
**Data:** Fase 26
**Contexto:** O arquivo `system.ae` estava crescendo descontroladamente, agindo como um monólito ("God File"). Além disso, precisávamos adicionar suporte a manipulação de Datas/Tempos, uma área historicamente propensa a bugs (timezones, daylight savings) em linguagens antigas.
**Decisão:** 
1. **Pacotes Virtuais:** O TypeChecker agora intercepta pacotes que começam com `std.` (ex: `std.time`) e roteia a busca diretamente para a pasta interna `std/` do compilador, ao invés de usar caminhos relativos ao projeto do usuário. O antigo `system.ae` se tornou `std.core` (`std/core.ae`).
2. **Epoch-First Time API:** Escolhemos o modelo do **Go** para a classe `Time`. Ela possui apenas uma propriedade (`val sec: Int`) que guarda os segundos absolutos (Unix Epoch `time_t`). Operações matemáticas (como somar horas usando a classe `Duration`) são processadas como somas de inteiros ultra-rápidas. Formatações e consultas baseadas em fuso horário (ex: Extrair Ano, Mês, Dia) são delegadas ao `<time.h>` no frontend C através do novo bloco nativo `lib NativeTime`. 
**Razão:** A quebra em pacotes `std.*` oficializa a Standard Library modular, blindando a SDK do Aether. A arquitetura Epoch-First garante que não haverão bugs de Fuso Horário na memória central das aplicações, aliada a uma performance monstruosa na CPU para matemática de tempo (apenas somas de bits) essencial para desenvolvimento de alto rendimento.

## ADR 12: Single-Pass Type Inference via Early Returns
**Data:** Refinamento Fase 26 / Bugfixes (Julho 2026)
**Contexto:** Ao suportar a inferência de blocos complexos, retornos condicionais e construtores nativos, o compilador enfrentou um bug grave: nós isolados (como *string literals*) passavam pela esteira do `TypeChecker` múltiplas vezes em avaliações de blocos sobrepostos. Isso causava mutações recursivas na AST gerando código corrompido no backend C, como `core_String_new(core_String_new(...))`, culminando em *Segmentation Faults*.
**Decisão:** O núcleo do `TypeChecker` (`core_inferNode`) implementa uma blindagem de **Early Return**. Qualquer nó da AST que já possua o `resolved_type` preenchido por uma visita anterior é devolvido imediatamente, prevenindo a re-varredura.
**Razão:** Elimina mutações duplas acidentais nos nós da AST e melhora radicalmente a estabilidade e performance do compilador, assegurando que o TypeChecker atue estruturalmente como um varredor O(N) (*Single-Pass*) puro na árvore.

## ADR 13: C-Style Prefix Unary Operators Integration
**Data:** Fase 27
**Contexto:** O compilador precisava de suporte nativo a operadores unários lógicos (`!condicao`) e matemáticos (`-10`). O desafio era gerir corretamente a ordem matemática sem conflitar com operadores de segurança *postfix*, como a asserção non-null (`!!`).
**Decisão:** A leitura dos unários (`unary()`) foi inserida estritamente na árvore do *Recursive Descent Parser* após `factor()` (* /) e antes de `call()`. Os tokens `.bang` (`!`) e `.minus` (`-`) foram modelados com suporte a empilhamento de múltiplas *Unary Expressions*.
**Razão:** Seguir a especificação sólida das linguagens da família C (Kotlin, Swift), permitindo o agrupamento seguro dessas expressões na emissão final (ex: gerando `!(cond)` no transpiler) e tipagem granular independente e blindada para cada operador.

## ADR 14: Representação Estruturada de Tipos na AST (ASTTypeRef)
**Data:** Fase 28
**Contexto:** O compilador representava tipos no AST utilizando strings cruas formatadas (ex: `"List<Int>"` ou `"[Int]"`). Essa abordagem exigia análises de strings complexas, lentas e propensas a falhas (usando `startsWith`, `indexOf` ou `split`) sempre que o `TypeChecker` precisava resolver tipos, tratar tipos opcionais (`Opt` / `?`) ou realizar monomorfização de classes genéricas.
**Decisão:** Substituir a representação de tipo baseada em strings por um modelo estruturado chamado `ASTTypeRef`, composto por campos explícitos (`name`, `generic_args`, `is_array`, `is_nullable`). O parser passa a instanciar e propagar essa estrutura recursiva a partir das anotações de tipo. O `TypeChecker` agora resolve os tipos semanticamente utilizando barramentos estruturais, e as substituições genéricas operam diretamente por clonagem da árvore `ASTTypeRef`.
**Razão:** Traz robustez extrema para o sistema de tipos. Elimina a necessidade de parsing de strings "ad-hoc" no verificador semântico e resolve de forma elegante e escalável a manipulação de classes genéricas com qualquer número de parâmetros (não mais limitados a 1 ou 2 argumentos genéricos). As otimizações de compatibilidade com os nomes de arquivos mangled (como `Opt` e `?`) foram mapeadas perfeitamente para manter a integridade total do backend.

## ADR 15: Herança de Classe por Embutimento de Structs e Ponteiros de Função
**Data:** Fase 30
**Contexto:** O Aether necessita de suporte a herança de classes para permitir polimorfismo dinâmico e implementar o tratamento estruturado de Exceções (Phase 19). Precisamos de uma arquitetura que ofereça polimorfismo mantendo a performance de uma linguagem nativa compilada e que se adapte de forma direta tanto no C Transpiler quanto no futuro LLVM Backend.
**Decisão:** Adotar herança de classe única baseada em embutimento de structs em C (onde a struct da classe pai é o primeiro campo da struct da classe filha) combinado com despacho dinâmico via ponteiros de função embutidos na struct. Toda classe marcada como `open` ou que possui herança terá seus ponteiros de métodos dinâmicos instanciados nas structs e remapeados nos construtores das subclasses.
**Razão:** Permite polimorfismo dinâmico e reutilização de estado sem a necessidade de tabelas de métodos virtuais (VTables) globais complexas no compilador. A herança por embutimento garante que a conversão de ponteiros (upcasting) no backend C e LLVM IR seja gratuita (offset zero). Os ponteiros de função na struct facilitam o despacho dinâmico direto em C (`obj->speak_ptr(obj)`) e LLVM IR (`indirect call`), e permitem otimizações nativas de devirtualização pelo compilador LLVM.

## ADR 16: Exception Handling via local setjmp/longjmp Stack Unwinding
**Data:** Fase 19
**Contexto:** Queríamos implementar o tratamento estruturado de exceções (`try-catch`), com suporte a multi-catch e captura genérica de erros, gerando código que mapeie eficientemente para C e que seja compatível com a infraestrutura futura de `landingpad`/`invoke` do LLVM IR.
**Decisão:** Adotar um modelo de desenrolamento de pilha não-local baseado na biblioteca padrão `<setjmp.h>`.
1. Cada bloco `try` gera um frame de exceção local empilhado em uma pilha thread-local (`aether_exception_stack`), capturando o ponto de retorno via `setjmp`.
2. Lançamentos de erros (`throw`) armazenam a exceção ativa em uma variável thread-local e saltam para o frame ativo via `longjmp`.
3. Os catches são resolvidos por ordem de declaração usando RTTI dinâmico em runtime (`aether_is_instance`). Se nenhum capturar, ocorre rethrow automático. O tipo estático da variável capturada no multi-catch é a classe base `Exception`.
4. Opcionalmente suportar blocos `catch` anônimos sem assinatura (`catch { ... }`) que capturam qualquer erro de forma silenciosa.
**Razão:** O uso de `setjmp`/`longjmp` simula a nível de C o comportamento de tabelas de saltos não-locais de exceções tradicionais. Esse modelo mapeia-se de forma direta para a instrução nativa `invoke` e blocos de `landingpad` no backend LLVM IR futuro, fornecendo no futuro tratamento de custo zero (Zero-Cost Exception) sem comprometer o fluxo lógico de C do transpiler atual.

## ADR 17: Operadores Ternário e Ternário Curto
**Data:** Fase 18
**Contexto:** O Aether não possuía o operador condicional ternário (`? :`), exigindo o uso de blocos `if-else` mais verbosos. Além disso, queríamos suportar um operador ternário curto (`condicao ? valor`) que retorna `null` implicitamente quando a condição é falsa.
**Decisão:**
1. **Precedência e Associatividade:** O operador ternário terá precedência logo abaixo do operador Elvis (`?:`) e acima do de atribuição (`=`), associando à direita (permitindo ternários aninhados sem parênteses, ex: `a ? b : c ? d : e` avalia como `a ? b : (c ? d : e)`).
2. **Tipo de Retorno (Ternário Curto):** O tipo retornado pelo ternário curto `a ? b` é uma união entre o tipo de `b` e `Null` (ex: `Type?`). Para evitar tipos opcionais aninhados redundantes (ex: `String??`), achatamos o tipo de retorno se `b` já for anulável. Expressões do tipo `Void` são proibidas como branch positiva.
3. **Transpilação para C:** Para o ternário padrão, geramos `((cond) ? (then) : (else))`. Para o ternário curto, como o C não o suporta nativamente, transpilamos como `((cond) ? (then) : 0)`.
**Razão:** Traz mais concisão e expressividade à linguagem, seguindo o pragmatismo e a simplicidade da transpilação direta para C, com checagem estática rigorosa de nulidade no TypeChecker.

## ADR 18: Pattern Matching e Expressões when
**Data:** Fase 32
**Contexto:** O compilador Aether precisava de uma forma expressiva de controle de fluxo condicional baseado em valores e tipos, para substituir cadeias longas de `if-else` e dar suporte a smart casting elegante.
**Decisão:** Adotar a expressão `when` (estilo Kotlin). A expressão `when` pode ter um assunto (`when (x)`) ou não. Suportará condições baseadas em valores literais, expressões gerais ou testes de tipo (`is Type` / `!is Type`). Cada caso é separado de seu corpo usando o operador `->`. Para transpilação, geramos uma cadeia de `if-else` em C embutida em uma Expressão de Bloco de Instruções do GCC (`({ ... })`).
Se o `when` retornar um valor não-Void, o compilador exige a presença de um ramo `else` para garantir a exaustividade (checagem de tipos rigorosa). Além disso, se o assunto for um identificador (variável estável) e houver uma única checagem de tipo `is Type` (sem negação `is_not == false`), o compilador fará *smart cast* da variável dentro do escopo daquele ramo.
**Razão:** O uso da expressão de bloco C `({ ... })` permite que `when` funcione tanto como expressão quanto instrução de forma uniforme em C, sem a limitação de switch-cases de C (que só suportam inteiros constantes). O *smart casting* melhora radicalmente a ergonomia de checagem de tipos polimórficos estabelecida no ADR 15.

## ADR 19: Standard Library HTTP e Networking via FFI e Evolução de Loop de Eventos
**Data:** Fase 35 e 36
**Contexto:** Para criar frameworks web e bibliotecas de requisição no Aether, precisamos de uma API de HTTP client e HTTP server performática. Go e Crystal usam concorrência baseada em fibers/goroutines sobre loops de eventos, mas o Aether não possui scheduler cooperativo nem event loop integrado no runtime atualmente.
**Decisão:** Adotar uma abordagem híbrida evolutiva:
1. **Fase Inicial (Phase 35):** Implementar o cliente HTTP (`std.http.Client`) via FFI com a biblioteca C `libcurl`, e o servidor HTTP (`std.http.Server`) utilizando FFI com `libuv` (ou soquetes não-bloqueantes com wrappers leves em C compilados no runtime).
2. **Fase de Concorrência Avançada (Phase 36):** Projetar uma infraestrutura de Fibers cooperativas no C runtime e um loop de eventos centralizado baseado em `epoll`/`kqueue`/`libevent`. Reimplementar soquetes da standard library para suspender as fibers em caso de bloqueio de I/O, entregando concorrência de altíssima performance no nível de Go e Crystal.
**Razão:** A curto prazo, reutilizar `libcurl` e `libuv` através de FFI aproveita a performance máxima e maturidade dessas bibliotecas em C, minimizando o risco de falhas de segurança e reduzindo drasticamente o esforço de implementação. A longo prazo, a evolução para Fibers integradas e um loop de eventos central no runtime dará ao Aether a mesma ergonomia síncrona e escalabilidade em concorrência que Go e Crystal oferecem.

## ADR 20: Lambda Expressions & Higher-Order Functions (Lambdas e Funções de Alta Ordem)
**Data:** Fase 31
**Contexto:** Para suportar programação funcional, concorrência e expressividade no estilo Kotlin, o Aether necessita de suporte a lambdas (literais de função) e closures (funções que capturam variáveis de escopo léxico externo).
**Decisão:**
1. **Sintaxe e Parâmetros:** Seguir estritamente o estilo Kotlin. Se nenhum parâmetro for declarado explicitamente (ex: `{ it + 1 }`), uma variável implícita chamada `it` será automaticamente injetada pelo TypeChecker com o tipo correspondente do argumento esperado pelo contexto. Se parâmetros explícitos forem providos (ex: `{ x -> x + 1 }`), a variável `it` não será definida. Além disso, suportar a sintaxe de *Trailing Lambda* (Lambda Pendente), onde a lambda pode ser passada fora dos parênteses se for o último argumento de uma chamada de função (ex: `html { ... }` ou `foo(arg) { ... }`).
2. **Mecanismo de Captura (Closures):** Variáveis imutáveis (`val`) capturadas são passadas por cópia/valor diretamente para a estrutura de contexto da closure. Variáveis mutáveis (`var`) capturadas sofrerão *boxing* automático (alocadas no heap via Boehm GC como uma struct wrapper) para garantir consistência de leitura e escrita tanto no escopo externo quanto interno à lambda.
3. **Representação no C e LLVM Backend:** Usar o padrão de *Ponteiro Gordo* (Fat Pointer). Uma closure é representada em C e LLVM como uma struct com dois ponteiros: um ponteiro para a função real e um ponteiro genérico de contexto/ambiente (`void* env`). A assinatura da função gerada sempre terá o ponteiro do ambiente (`env`) como primeiro argumento. A chamada é transpilada uniformemente como `closure.fn_ptr(closure.env, args...)`.
**Razão:** A sintaxe com `it` traz excelente ergonomia idêntica ao Kotlin. A representação de *Ponteiro Gordo* no backend C e LLVM IR é o padrão da indústria (Rust/Swift/Go), evitando poluição de código gerado e permitindo passagem uniforme de funções de primeira classe, garantindo a evolução do compilador para emissão de código nativo via LLVM sem grandes refatorações estruturais.

## ADR 21: Objects & Boundless Namespaces
**Data:** Fase 38
**Contexto:** O Aether precisava de suporte a membros estáticos (funções e variáveis associadas a uma classe/tipo, e não a instâncias específicas) para permitir fábricas de instanciação, constantes e namespaces limpos. Em vez de introduzir a palavra-chave `static` clássica do C++/Java, optou-se pela semântica de blocos de objeto associados (`object`).
**Decisão:**
1. Introduzir a palavra-chave `object` para declarar blocos estáticos nomeados (`object File { ... }`) ou anônimos (`object { ... }`).
2. Implementar binding restrito no Parser: a declaração de `object` anônimo deve ser na mesma linha do fechamento da classe como uma continuação (`} object {`). Da mesma forma, uma classe anônima seguindo um `object` nomeado deve continuar na mesma linha (`} class (...) {`). O Parser valida isso comparando o número da linha do token com a linha do último brace de fechamento (`}`). Se não estiverem na mesma linha, gera um erro de sintaxe.
3. Unificar os escopos no TypeChecker: o TypeChecker resolve membros estáticos buscando no bloco `object` associado (onde não há injeção de ponteiro implícito `this`), e membros de instância no bloco `class` correspondente (onde há injeção de `this`). Acesso estático ocorre via `Type.membro`.
4. Transpilação sem overhead: funções estáticas declaradas no `object` são compiladas diretamente como funções globais sem o argumento de ponteiro de instância (`this`). Variáveis estáticas no `object` tornam-se variáveis globais em C, com os nomes mangled adequadamente (`File_read`, `File_defaultPath`).
**Razão:** Mantém a simplicidade do modelo de transpilação sem introduzir modificadores redundantes de escopo (`static`) em cada campo. A exigência de mesma linha na continuação (`} object {`) reforça a integridade visual da declaração conjunta, tratando o bloco `object` como parte intrínseca do tipo.

## ADR 22: Standard Library Environment Configuration (`std.env`)
**Data:** Fase 39
**Contexto:** O Aether precisava de suporte a gerenciamento de variáveis de ambiente do processo e leitura de arquivos de configuração locais `.env` de forma limpa, tipada e resiliente.
**Decisão:**
1. Criar o módulo `std.env` expondo o objeto `Env` com suporte a `load()`, `get()`, `set()`, `unset()` e `exists()`.
2. Implementar FFI bindings eficientes para a biblioteca padrão do C (`getenv`, `setenv`, `unsetenv` e `atoi` do `<stdlib.h>`).
3. O método `Env.load(path)` fará checagem de legibilidade silenciosa do arquivo via FFI (tentando `fopen` no modo leitura) antes de processá-lo, retornando `false` sem emitir erros no stdout se o arquivo não existir.
4. O parseador de `.env` descartará linhas vazias e comentários iniciados por `#`, fará split no primeiro caractere `=`, aplicará trim de espaços/newlines nas chaves e valores, e removerá aspas externas simples (`'`) ou duplas (`"`) do valor.
5. Permitir conversão automática e segura para tipos em sobrecargas de `Env.get`:
   - `Env.get(key): String?` (retorna `null` se não existir).
   - `Env.get(key, default: String): String` (retorna o default se não existir).
   - `Env.get(key, default: Int): Int` (converte via `atoi` ou retorna default se não existir).
   - `Env.get(key, default: Bool): Bool` (valida valores truthy como `"true"`, `"1"`, `"yes"`, `"on"` ou retorna default se não existir).
6. Executar o auto-loading automático do `.env` na primeira chamada de leitura (`get`, `exists`) caso `Env.load()` não tenha sido invocado previamente.
**Razão:** Centraliza o acesso à configuração do processo sob uma única API consistente, facilitando inicialização de servidores e scripts que dependem de configurações dinâmicas de infraestrutura sem poluir a saída de erros na inicialização.

## ADR 23: Arquitetura de Compilador Multi-Pass (Kotlin/Crystal Style)
**Data:** Fase 40
**Contexto:** O compilador Aether operava por análise semântica e resolução de imports recursivas na mesma passagem (single-pass sob demanda). Essa estrutura gerava recursão infinita ou falha por falta de símbolos caso houvesse dependência circular entre classes/módulos do usuário (ex: Classe A referenciando Classe B e vice-versa), além de causar redundância na transpilação final em C.
**Decisão:** Refatorar o pipeline em três passes ordenados e centralizados sob um driver/orquestrador (Opção A):
1. **Parsing Pass:** Carrega e analisa recursivamente todos os arquivos a partir do ponto de entrada (incluindo implicit imports e explicit imports), armazenando as ASTs brutas em um registro global mapeado pelo caminho físico absoluto do arquivo.
2. **Declaration Pass:** Varre todas as ASTs cadastradas para registrar as assinaturas públicas de todos os tipos (classes, construtores, objetos, funções, bibliotecas FFI) nos respectivos escopos locais e globais, resolvendo namespaces e imports de assinaturas de forma estática sem validar corpos.
3. **Semantic Body Validation Pass:** Executa a validação semântica profunda e verificação de tipos de expressões, corpos de métodos/funções, inicializadores padrões e statements soltos em todos os arquivos no registro unificado.
Além disso, atualizar o `CTranspiler` para verificar se um arquivo físico (incluindo o core da stdlib) já foi transpiled através de um mapa de controle `emitted_modules`, garantindo deduplicação total de símbolos em C.
**Razão:** Permite dependências circulares de tipos completas no nível de linguagem de forma transparente, garante clareza de passes no compilador, elimina redundâncias no backend CTranspiler e fornece a base de dados ideal (ASTs pré-resolvidas de escopo) para a futura geração nativa de LLVM IR.

## ADR 24: Suporte a Escape de Aspas e Caracteres Especiais em Strings
**Data:** Fase de Estabilização (Julho 2026)
**Contexto:** O Aether não suportava escape de aspas em literais de String, o que impedia construções básicas como `"Ele disse \"Olá\""`. Qualquer aspa dupla `"` encontrada dentro de uma string fechava o literal prematuramente no Lexer.
**Decisão:**
1. **Tratamento no Lexer:** Modificar o analisador léxico (`lexer.zig`) no método `string` para ignorar aspas de fechamento se forem precedidas por um caractere de escape (barra invertida `\\`), e também consumir a própria sequência de escape (e o caractere seguinte) para permitir outros escapes padrão do Kotlin/C (como `\\`, `\n`, `\t`, `\r`, `\'`, `\b`).
2. **Cálculo de Tamanho no Type Checker:** Modificar a inferência de tipo de literais de string em `core.zig` para calcular o comprimento correto da string descontando os caracteres de barra invertida (`\\`) usados como escape. Isso garante que a propriedade `length` das Strings geradas em C represente a quantidade correta de bytes de dados.
3. **Transpilação:** As sequências de escape em C coincidem exatamente com as do Kotlin, portanto o backend do transpiler pode ejetar a string diretamente sem a necessidade de re-mapeamento complexo em tempo de transpilação.
**Razão:** Traz conformidade com o padrão do Kotlin e de outras linguagens modernas de forma extremamente simples e robusta, com impacto mínimo no parser e garantia de consistência de tamanho e integridade de memória.



