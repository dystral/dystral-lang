# Aether Compiler Roadmap & Progress

This document tracks the historical progress, current status, and future roadmap of the Aether Compiler. 

> **For AI Agents:** Use this file to identify the current phase, check what has already been built, and check off completed tasks as you work.

---

## 🚀 Phase Status & Task Breakdown

### Phase 1 to Phase 5: Infrastructure and Parser (COMPLETED)
- [x] Initialize Zig build environment.
- [x] Create robust lexer and recursive descent parser.
- [x] Establish basic C transpiler and inference engine.

### Phase 6: Control Flow & Expressions (COMPLETED)
- [x] Implement Math, Logic, and Comparison Operators.
- [x] Implement `while` loops, `return`, and assignments.
- [x] Validate via recursive `fibonacci.ae` execution.

### Phase 7: Architecture Refactoring & Documentation (COMPLETED)
- [x] Split source into `core`, `frontend`, and `backend` modules.
- [x] Add Zigdoc to all structural components.

### Phase 8: Classes and OOP Pragmatism (COMPLETED)
- [x] **Task 8.1:** Update Lexer and AST to support `class`, properties, and primary constructors.
- [x] **Task 8.2:** Implement property access (`.`) and instantiation parsing.
- [x] **Task 8.3:** Transpile classes into C `struct` definitions and initialize them safely via implicit `_new` calls.
- [x] **Verify:** Instantiate `class Person(val name: String, var age: Int)` successfully.

### Phase 9: Type Checker Enforcement (COMPLETED)
- [x] **Task 9.1:** Introduce `Scope` (Symbol Table) for resolving variables inside blocks.
- [x] **Task 9.2:** Add `resolved_type` mapping to the AST.
- [x] **Task 9.3:** Emit detailed, rich compiler errors (pointing to exact line and column) when assigning incompatible types.
- [x] **Verify:** The compiler intercepts a `String` to `Int` reassignment, prints a rich `TypeError`, and aborts.

### Phase 10: Standard Library & Advanced Primitives (COMPLETED)
- [x] **Task 10.1:** Implement a native `String` type structure (size + buffer) rather than raw C pointers (`const char*`).
- [x] **Task 10.2:** Transpile `+` operator on Strings into native functions using AST `resolved_type`.
- [x] **Verify:** Manipulate strings natively.

### Phase 11: Methods and Operator Overloading (COMPLETED)
- [x] **Task 11.1:** Add methods support inside classes (`fun` within `class_decl`).
- [x] **Task 11.2:** Inject `self` automatically into method scopes via the TypeChecker.
- [x] **Task 11.3:** AST Desugaring! Convert `a + b` to `a.plus(b)` dynamically during semantic analysis.
- [x] **Verify:** Class `Vector` successfully overloads the `+` operator natively.

### Phase 12: Function Modifiers (COMPLETED)
- [x] **Task 12.1:** Introduce `kw_override` and `kw_operator` to the Lexer and AST.
- [x] **Task 12.2:** Update Parser to parse modifier arrays before function declarations.
- [x] **Task 12.3:** Semantic Enforcement: Block compilation if an overloaded math method is missing the `operator` modifier.
- [x] **Verify:** Strict Kotlin-like enforcement prevents accidental overload.

### Phase 13: Null Safety (COMPLETED)
- [x] **Task 13.1:** Introduce nullable types (`String?` and `String | null`).
- [x] **Task 13.2:** Introduce safe call `?.`, elvis operator `?:`, and not-null assertion `!!`.
- [x] **Task 13.3:** Semantic Enforcement: Block compilation if a nullable type is accessed unsafely.
- [x] **Task 13.4:** Add support to `print()` as a native built-in function via a bypass in the TypeChecker mapping the invocation to C `_Generic printf`. (Note: Later cleaned up via standard library packages).
- [x] **Verify:** Compiler intercepts null-safety violations and the C transpilier emits ternary checks.

### Phase 14: CLI & Build Pipeline (COMPLETED)
- [x] **Task 14.1:** Implement the `aether build file.ae` command in the CLI (`main.zig`).
- [x] **Task 14.2:** The `build` command compiles the code generating a standalone static binary without executing it.
- [x] **Task 14.3:** Optimize the pipeline of the C Transpiler to erase intermediate `.c` and `.o` files, leaving only the executable.

### Phase 15: Memory Management & Garbage Collection (COMPLETED)
- [x] **Task 15.1:** Replace manual allocations (`malloc`) in the C Transpiler with a conservative Garbage Collector (Boehm GC) via the `-lgc` linker flag.
- [x] **Task 15.2:** Eliminate memory leaks in native objects (`AetherString`, class instances).
- [x] **Task 15.3:** Ensure runtime object lifecycles are safe and do not freeze execution.

