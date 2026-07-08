<div align="center">
  <h1>🌌 Aether Programming Language</h1>
  <p><strong>A pragmatic, statically typed, natively compiled systems language with a Kotlin-inspired syntax.</strong></p>
</div>

---

Aether is a modern, statically-typed programming language designed to combine the elegant expressiveness of Kotlin with the sheer performance and portability of native systems languages.

**Program exactly as you know Kotlin, but with even more pragmatic features.**

Instead of running inside a heavy JVM or relying on interpreted bytecode, Aether compiles directly into highly optimized, standalone executables. It provides developers with an incredibly fast and lightweight loop during development (acting almost like a script), and uncompromising speed in production, generating native binaries with a remarkably low memory footprint.

## ✨ Key Features

- 💎 **Kotlin Familiarity + Pragmatism:** If you know Kotlin, you already know Aether. Supports `val`/`var`, implicit instantiation, expression bodies, and more.
- 🛡️ **Compile-Time Null Safety:** Null is treated as a strict Union Type (`.String | .Null`). The compiler strictly forbids unsafe access, forcing the use of `?.`, `?:`, and `!!`.
- ⚙️ **Operator Overloading:** Overload math operators in classes with explicit contracts via the `operator` modifier.
- 🚀 **Zero Setup Execution:** Just `aether run` and your code compiles and runs instantly.
- 🗑️ **Memory Safe:** Native integration with a conservative Garbage Collector eliminates memory leaks without the overhead of reference counting or pausing VMs.

---

## 📖 Syntax Sneak Peek

Aether code looks familiar and clean. Here's a quick look at classes, properties, and null safety:

```kotlin
// aether
class User(val name: String, var email: String?) {
    fun greet() = "Hello, " + name
}

fun main() {
    val admin: User | null = null

    // Safe calls and Elvis Operator supported natively
    val emailToUse = admin?.email ?: "no-reply@aether.lang"
    print(emailToUse)
}
```

---

## 💻 Using Aether (For Developers)

Writing code in Aether is extremely lightweight. The Aether CLI comes with two main operational modes:

### `aether run` (Development)
Perfect for development. It compiles a temporary binary, executes it instantly, and cleans up the mess. You get sub-second feedback as if it were a dynamic scripting language.
```bash
aether run my_script.ae
```

### `aether build` (Production)
Perfect for distribution. Generates a standalone native binary locally with an incredibly low memory footprint, ready to be deployed to servers.
```bash
aether build my_script.ae
# Output: ./my_script (Native Executable)
```

---

## 🛠️ Contributing to the Compiler (For Contributors)

If you want to hack on the Aether compiler itself, you will need to prepare your machine. The compiler is written in **Zig** and uses **Boehm GC** for the generated C code.

### 1. Install Dependencies
You need **Zig (0.13.0+)** and the Garbage Collector library.
```bash
# Ubuntu / Debian
sudo apt install libgc-dev

# macOS
brew install bdw-gc
```

### 2. Build the Compiler
```bash
git clone https://github.com/your-username/aether.git
cd aether
zig build
```
This generates the `aether` binary inside `./zig-out/bin/`. *(For a more detailed breakdown, see our [Setup Guide](docs/setup.md)).*

---

## 🏗️ Architecture & Documentation

Aether's compiler is fully documented. If you are curious about how we process ASTs or why we chose certain architectural paths, check out the `docs/` folder:

- 🏛️ **[Architecture Overview](docs/architecture.md)**: How the Lexer, Parser, TypeChecker, and C Transpiler pipeline work.
- ⚖️ **[Architectural Decisions (ADRs)](docs/decisions.md)**: Why we enforce operator modifiers and how we handle Null Safety.
- 📈 **[Progress & Roadmap](docs/progress_and_phases.md)**: The historic evolution of the compiler and what's next.

---

## 🛣️ What's Next? (Roadmap)

We are currently on **v0.1.x**. The immediate next steps include:
- **Phase 16:** Module System & Multi-file Compilation (`import`).
- **Phase 17:** Core Stdlib, native Collections (`[String]`) and `for-in` loops.
- **Phase 18:** Short Ternary Operator.
- **Phase 19:** Exception Handling (`try-catch` & multi-catch).
- **Phase 20:** LLVM IR Native Release Backend for maximum optimization.

*(See [aether-compiler.md](aether-compiler.md) for the full granular roadmap).*
