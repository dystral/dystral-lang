# Project: Aether Compiler (v0.1.x)

## Overview
Aether is a compiled programming language focused on systems performance, conciseness, and type safety without the overhead of managed environments. This project builds the compiler from scratch in **Zig**. The initial goal is to support the base grammar (val, var, functions, classes) with a strict Type Checker and a C transpilation strategy for fast feedback (via `zig cc -O0`).

## Project Type
**BACKEND** (CLI / Systems Programming)

## Architectural Decisions & Notes
> [!IMPORTANT]
> 1. **Parser:** Recursive descent parser for maximum speed and control. Contains robust error reporting (AST nodes track exact line and column numbers).
> 2. **C Transpilation:** Aether code transpiles to C code for rapid development and high portability.
> 3. **Memory Management (v0.1):** String manipulations and object instantiations defer to `malloc` directly via C structs. Arena/LLVM memory safety will be introduced in production phases.
> 4. **Operator Overloading (Future Vision):** Inspired by Kotlin, operators like `+`, `-`, `*` will eventually map to class methods like `operator fun plus()`. However, for v0.1, the Transpiler statically evaluates binary expressions via the Type Checker (`resolved_type`) and "inlines" them to native C macros (e.g., `AetherString_concat`).

## Success Criteria
- The compiler CLI can read a `.ae` file (`aether run`).
- The lexer tokenizes the input correctly.
- The parser builds an AST and embeds lexical locations for error tracking.
- The semantic Type Checker enforces static typing before compilation, halting if it detects mismatching types.
- The transpiled C code compiles and runs successfully.

## Tech Stack
- **Zig:** Chosen for extreme speed, manual memory control, and flawless native integration with `zig cc`.
- **C Intermediate:** For development backend.
- **LLVM:** Planned for the Release pipeline in the future.

## File Structure
```text
.
├── build.zig                  # Zig build script
├── src/
│   ├── main.zig               # CLI entry point (aether)
│   ├── core/
│   │   ├── ast.zig            # Tree Data Structures (line/col tracked)
│   │   └── types.zig          # Semantic Type Checker and Scopes
│   ├── frontend/
│   │   ├── lexer.zig          # Lexical Analyzer (Tokenization)
│   │   └── parser.zig         # Syntactic Analyzer (AST Construction)
│   └── backend/
│       └── c_transpiler.zig   # Intermediate C code generation
├── samples/                   # Example code used for validation
└── tests/                     # Toolchain test cases
```

## Task Breakdown

### Phase 1 to Phase 5: Infrastructure and Parser (COMPLETED)
- Initialized Zig build environment.
- Created robust lexer and recursive descent parser.
- Established basic C transpiler and inference engine.

### Phase 6: Control Flow & Expressions (COMPLETED)
- Implemented Math, Logic, and Comparison Operators.
- Implemented `while` loops, `return`, and assignments.
- Validated via recursive `fibonacci.ae` execution.

### Phase 7: Architecture Refactoring & Documentation (COMPLETED)
- Split source into `core`, `frontend`, and `backend` modules.
- Added Zigdoc to all structural components.

### Phase 8: Classes and OOP Pragmatism (COMPLETED)
- **Task 8.1:** Update Lexer and AST to support `class`, properties, and primary constructors.
- **Task 8.2:** Implement property access (`.`) and instantiation parsing.
- **Task 8.3:** Transpile classes into C `struct` definitions and initialize them safely via implicit `_new` calls.
- **VERIFY:** Created and instantiated `class Person(val name: String, var age: Int)`.

### Phase 9: Type Checker Enforcement (COMPLETED)
- **Task 9.1:** Introduce `Scope` (Symbol Table) for resolving variables inside blocks.
- **Task 9.2:** Add `resolved_type` mapping to the AST.
- **Task 9.3:** Emit detailed, rich compiler errors (pointing exactly to the line and column) when assigning incompatible types.
- **VERIFY:** The compiler intercepts a `String` to `Int` reassignment, prints a rich `TypeError`, and safely aborts.

### Phase 10: Standard Library & Advanced Primitives (COMPLETED)
- **Task 10.1:** Implement a native `String` type structure (size + buffer) rather than raw C pointers (`const char*`).
- **Task 10.2:** Transpile `+` operator on Strings into native functions using AST `resolved_type`.
- **VERIFY:** Manipulate strings natively.

### Phase 11: Methods and Operator Overloading (COMPLETED)
- **Task 11.1:** Add methods support inside classes (`fun` within `class_decl`).
- **Task 11.2:** Inject `self` automatically into method scopes via the TypeChecker.
- **Task 11.3:** AST Desugaring! Convert `a + b` to `a.plus(b)` dynamically during semantic analysis.
- **VERIFY:** Class `Vector` successfully overloads the `+` operator natively.

### Phase 12: Function Modifiers (COMPLETED)
- **Task 12.1:** Introduce `kw_override` and `kw_operator` to the Lexer and AST.
- **Task 12.2:** Update Parser to parse modifier arrays before function declarations.
- **Task 12.3:** Semantic Enforcement: Block compilation if an overloaded math method is missing the `operator` modifier.
- **VERIFY:** Strict Kotlin-like enforcement prevents accidental overload.

### Phase 13: Null Safety (COMPLETED)
- **Task 13.1:** Introduce nullable types (`String?` and `String | null`).
- **Task 13.2:** Introduce safe call `?.`, elvis operator `?:`, and not-null assertion `!!`.
- **Task 13.3:** Semantic Enforcement: Block compilation if a nullable type is accessed unsafely.
- **Task 13.4:** Adicionado suporte ao `print()` como uma função "Built-In" nativa, através de um bypass no TypeChecker que mapeia a invocação diretamente para o C `_Generic printf`. Isso deverá ser removido no futuro com a criação do módulo `Core/Stdlib` do Aether.
- **VERIFY:** O compilador interceptou violações de Null Safety com precisão cirúrgica e o Transpilador C emitiu checagens ternárias que compilaram e executaram sem Segmentation Faults.