### Phase 16: Módulos & Multi-file Compilation (COMPLETED)
- [x] **Task 16.1:** Add support for the `import` keyword in the Lexer/Parser.
- [x] **Task 16.2:** Allow the compiler to read, analyze, and compile multiple `.ae` files into a single Global AST.
- [x] **Task 16.3:** Resolve namespace collisions between files using dynamic Name Mangling.

### Phase 17: Core Library, Arrays & For-Loops (PENDING / LATER)
- [ ] **Task 17.1:** Remove the native bypass of functions like `print()`, `assert()`, `exit()` in the TypeChecker, utilizing the hidden standard library package instead.
- [ ] **Task 17.2:** Native support for Collections/Arrays (`[String]`).
- [ ] **Task 17.3:** Support native iteration with `for` loops (`for (item in list)`).

### Phase 18: Short Ternary Operator (PENDING / LATER)
- [ ] **Task 18.1:** Add support in the Lexer/AST for the Ternary Operator (`condition ? true_expr : false_expr`).
- [ ] **Task 18.2:** Implement short ternary (`condition ? true_expr`), which returns `null` automatically if the condition is false.
- [ ] **Task 18.3:** Implement semantic validation (verify matching types, forcing short ternaries to return union types with `null`).
- [ ] **Task 18.4:** Transpile control structure safely to the C ternary operator.

### Phase 19: Exception Handling & Multi-Catch (PENDING / LATER)
- [ ] **Task 19.1:** Implement support for `try`, `catch`, and `finally` blocks.
- [ ] **Task 19.2:** Add support for Java-style Multi-Catch (`catch (ExceptionA | ExceptionB e)`).
- [ ] **Task 19.3:** Map Exceptions and error handling in the C Transpiler (e.g. setjmp/longjmp or structured return codes).

### Phase 20: LLVM Native Emitter & Release Pipeline (PENDING / LATER)
- [ ] **Task 20.1:** Add support for the `--release` flag in the CLI (`aether build --release file.ae`).
- [ ] **Task 20.2:** Build `llvm_emitter.zig`, bypassing the C backend, and translating the Resolved AST directly into **LLVM IR** using native bindings.
- [ ] **Task 20.3:** Hook up LLVM optimization passes (O3) to generate native optimized binaries.

### Phase 21: Native Test System & CLI Refinements (COMPLETED)
- [x] **Task 21.1:** Add native `test "name" { ... }` blocks in the AST and Parser.
- [x] **Task 21.2:** Implement the `aether test` CLI command to search for `_test.ae` files and run test suites in isolation.
- [x] **Task 21.3:** Make file extensions optional in imports (focusing strictly on `.ae` files).
- [x] **Verify:** Native tests run and pass using `aether test`.

### Phase 22: Top-Level Statements & Hybrid Main (COMPLETED)
- [x] **Task 22.1:** Update the AST and Parser to allow free statements (e.g. `print`, function calls) at the root level of files.
- [x] **Task 22.2:** The TypeChecker scopes all root-level statements and compiles them in order.
- [x] **Task 22.3:** The CTranspiler wraps top-level statements inside the generated `aether_main()` or `main()`, avoiding the need for `fun main()`.
- [x] **Task 22.4:** Support Hybrid Main: if the user provides `fun main()`, top-level statements are either wrapped or checked for conflicts.
- [x] **Task 22.5:** Ensure imported modules do not execute their top-level statements; only the entry file or tests run.
- [x] **Verify:** Samples run correctly without needing an explicit `fun main()`.

### Phase 23: Function Overloading & Global Symbol Table (COMPLETED)
- [x] **Task 23.1:** Replace the temporary `.Unknown` type with a global symbol table supporting Function Overloading and C backend Name Mangling.
- [x] **Task 23.2:** Resolve overloaded calls (e.g. `System.print(String)` and `System.print(Int)`) checking argument types statically.
- [x] **Task 23.3:** Validate cross-file overloaded functions in the Global AST.

### Phase 24: Native SDK Architecture (COMPLETED)
- [x] **Task 24.1:** Eliminate utility methods from raw C runtime (`aether_runtime.h`), moving primitive logic into the Aether SDK.
- [x] **Task 24.2:** Create clean C bindings (`lib C { fun printf(...) }`) and implement the `String` class entirely in Aether.
- [x] **Task 24.3:** Move print overloads, `toString` conversions, and concatenation to `std/core.ae`.

