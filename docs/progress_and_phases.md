# Progress and Completed Phases

Este documento detalha historicamente o que foi construído no Aether até o momento.

### Phase 1-7: A Fundação
Construímos a arquitetura base do compilador em Zig.
- **Lexer & Parser:** Capacidade de ler tokens e gerar a AST inicial.
- **Basic Primitives:** Suporte a Declaração de Variáveis (`val`, `var`), Estruturas de Repetição (`while`) e Estruturas de Decisão (`if/else`).
- **Funções:** Assinatura de funções com tipos explícitos (`fun main()`, parâmetros e retornos).
- **C Transpiler Pipeline:** Criação do emissor que lê a AST e cospe o código C.

### Phase 8: OOP (Classes & Propriedades)
Introduzimos o paradigma de Orientação a Objetos pragmático.
- Construtores Primários baseados em Kotlin: `class Person(val name: String, var age: Int)`.
- Instanciação de objetos (implícita, sem a palavra `new`).
- Acesso e modificação segura de propriedades via Ponto (`p.age = 29`).

### Phase 9: TypeChecker Enforcement
O momento em que a linguagem se tornou "fortemente tipada".
- Criação do **Scope** (Tabela de Símbolos local e global).
- Validação Matemática e Lógica: O compilador passou a calcular tipos (`resolved_type`) para todas as expressões da AST.
- Geração de Erros Ricos: Erros tipográficos agora apontam a exata linha e coluna no terminal (ex: tentando atribuir `String` para `Int`).

### Phase 10: Standard Library & Advanced Primitives
Deixamos o C puro um pouco para trás e adotamos o formato de Strings nativas.
- Estrutura nativa `AetherString` injetada no compilado C (composta por um buffer dinâmico e rastreador de *length*).
- Transpilação do operador `+` para executar concatenação segura de Strings na Heap, em vez de estourar os ponteiros brutos do C.

### Phase 11: Methods and Operator Overloading
Poder interno de classes.
- Adicionamos a capacidade de declarar funções `fun` dentro de blocos de `class`.
- O TypeChecker injeta secretamente a palavra `self` no escopo do método, apontando para o tipo da própria classe.
- **AST Desugaring:** A mágica de reescrever a AST em tempo de análise. Descobrimos como interceptar o símbolo `+` matemático e convertê-lo em uma chamada explícita `obj.plus(arg)` para permitir sobrecarga de operadores matemáticos personalizados nas classes (ex: `Vector + Vector`).

### Phase 12: Function Modifiers
Controle estrito de assinaturas de método.
- Introduzimos palavras reservadas baseadas no Kotlin: `override` e `operator`.
- Amarramos o compilador para emitir um erro semântico rigoroso caso um desenvolvedor tente criar uma função de nome matemático (ex: `fun plus`) sem assinar o contrato explícito `operator`. Isso previne a sobrecarga acidental no código.

### Phase 13: Null Safety
Um dos maiores diferenciais de qualidade do Aether.
- Integração profunda no Lexer e Parser para ler tipos Nulos: `String?` e a notação de union type `String | null`.
- **Validação Semântica Extrema:** O TypeChecker isola os valores nulos, impedindo o desenvolvedor de invocar `u.email` se `u` tiver a ínfima possibilidade de ser nulo (Compile-Time Catch).
- Operadores protetores: `?.` (Safe Call), `?:` (Elvis) e `!!` (Not-Null Assertion).
- O backend transpila a blindagem inteira em macros seguras usando o operador ternário em C, impedindo Segmentation Faults.

### Phase 14: CLI & Build Pipeline
- Criação do comando `aether build arquivo.ae` para compilar binários estáticos limpos.
- Diferentemente do `run`, o `build` apenas gera o binário final no diretório atual sem executá-lo, pronto para distribuição.
- O pipeline foi otimizado para apagar os arquivos intermediários C gerados (`temp_out.c`), deixando a pasta limpa.

### Phase 15: Memory Management
- A arquitetura do Aether nativo foi totalmente integrada com o **Boehm-Demers-Weiser Conservative Garbage Collector** (Boehm GC).
- O backend de C foi alterado para instanciar strings e classes com `GC_MALLOC`, extinguindo perfeitamente os Memory Leaks da compilação e permitindo alocações nativas seguras. O flag `-lgc` foi acoplado por padrão no CLI.

### Phase 16: Módulos & Multi-file Compilation
Arquitetura de múltiplos arquivos e imports.
- Adicionado suporte a `import { } from "file"`.
- O TypeChecker lê arquivos importados recursivamente e resolve conflitos no backend utilizando um sistema engenhoso de *Name Mangling* dinâmico.

### Phase 21: Native Test System & CLI Refinements
Integração profunda de testes como recurso *first-class*.
- Fim da necessidade da extensão `.kt`, aceitando explicitamente a extensão nativa `.ae` e tornando sua citação opcional nas importações (`import { add } from "math"`).
- O Lexer e Parser agora leem a nova palavra-chave `test`.
- O comando `aether test` busca recursivamente por arquivos `_test.ae`, compilando-os e gerando a função de verificação `main()` que avalia os testes injetados com a nova macro nativa `assert()`.
