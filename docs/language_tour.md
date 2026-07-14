# The Aether Language Tour

Aether was born from a desire to write low-level systems code with the ergonomics of modern high-level languages like Kotlin. 

While Aether shares an almost identical baseline syntax with Kotlin, it operates in a fundamentally different environment: **there is no JVM, no massive standard library, and no runtime interpreter.** Everything is compiled directly to native code with a highly optimized embedded Garbage Collector.

Because of this, some architectural decisions differ from Kotlin to provide extreme performance and absolute safety.

---

## 1. Compile-Time Null Safety (Union Types)

Null Pointer Exceptions (NPEs) are the bane of native systems programming, often resulting in fatal `Segmentation Faults` in C/C++. Aether prevents this statically.

In Aether, `null` is not a primitive value that can be assigned anywhere. It is a strictly enforced **Union Type**.

```kotlin
// 'admin' is strictly a User. It CANNOT be null.
val admin: User = User("Leo")

// 'guest' is a Union Type: (.User | .Null)
val guest: User? = null
```

If you try to access `guest.name`, the Aether compiler will **block the compilation**, because you are trying to access a property on something that might be `null`.

**Safe Calls:**
```kotlin
// The Elvis Operator (?:) unwraps the Union Type safely.
val finalName = guest?.name ?: "Unknown"

// The Bang-Bang Operator (!!) forces unwrap, trusting the developer.
// Use with caution!
val dangerousName = guest!!.name
```

---

## 2. Operator Overloading via Modifiers

Kotlin allows you to overload mathematical operators (like `+` and `-`) by naming a function `plus` or `minus`. Aether takes this a step further to prevent accidental overloads.

In Aether, naming a function `plus` is not enough. You **must** explicitly tag the function with the `operator` modifier. This acts as a clear contract to anyone reading the code that this function fundamentally alters the language's math operations for that class.

```kotlin
class Vector(val x: Int, val y: Int) {
    
    // The 'operator' modifier is MANDATORY.
    operator fun plus(other: Vector): Vector {
        return Vector(this.x + other.x, this.y + other.y)
    }
}

fun main() {
    val v1 = Vector(1, 2)
    val v2 = Vector(3, 4)
    val v3 = v1 + v2 // Automatically calls v1.plus(v2)
}
```

---

## 3. Implicit Returns & Expression Bodies

Like Kotlin, Aether heavily favors expressions. If a function is simple enough, you don't need curly braces or a `return` keyword.

```kotlin
// Traditional block body
fun multiply(a: Int, b: Int): Int {
    return a * b
}

// Expression body (Type is inferred implicitly)
fun multiply(a: Int, b: Int) = a * b
```

---

## 4. Module System (File-Based Namespaces)

Aether adopts a modern, lightweight module system inspired by ES6 and Go. Every `.ae` file is an implicit module. You don't need to define explicit `package com.x.y` declarations at the top of your files.

To use symbols from another file, you must explicitly declare exactly what you want to import using destructuring. This prevents polluting your namespace and makes dependencies crystal clear.

```kotlin
// Assumes a file named 'math.ae' exists in the same directory.
// The .ae extension is optional and will be inferred automatically.
import { add, Vector } from "math"

// Wildcard Import (Imports all public symbols from the module)
import {} from "network"

fun main() {
    val v = Vector(1, 1)
    val r = add(5, 5)
}
```

**The Implicit Standard Library**
Aether comes with a core module named `system.ae` which contains fundamental types, C-bindings, and intrinsic functions (like `print`). The compiler automatically injects an `import {} from "system"` at the top of every file, making all standard functions globally available without explicitly requiring an import statement.

*(Note: In the C backend, the compiler automatically performs Name Mangling to prevent collisions across files, meaning `add` inside `math.ae` becomes `math_add` in the final native binary, ensuring absolute safety).*

---

## 5. Top-Level Statements & Side-Effects

Aether is designed to be highly fluid for quick scripts. Because of this, `fun main()` is **optional**. You can write statements directly at the root of your file.

```kotlin
// script.ae
import { add } from "math"

// This is perfectly valid Aether code
val a = 10
val b = 5
print(add(a, b))
```