### Phase 25: User-Defined Annotations & Metadata (PENDING / LATER)
- [ ] **Task 25.1:** Add support in the Lexer, AST, and Parser for user-defined annotations (e.g. `annotation Header(files: [String])`).
- [ ] **Task 25.2:** Validate that annotations used in code are declared in scope and have matching argument types.
- [ ] **Task 25.3:** Save annotations as reflectable metadata or compile-time options.

### Phase 26: Standard Library Packages & Time API (COMPLETED)
- [x] **Task 26.1:** Map the virtual prefix `std.*` in imports to resolve files inside the compiler's internal `std/` directory.
- [x] **Task 26.2:** Migrate core utilities to the `std.core` package (`std/core.ae`).
- [x] **Task 26.3:** Implement `std.time` package featuring the **Epoch-First** `Time` and `Duration` abstractions.
- [x] **Task 26.4:** Encapsulate `<time.h>` calls inside the `lib NativeTime` block.

### Phase 27: Unary Operators (COMPLETED)
- [x] **Task 27.1:** Add support in the Lexer and Parser for unary prefix operators (e.g. `-10`, `!condition`).
- [x] **Task 27.2:** Update the AST to support `UnaryExpression`.
- [x] **Task 27.3:** Infer unary types in the TypeChecker (`!` requires/returns `Bool`, `-` requires/returns numeric).
- [x] **Task 27.4:** Emit unary expressions in the C Transpiler.

### Phase 28: Native File I/O (`std.fs`) (COMPLETED)
- [x] **Task 28.1:** Design the `std.fs` package containing modern abstractions for reading and writing files (e.g. `File`, `Path`).
- [x] **Task 28.2:** Implement bindings via `lib NativeFS` encapsulating standard POSIX/C library calls (`fopen`, `fread`, `fwrite`, `fclose`).
- [x] **Task 28.3:** Ensure resource clean-up and prevent file descriptor leaks.
- [x] **Task 28.4:** Implement convenience methods (e.g. `fs.readFile(path: String) -> String`).

### Phase 29: True Generics & Collections (`std.collections`) (COMPLETED)
- [x] **Task 29.1:** Add support for Generics in the Parser and TypeChecker (via Monomorphization) to allow container classes without casting.
- [x] **Task 29.2:** Update C Transpiler to emit clean monomorphized structs (e.g. `Box_Int`, `Box_String`) without compiler errors.
- [x] **Task 29.3:** Implement `std.collections` package featuring `List<T>`, `MutableList<T>`, `Set<T>`, `MutableSet<T>`, `Map<K, V>`, and `MutableMap<K, V>`.
- [x] **Task 29.4:** Add dynamic memory allocations (`GC_REALLOC`) for growing arrays in the runtime.
- [x] **Task 29.5:** Implement hash codes (`hashCode()`) for native types (`String`, `Int`) to support hash map bucket placement.

### Phase 30: Class Inheritance & Polymorphism (COMPLETED)
- [x] **Task 30.1:** Introduce the `open` keyword to the Lexer and Parser.
- [x] **Task 30.2:** Update class declaration syntax to parse inheritance: `class SubClass : SuperClass(args)`.
- [x] **Task 30.3:** Support method overrides (`override` keyword check) and resolve member inheritance in the Type Checker.
- [x] **Task 30.4:** Implement struct embedding in the C Transpiler (first field represents the parent class).
- [x] **Task 30.5:** Emit function pointers for polymorphic methods in the struct and wire them up in constructors.
- [x] **Task 30.6:** Implement type compatibility and casting rules (upcasting and downcasting/smart casts) in the Type Checker.

---

## ✅ Definition of Done (Per Phase)
* [x] **Security/Lint:** No memory leaks in tests (utilizing `std.testing.allocator` across internal Zig modules).
* [x] **Build:** `zig build test` and `zig build run` execute successfully.
* [x] **Errors:** Semantic validations fail gracefully, emitting rich terminal errors.

---

## 🛠️ Historic Bugfixes & Tools
* **C Transpiler `.if_expr` (July 9, 2026):** Fixed C transpiler to emit statements for `if/else` instead of C ternary operators `?:` when in Statement mode, resolving compilation issues with complex blocks (e.g., `return`).
* **Runtime Stream (July 9, 2026):** Updated `aether run` command to output `stdout` in real-time (unbuffered) using `child.spawn()` with stream inheritance (`.Inherit`), allowing long-running loops to execute correctly without blocking the TTY.
* **Method Resolution Name Mangling (July 9, 2026):** Resolved a compiler bug where primitive method resolution failed on `Int`, `Bool`, etc., because the type checker searched for the raw type names in `classes_ast` instead of using the mangled name `system_Int`.
