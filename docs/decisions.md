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