If your code reaches the end of the file, it exits successfully (returning `0` to the OS). If you want to force an exit with an error code, you can use the built-in `exit(code)` function natively.

**The Golden Rule of Modules (No Side-Effects):**
Top-level execution is **only allowed in your root file** (the one you pass to `aether run`). If an *imported* file tries to run top-level statements (like calling `print`), the compiler will strictly block it and throw an `ImportSideEffectsNotAllowed` error. 

Imported files must be "passive libraries", meaning they should only **declare** things (Functions, Classes, Tests, etc.). This ensures maximum code hygiene and predictable execution paths.

---

## 6. Native Testing

Aether has a first-class, built-in testing system. You don't need external libraries or complex test runners. Just create a file with the suffix `_test.ae`, write a `test` block, and use the `assert` macro.

```kotlin
// math_test.ae
import { add } from "math"

test "should add two numbers correctly" {
    val result = add(10, 5)
    assert(result == 15)
}
```

Then, run `aether test` in your terminal. The compiler will automatically discover, group, and run all your tests in an isolated native binary.

---

## 7. C Interoperability & Annotations

Because Aether transpiles to C, integrating with native C libraries is seamless. You can declare a `lib` block to map C functions into Aether without writing any wrapper code.

Annotations (like `@Header`) instruct the C Transpiler to inject the corresponding `#include` directives at the top of the generated C file.

```kotlin
// core.ae (Aether's emerging Standard Library)
@Header("<stdio.h>", "<stdlib.h>")
lib System {
    fun print(value: Unknown): Void
    fun exit(code: Int): Void
}
```

You can then import and use these native functions exactly like standard Aether code:

```kotlin
import { System } from "core"

System.print("Hello from C!")
System.exit(0)
```

*(Note: In the current phase, Annotations are structural compiler pragmas. In future phases, Aether will support declaring custom user-defined annotations natively).*

---

## 8. Arrays and Loops

Aether features a native type system for dynamic arrays and full-featured generic **collections**, along with ergonomic `for` and `while` loops.

