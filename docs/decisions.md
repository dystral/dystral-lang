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
