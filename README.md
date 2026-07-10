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
- ⚡ **Top-Level Execution:** Start scripting immediately without boilerplate. No `fun main()` required unless you want it (Hybrid Main approach).
- 🛡️ **Compile-Time Null Safety:** Null is treated as a strict Union Type (`.String | .Null`). The compiler strictly forbids unsafe access, forcing the use of `?.`, `?:`, and `!!`.
- 📦 **File-Based Modules & Standard Library:** A modern module system with destructured imports (`import { fun1 } from "file.ae"`). Features an ever-growing Standard Library built natively (`std.core`, `std.math`, `std.time`).
- 🕒 **Epoch-First Time API:** Time handling done right, inspired by Go. Zero-overhead Time and Duration mathematics leveraging the language's native Operator Overloading.
- 🔁 **Native Arrays and Loops:** First-class support for native typed arrays (`[1, 2, 3]`), combined with ergonomic `for (item in array)` and `while` loops.
- ⚙️ **Operator Overloading:** Overload math operators in classes with explicit contracts via the `operator` modifier (e.g., `operator fun plus()`).
- 🧪 **Native Test System:** First-class testing support. Write `test "name" {}` blocks directly and run `aether test` for an isolated and fast native testing suite.
- 🗑️ **Memory Safe:** Native integration with a conservative Garbage Collector (Boehm GC) eliminates memory leaks without the overhead of reference counting or pausing VMs.

---

## 📖 Syntax & Language Tour

Aether code looks familiar and clean. If you want to deeply understand how Aether differs from Kotlin (Union Types, Modifiers, and File-based Imports), **[read the full Language Tour](docs/language_tour.md)**.

Here's a quick look at top-level statements, operator overloading, the native Time API, and arrays:

```kotlin
// script.ae
import { date, hours, now, Time, Duration } from "std.time"

class Flight(val destination: String, val departure: Time) {
    fun isDelayed() = now() > departure
    
    // Custom Operator Overloading
    operator fun plus(delay: Duration): Flight {
        return Flight(this.destination, this.departure + delay)
    }
}

// Top-Level execution (no `fun main()` required)
val flights = [
    Flight("Tokyo", date(2026, 12, 10)),
    Flight("Paris", now() + hours(2))
]

// Ergonomic loops over strictly typed arrays
for (f in flights) {
    if (f.isDelayed()) {
        val newFlight = f + hours(1) // Triggers `operator plus`
        print("Delayed to: " + newFlight.departure.format("HH:mm"))
    }
}
```

### 🧪 Built-in Testing
Testing is a first-class citizen in Aether. No external libraries or configurations required.

```kotlin
// script_test.ae
import { assert } from "std.core"
import { hours, now } from "std.time"
import { Flight } from "./script.ae"

test "adding duration to flight shifts departure" {
    val f = Flight("Tokyo", now())
    val delayed = f + hours(5)
    
    assert(delayed.departure > f.departure)
}
```
Run it simply with `aether test`.

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
```

### `aether test` (Testing)
Aether has native test integration. Simply create files ending in `_test.ae` containing native `test "name" { }` blocks and run the test CLI.
The compiler will automatically find, group, and execute all tests locally, isolating them from your production binaries.
```bash
aether test
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

We are currently finishing the stabilization of **v0.1.x** (Phase 27). The immediate next steps include:
- **Phase 28:** File I/O nativo (Desenvolvimento do `std.fs` para manipulação de arquivos).
- **Phase 29:** Custom Module Imports e caminhos relativos avançados (`import { x } from "./../utils"`).
- **Phase 30:** JSON Serialization/Deserialization.
- **Phase 31:** Network Sockets / HTTP Foundation.
- **Phase 32:** LLVM IR Native Release Backend for maximum optimization (Production build transition).

*(See [aether-compiler.md](aether-compiler.md) for the full granular roadmap and historic evolution).*