### Phase 14: CLI & Build Pipeline (COMPLETED)
- **Task 14.1:** Implementar o comando `aether build arquivo.ae` no CLI (`main.zig`).
- **Task 14.2:** O comando `build` deve compilar o código gerando um binário final estático (ex: `arquivo`) sem executá-lo, diferente do `run`.
- **Task 14.3:** Otimizar o pipeline do C Transpiler para apagar os arquivos intermediários (`.c` e `.o`) deixando a pasta limpa apenas com o executável.

### Phase 15: Memory Management & Garbage Collection (COMPLETED)
- **Task 15.1:** Substituir alocações manuais soltas (`malloc`) no C Transpiler por um Garbage Collector conservador (Boehm GC) ou implementar *Reference Counting*.
- **Task 15.2:** Eliminar vazamentos de memória (*memory leaks*) nos objetos nativos (`AetherString`, instâncias de classes).
- **Task 15.3:** Garantir que o ciclo de vida dos objetos em tempo de execução seja seguro e não trave a máquina em loops infinitos.

### Phase 16: Módulos & Multi-file Compilation (DONE)
- **Task 16.1:** Adicionar suporte à palavra-chave `import` no Lexer/Parser.
- **Task 16.2:** Permitir que o compilador leia, analise e costure múltiplos `.ae` em uma única AST Global.
- **Task 16.3:** Resolver colisões de namespace entre arquivos.

### Phase 17: Core Library, Arrays & For-Loops (LATER)
- **Task 17.1:** Remover o bypass nativo de funções como `print()` no TypeChecker, introduzindo um arquivo base oculto (`core.ae`) que define a Stdlib do Aether.
- **Task 17.2:** Suporte nativo a Coleções/Arrays (`[String]`).
- **Task 17.3:** Adicionar suporte nativo à iteração com loop `for` (`for (item in list)`).

### Phase 18: Short Ternary Operator (LATER)
- **Task 18.1:** Adicionar suporte no Lexer/AST para o Operador Ternário (`condicao ? verdadeiro : falso`).
- **Task 18.2:** Inovação Aether: Permitir o ternário curto (`condicao ? verdadeiro`), onde a ausência do `:` faz a expressão retornar `null` automaticamente se a condição for falsa.
- **Task 18.3:** Implementar validação semântica (garantir que os tipos batam, forçando que ternários curtos retornem Union Types com `null`).
- **Task 18.4:** Transpilar a estrutura de controle com segurança para o ternário do C.

### Phase 19: Exception Handling & Multi-Catch (LATER)
- **Task 19.1:** Implementar suporte a blocos `try`, `catch` e `finally`.
- **Task 19.2:** Adicionar suporte a *Multi-Catch* estilo Java (`catch (ExceptionA | ExceptionB e)`).
- **Task 19.3:** Mapear Exceptions e tratamento de erros de forma robusta no Transpilador C (ex: setjmp/longjmp ou códigos de retorno estruturados).

### Phase 20: LLVM Native Emitter & Release Pipeline (LATER)
- **Task 20.1:** Adicionar suporte ao *flag* `--release` na CLI do compilador (`aether build --release arquivo.ae`).
- **Task 20.2:** Construir o `llvm_emitter.zig`, ignorando completamente o Backend C, traduzindo a AST Resolvida diretamente para **LLVM IR** via bindings nativos do Zig.
- **Task 20.3:** Ligar o otimizador do LLVM (O3) para gerar binários monolíticos de extrema performance.

### Phase 21: Native Test System & CLI Refinements (COMPLETED)
- **Task 21.1:** Adicionar blocos nativos de `test "nome" { ... }` na AST e no Parser.
- **Task 21.2:** Implementar comando `aether test` na CLI para procurar arquivos `_test.ae` automaticamente e rodar as suítes isoladamente.
- **Task 21.3:** Tornar as extensões de arquivos opcionais nos imports, focando estritamente em arquivos `.ae` no ecossistema e abandonando a sintaxe `.kt` na invocação.
- **VERIFY:** Os testes dos samples atuais rodam e passam com o sistema nativo da linguagem integrado, permitindo verificações diretas.

### Phase 22: Top-Level Statements & Hybrid Main (COMPLETED)
- **Task 22.1:** Atualizar a AST e o Parser para permitir instruções livres (ex: `print`, chamadas de função, atribuições) na raiz do arquivo.
- **Task 22.2:** O TypeChecker deve englobar todas as instruções Top-Level no momento da compilação, permitindo que elas executem em ordem.
- **Task 22.3:** O CTranspiler precisa detectar Top-Level Statements e envelopá-los dentro da função gerada nativamente `aether_main()` ou `main()`, dispensando a escrita obrigatória do `fun main()`.
- **Task 22.4:** Permitir a Abordagem Híbrida: se o usuário fornecer um `fun main()`, as top-level statements serão ignoradas ou o compilador irá jogar erro de conflito, a definir na implementação.
- **Task 22.5:** Garantir que arquivos que são *importados* não executem seus top-level statements aleatoriamente. Apenas o arquivo CLI principal ou os testes devem rodar.
- **VERIFY:** O `samples/fibonacci.ae` ou `samples/string_ops.ae` funcionam corretamente se apagarmos as chaves do `fun main()`.

## ✅ Definition of Done (Per Phase)
- [x] Security/Lint: No memory leaks using `std.testing.allocator` across all modules.
- [x] Build: `zig build test` and `zig build run` execute successfully.
- [x] Errors: Semantic validations fail gracefully with rich terminal outputs.