The `[Type]` syntax is syntactic sugar for an immutable **`List<T>`**. Read elements with `[index]` or `.get(index)`, check size with `.size()`. For mutation, call `.mut()` on any immutable collection to get a `MutableList<T>` (see [Section 10.5](#105-mutability-conversion----mut-and-freeze)).

```kotlin
fun main() {
    // Immutable list literal
    val numbers = [1, 2, 3, 4, 5]
    
    // Index access
    val first = numbers[0]
    
    // For-loops iterate seamlessly over lists
    var sum = 0
    for (item in numbers) {
        sum = sum + item
    }
    
    // While loops are also fully supported
    var i = 0
    while (i < 5) {
        // do something
        i = i + 1
    }
}
```

---

## 9. Standard Library Packages & Time API

Aether organizes its standard library into virtual packages starting with `std.`. The compiler automatically maps these to the language's internal SDK.

For example, manipulating Date and Time in Aether is done through the `std.time` package, which uses an ultra-fast **Epoch-First** architecture (inspired by Go). Instead of bloated objects containing Year/Month/Day properties, Aether's `Time` class is a zero-overhead wrapper around a simple Unix Epoch integer. 

```kotlin
import { Time, Duration, now, date, hours, minutes, seconds } from "std.time"

fun main() {
    // Current time (machine epoch)
    val today = now()
    
    // Creating specific dates directly
    val birthday = date(1990, 7, 20)
    
    // Time mathematics uses Aether's native Operator Overloading
    val dur = hours(48)
    val future = birthday + dur // Birthday + 48 hours
    
    // Time difference returns a Duration
    val diff = today - birthday 
    print(diff.hours().toString())
    
    // Formatting uses the traditional standard
    print(future.format("YYYY-MM-DD HH:mm:ss"))
}
```

Because time math is just adding integers (`epoch + seconds`), it avoids the historic timezone bugs that plague other languages when dealing with daylight savings and calendar math. The `std.time` package makes all duration math explicit (e.g., `hours(2)`) and heavily leverages Operator Overloading for ergonomics.

---

## 10. Collections (List, Map, Set)

Aether comes with a rich, generic standard library of collection types in `std.collections`. Collections fall into two categories: **immutable** (safe, read-only snapshots) and **mutable** (full read-write).

Import what you need:

```kotlin
import { List, MutableList, Map, MutableMap, Set, MutableSet } from "std.collections"
```

---

### 10.1 List & MutableList

`List<T>` is a **read-only** ordered sequence. Create one with a bracket literal — the same syntax as a native array:

```kotlin
val nums: List<Int> = [10, 20, 30]

// Index access with brackets
val first = nums[0]       // 10

// Size
val n = nums.size()       // 3

// Read by position
val second = nums.get(1)  // 20
```

`MutableList<T>` wraps a `List<T>` and allows mutation:

```kotlin
val items: List<Int> = [5]
val list: MutableList<Int> = MutableList(items)

list.add(10)
list.add(20)
list.set(0, 99)   // overwrite position 0
list.remove(1)    // remove by index

assert(list.size() == 2)
assert(list.get(0) == 99)
```

You can also get a `MutableList` from any existing `List` by calling `.mut()`, and convert back to an immutable `List` via `.freeze()` (see [Section 10.5](#105-mutability-conversion----mut-and-freeze)):

```kotlin
val frozen: List<Int> = [1, 2, 3]
val mutable = frozen.mut()   // MutableList<Int>
mutable.add(4)
val back = mutable.freeze()  // List<Int> again
```

**Type inference** works out-of-the-box. The compiler resolves the element type from the literal:

```kotlin
val list = MutableList([42])  // inferred: MutableList<Int>
list.add(100)
```

---

### 10.2 Map & MutableMap

Maps are associative containers. The cleanest way to create one is with the **`of` infix literal syntax** inside brackets:

```kotlin
// Immutable literal map (Map<String, String>)
val capitals = [
    "Brazil" of "Brasília",
    "France" of "Paris",
    "Japan"  of "Tokyo"
]

// Read by key using brackets (returns the value or null)
val capital = capitals["Brazil"]  // "Brasília"
val missing  = capitals["India"]  // null
```

The `of` keyword is a reserved **infix pair constructor**. Each `key of value` expression creates one entry. The compiler deduces `K` and `V` from the first pair.

`Map<K, V>` (immutable) exposes only `.get(key)` and `.containsKey(key)`.

---

### 10.3 Set & MutableSet

A `Set<T>` is an unordered collection of **unique** values backed by a `Map<T, Bool>`.

```kotlin
val tags = MutableSet(items)   // inferred: MutableSet<String>

tags.add("Aether")
tags.add("Zig")
tags.add("Aether")  // duplicate is silently ignored

assert(tags.contains("Aether") == true)
assert(tags.contains("Rust")   == false)
```

`Set<T>` (immutable) wraps a `Map<T, Bool>` and only exposes `.contains(element)`.

---

### 10.4 Literal Sugar Reference

| Syntax | Meaning |
|---|---|
| `[1, 2, 3]` | `List<Int>` literal |
| `["a", "b"]` | `List<String>` literal |
| `["k" of "v", ...]` | `Map<String, String>` literal (immutable) |
| `map["key"]` | read from `Map` or `MutableMap` |
| `map["key"] = val` | write to `MutableMap` |

> **Note:** The bracket literal `[x of y, ...]` always produces an **immutable** `Map`. For a mutable map you must use `MutableMap(...)` explicitly.

---

### 10.5 Mutability Conversion — `.mut()` and `.freeze()`

Aether collections are **immutable by default**. When you need to mutate a snapshot, call `.mut()` to get a mutable view. When you're done mutating and want to hand off a safe read-only handle, call `.freeze()`.

| Method | From | To | Description |
|---|---|---|---|
| `.mut()` | `List<T>` | `MutableList<T>` | Wraps the list for mutation |
| `.mut()` | `Map<K,V>` | `MutableMap<K,V>` | Wraps the map for mutation |
| `.mut()` | `Set<T>` | `MutableSet<T>` | Wraps the set for mutation |
| `.freeze()` | `MutableList<T>` | `List<T>` | Returns the immutable backing list |
| `.freeze()` | `MutableMap<K,V>` | `Map<K,V>` | Returns the immutable backing list |
| `.freeze()` | `MutableSet<T>` | `Set<T>` | Returns the immutable backing map |

**Pattern: build then freeze**

```kotlin
import { List } from "std.collections"

fun main() {
    // Start with an immutable snapshot
    val base: List<Int> = [10, 20]

    // Upgrade to mutable, mutate freely
    val builder = base.mut()
    builder.add(30)
    builder.set(0, 99)

    // Downgrade back to safe, immutable view
    val result = builder.freeze()
    assert(result.size() == 3)
    assert(result[0] == 99)
    assert(result[2] == 30)
}
```

**Pattern: collect into a mutable map, then share immutably**

```kotlin
import { Map } from "std.collections"

fun main() {
    val seed: Map<String, Int> = ["a" of 1]

    val m = seed.mut()
    m["b"] = 2
    m["c"] = 3

    val snapshot = m.freeze()  // safe to pass around
    assert(snapshot["b"] == 2)
}
```

> **Design note:** `.mut()` does not copy the underlying data — the mutable wrapper operates directly on the same internal storage. `.freeze()` returns a reference to that same storage as an immutable handle. This means both operations are **O(1)** regardless of collection size.

---

## 11. Exception Handling (try-catch)

Aether features a native structured exception handling system using `try` and `catch` blocks. All exception types must inherit from the built-in `Exception` base class:

```kotlin
class InvalidAgeException(message: String) : Exception(message)

fun checkAge(age: Int) {
    if (age < 18) {
        throw InvalidAgeException("Idade inválida: " + age.toString())
    }
}
```

Exceptions propagate up function call frames until they encounter a matching handler.

### 11.1 Basic Usage
```kotlin
try {
    checkAge(15)
} catch (e: InvalidAgeException) {
    print("Erro capturado: " + e.message)
}
```

### 11.2 Multi-Catch
You can catch multiple exceptions in a single block using the union syntax `|`. In this case, the caught exception `e` is statically typed as the generic `Exception` base class:
```kotlin
try {
    checkAge(15)
} catch (e: InvalidAgeException | ConnectionException) {
    print("Exceção capturada: " + e.message)
}
```

### 11.3 Catch-All & Swallowing Exceptions
If you omit the variable declaration in a `catch` block, it acts as a **catch-all** that intercepts any exception:
```kotlin
try {
    checkAge(15)
} catch {
    print("Ocorreu um erro genérico.")
}
```

Furthermore, you can write a `try` block **without any catch clauses**. In this scenario, any exception thrown inside the `try` block is caught and swallowed silently:
```kotlin
try {
    checkAge(15) // Exception is caught and ignored
}
```

## 12. Ternary Operators

Aether provides standard ternary conditional expressions and a unique short ternary operator to simplify conditional value assignments.

### 12.1 Standard Ternary Operator

The standard ternary operator uses the classic `condition ? true_expr : false_expr` syntax:

```kotlin
fun max(a: Int, b: Int): Int {
    return (a > b) ? a : b
}
```

* **Type Safety:** The type of the ternary expression is inferred as the common compatible type of both branches. If the branches have incompatible types, the compiler will fail with a `TypeError`.
* **Right-Associativity:** The operator associates to the right, meaning nested ternaries parse naturally:
```kotlin
// In Aether, this evaluates as: a ? b : (c ? d : e)
val result = a ? b : c ? d : e
```

### 12.2 Short Ternary Operator

The short ternary operator `condition ? true_expr` omits the else branch. When the condition is false, it implicitly returns `null`:

```kotlin
fun getAdminRole(isAdmin: Bool): String? {
    return isAdmin ? "Administrator"
}
```

* **Nullable Union Return Type:** Because a short ternary returns `null` when false, its type is automatically promoted to a Union Type with `Null` (e.g. `String?`).
* **Nesting Flattening:** If the positive branch is already a nullable type (like `String?`), the return type is flattened to `String?` rather than nesting (e.g., `String??`).
* **Void Safety:** Since returning `null` implies a value payload, you cannot use expressions returning `Void` inside a short ternary.
```kotlin
// THIS IS A COMPILATION ERROR:
cond ? print("hello") 
```


