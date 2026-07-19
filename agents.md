# AI Agent Guide - Aether Compiler Project

Welcome, AI Agent! This guide outlines the project context, technical stack, architecture, and coding guidelines for the Aether Compiler. Read this file before making any changes.

## 🌌 Project Overview
Aether is a pragmatic, statically typed, natively compiled systems language with a Kotlin-inspired syntax. 
* **The Compiler** is built from scratch in **Zig (0.13.0)**.
* **The Backend** compiles Aether code (`.ae`) into intermediate **C code**, which is then compiled into a native binary via `zig cc -O0` (Development mode) or direct C optimization.
* **Memory Management:** Driven by a conservative Garbage Collector (**Boehm GC**) in the generated C runtime.

---

## 🛠️ CLI & Build Commands Quick Reference
Always use these commands to build, run, and test the project:

```bash
# 1. Build the Aether compiler
zig build

# 2. Run the compiler's unit tests (written in Zig)
zig build test

# 3. Run an Aether program using the freshly built compiler
./zig-out/bin/aether run samples/path_to_file.ae

# 4. Compile an Aether program to a static native binary
./zig-out/bin/aether build samples/path_to_file.ae

# 5. Run the native Aether test suite (executes `test "name" {}` blocks)
./zig-out/bin/aether test
```

---

## 🏛️ Codebase Map & Entry Points
* [src/main.zig](src/main.zig): CLI entry point. Parses commands (`run`, `build`, `test`) and drives the pipeline.
* [src/frontend/lexer.zig](src/frontend/lexer.zig): Tokenizer. Converts source into token streams.
* [src/frontend/parser.zig](src/frontend/parser.zig): Recursive Descent Parser. Generates the AST.
* [src/core/ast.zig](src/core/ast.zig): Defines AST data structures (`ASTNode`, `TokenType`). Tracks positions (`line`, `column`).
* [src/core/types.zig](src/core/types.zig): Type Checker and Scope Resolver. Resolves types, desugars operators (`+` to `.plus()`), and manages symbols.
* [src/backend/c_transpiler.zig](src/backend/c_transpiler.zig): Generates the C output.
* [src/backend/c_transpiler/aether_runtime.h](src/backend/c_transpiler/aether_runtime.h): Core runtime definitions, structures (e.g., `AetherString`), and GC integration.
* [src/std/](src/std/): The Aether Standard Library package (written in Aether). Includes `std/core.ae` and `std/time.ae`.
* [samples/](samples/): Example scripts and syntax tests.
* [tests/](tests/): Automated toolchain test cases.

---

## 📚 Documentation Index
> Consult these files **on-demand**, not necessarily at the start of every session.

* [docs/architecture.md](docs/architecture.md): Compiler module layout and architectural decisions. Read when understanding the compilation pipeline or reorganizing modules.
* [docs/decisions.md](docs/decisions.md): ADRs (Architecture Decision Records). **Read before introducing new patterns or changing existing decisions** to avoid rework.
* [docs/language_tour.md](docs/language_tour.md): Full Aether syntax reference. Use when writing samples, tests, or `.ae` code examples.
* [docs/roadmap.md](docs/roadmap.md): Phase history, completed tasks, and pending features. Read to identify the current project state.
* [docs/setup.md](docs/setup.md): Dependency installation and environment setup. Only needed during initial setup.

---

## ⚠️ Critical Rules & Gotchas for LLMs
1. **Zig Version:** Ensure compatibility with Zig `0.13.0`. Do not use deprecated API structures from older versions.
2. **Type Checking First:** Never generate code bypassing validations. All semantic checks, Null Safety, and Type Enforcements must happen in `src/core/types.zig` before calling the transpiler.
3. **Boehm GC Integration:** Memory allocation in the transpiled C code must use GC-managed hooks (like `GC_MALLOC` or `GC_MALLOC_ATOMIC`) via runtime definitions. Do not use raw malloc/free.
4. **Name Mangling:** Classes, functions, and standard library methods use Name Mangling (e.g., `system_Int` instead of raw `Int`) in the C backend to avoid naming collisions.
5. **No Placeholders:** When writing Aether examples or test cases, write complete, working assertions.
6. **Task Status Tracking:** Refer to [docs/roadmap.md](docs/roadmap.md) for the historic roadmap, completed phases, and pending features.
