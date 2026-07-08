# Aether Compiler Architecture

Aether is a statically typed, pragmatic programming language that uses Kotlin-inspired syntax. It is written in Zig and transpiles to C, combining high-level developer ergonomics with low-level portability and speed.

## High-Level Pipeline

The Aether compiler (`aether`) follows a classic multi-pass architecture:
1. **Frontend**: Source Code (`.ae`) -> Tokens -> Abstract Syntax Tree (AST).
2. **Core (Semantic Engine)**: AST -> Scope Resolution -> Type Checking -> Resolved AST.
3. **Backend**: Resolved AST -> Intermediate C Code -> Native Binary.

---

## 1. Frontend (`src/frontend/`)

### Lexer (`lexer.zig`)
Converts raw source code strings into a stream of tokens. It handles keyword recognition, operators, literals (Strings, Ints, Bools, Null), and tracks exact line/column positions for rich error reporting.

### Parser (`parser.zig`)
A Recursive Descent Parser that consumes tokens and builds an Abstract Syntax Tree (AST). 
- Implements statement parsing (variables, conditionals, loops).
- Implements expression parsing based on precedence (assignments, equality, math, method calls, property access).
- Generates data structures defined in `ast.zig`.

---

## 2. Core (`src/core/`)

### AST (`ast.zig`)
Defines the `ASTNode` structures and `TokenType` enums. Every node contains positional metadata (`line`, `column`) and an optional `resolved_type` which is populated during the Semantic pass.

### Semantic Engine & TypeChecker (`types.zig`)
The most critical part of the compiler. It ensures mathematical and logical correctness before any code generation occurs.
- **Scope Management**: Tracks variable declarations block-by-block.
- **Type Inference**: Infers types for literals and expressions.
- **Enforcement**: Blocks compilation with rich terminal errors if incompatible types are assigned, or if `null` is accessed unsafely.
- **AST Desugaring**: Transforms high-level constructs into low-level method calls (e.g., converting `a + b` to `a.plus(b)` dynamically).

---

## 3. Backend (Dual-Strategy)

Aether emprega uma arquitetura de "Dual-Backend" para entregar o melhor dos dois mundos: ciclos de feedback instantâneos durante o desenvolvimento e performance extrema em produção.

### 3.1. C Transpiler (Modo Desenvolvimento / `run`)
Localizado em `src/backend/c_transpiler.zig`.
- Foco absoluto em **velocidade de compilação**.
- Pega a AST resolvida e emite código C intermediário puro.
- Em seguida, o CLI aciona internamente o `zig cc -O0` para gerar o binário de debug em tempo recorde (geralmente sub-segundo).
- Útil para testar a aplicação localmente e iterar rápido.

### 3.2. LLVM IR Emitter (Modo Produção / `build --release`)
*Fase Futura (Pipeline de Release)*
- Foco absoluto em **performance de execução**.
- Em vez de gerar C, o compilador consumirá os *bindings* nativos do LLVM direto no Zig para emitir **LLVM IR** (Intermediate Representation).
- Aciona o pipeline de otimização agressiva do LLVM (O3), gerando um binário nativo estático, enxuto e livre das abstrações do C.

### Build System (`main.zig`)
Orquestra o fluxo inteiro. Ele decide qual pipeline do Backend acionar dependendo dos argumentos passados via CLI (`run` invoca o C Transpiler, `build --release` invocará o LLVM Emitter).
