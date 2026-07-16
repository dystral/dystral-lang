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

Annotations on `lib` blocks instruct the compiler and linker on how to process the native library:
- **`@Header` (Compile-Time Includes)**: Instructs the C Transpiler to inject the corresponding `#include` directives at the top of the generated C file so that C compiler knows about the function signatures, structs, and constants.
- **`@Link` (Linker-Time Libraries)**: Instructs the Aether compiler to append the corresponding `-l<library>` flag (e.g., `-lcurl`) during the linking phase, and injects `-DAETHER_USE_<LIBRARY>` preprocessor definitions into the C compiler.
- **`@Alias` (Function Names Mapping)**: Placed on individual functions inside `lib` blocks to map Aether `camelCase` function names to the corresponding C `snake_case` library functions.

```kotlin
// http.ae (FFI declaration using Header, Link, and Alias)
@Link("curl")
@Header("<curl/curl.h>")
lib NativeHttp {
    @Alias("curl_easy_init")
    fun curlEasyInit(): OpaquePointer
    
    @Alias("curl_easy_perform")
    fun curlEasyPerform(curl: OpaquePointer): Int
    
    @Alias("curl_easy_cleanup")
    fun curlEasyCleanup(curl: OpaquePointer): Void
}
```

You can then import and use these native functions exactly like standard Aether code:

```kotlin
import { NativeHttp } from "http"

val curl = NativeHttp.curlEasyInit()
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

---

## 13. Pattern Matching (when Expressions)

Aether supports Kotlin-style `when` expressions for flexible conditional branching. It can act both as an expression (evaluating to a value) or as a statement (for side effects).

### 13.1 Basic Usage (With Subject)
You can match a subject expression against multiple values separated by commas:

```kotlin
val code = 404
val message = when (code) {
    200 -> "OK"
    401, 403 -> "Unauthorized Access"
    404 -> "Not Found"
    else -> "Unknown Error"
}
assert(message == "Not Found")
```

* **Exhaustiveness:** If `when` is used as an expression (to assign a value), the `else` branch is **mandatory**. If used as a statement, `else` is optional.

### 13.2 Smart Casting via Type Check
Aether integrates pattern matching with its class hierarchy and polymorphism. If you match a stable variable against a type using `is Type`, the variable is automatically **smart-cast** inside that branch's scope:

```kotlin
open class Shape
class Circle(val radius: Int) : Shape()
class Square(val side: Int) : Shape()

fun printArea(shape: Shape) {
    when (shape) {
        is Circle -> {
            // 'shape' is smart-cast to Circle here
            print("Circle Area: " + (shape.radius * shape.radius).toString())
        }
        is Square -> {
            // 'shape' is smart-cast to Square here
            print("Square Area: " + (shape.side * shape.side).toString())
        }
        else -> print("Unknown shape")
    }
}
```

### 13.3 Subjectless when
If you omit the subject, the `when` expression acts as a cleaner alternative to `if-else if-else` chains. Each branch condition must evaluate to a `Bool`:

```kotlin
val x = 10
val y = 20


when {
    x > y -> print("x is greater")
    x < y -> print("y is greater")
    else -> print("they are equal")
}
```
---

## 14. Default Parameters

Aether supports default values for parameters in functions, methods, and class constructors (both generic and non-generic). This reduces the need for overloading and simplifies constructor instantiations.

```kotlin
// Function with default parameters
fun greet(name: String, greeting: String = "Hello") = greeting + ", " + name + "!"

class Server(val tcpServer: TCPServer = TCPServer())

fun main() {
    // Uses the default greeting "Hello"
    print(greet("Alice")) // "Hello, Alice!"
    
    // Overrides the default greeting
    print(greet("Bob", "Hi")) // "Hi, Bob!"
    
    // Instantiates Server using default constructor parameter (which calls TCPServer())
    val server = Server()
}
```

Statically typed defaults are evaluated and type-checked during function and class declarations. If a caller omits an argument that has a default value, the type checker automatically clones and injects the default expression at the call-site.

---

## 15. Lambda Expressions & Higher-Order Functions

Aether supports functional programming paradigms via lambdas (anonymous function literals) and Higher-Order Functions (functions that accept functions as arguments or return them).

### 15.1 Function Types
A function type represents a reference to a function. Its syntax is `(ParamType1, ParamType2, ...) -> ReturnType`.

```kotlin
// Declaring a variable holding a function that takes two Ints and returns an Int
val sum: (Int, Int) -> Int = { x: Int, y: Int -> x + y }

// Invocations are natural
val result = sum(10, 20)
assert(result == 30)
```

### 15.2 Lambda Literals & Implicit `it`
Lambdas are enclosed in curly braces `{}`. If a lambda has parameters, they are declared before the arrow `->`. If the lambda has only one parameter, you can omit its declaration and access it via the implicit name `it`.

```kotlin
// Explicit parameter
val double = { x: Int -> x * 2 }

// Implicit 'it' parameter (type inferred as Int from the context)
val triple: (Int) -> Int = { it * 3 }

assert(triple(5) == 15)
```

### 15.3 Scope Capturing (Closures)
Lambdas can capture variables from their surrounding lexical scope. If a captured variable is mutable (`var`), the Aether compiler automatically wraps it in a heap-allocated box so that changes are visible both inside the lambda and in the outer scope, even after the outer function exits.

```kotlin
fun makeCounter(): () -> Int {
    var count = 0
    return {
        count = count + 1
        count
    }
}

fun main() {
    val counter = makeCounter()
    assert(counter() == 1)
    assert(counter() == 2)
}
```

### 15.4 Trailing Lambdas & DSLs
If the last parameter of a function is a function type, the lambda expression can be passed outside of the function call parentheses. If it is the only parameter, the parentheses can be completely omitted. This is extremely powerful for building clean DSLs:

```kotlin
class HTMLBuilder {
    var content: String = ""
    fun body(init: () -> String) {
        this.content = this.content + "<body>" + init() + "</body>"
    }
}

fun html(init: HTMLBuilder.() -> Void): String {
    val builder = HTMLBuilder()
    init(builder)
    return "<html>" + builder.content + "</html>"
}

fun main() {
    // Parentheses are completely omitted for the trailing lambda
    val result = html {
        body {
            "Hello Aether DSL!"
        }
    }
    assert(result == "<html><body>Hello Aether DSL!</body></html>")
}
```

## 16. Objects & Boundless Namespaces
Objects allow grouping static variables and functions under a class namespace. In Aether, this is declared using the `object` keyword.

### 16.1 Named Standalone Objects (Singletons)
You can also declare standalone named `object` blocks which act as singletons or modules:

```kotlin
object Database {
    var queryCount = 0
    
    fun execute(query: String): String {
        this.queryCount = this.queryCount + 1
        return "Result of: " + query
    }
}

fun main() {
    assert(Database.queryCount == 0)
    val result = Database.execute("SELECT * FROM users")
    assert(Database.queryCount == 1)
}
```

### 16.2 Class-Bound Objects
An anonymous `object` block that immediately follows or precedes a `class` definition binds its members to the class namespace.

#### Same-Line Syntax Constraint
To emphasize that the class-bound object/class definition is a continuation of the class/object scope, Aether enforces that the anonymous block **must start on the same line** as the closing brace `}` of the sibling block. Separating them with a newline will trigger a compile-time syntax error.

#### Class-First Declaration
When the class is declared first, the anonymous `object` block is declared immediately after the class closing brace `} object {`:

```kotlin
class File(val path: String) {
    fun read(): String {
        return "Content of " + this.path
    }
} object {
    val defaultPath = "/tmp/aether.txt"
    
    fun create(path: String): File {
        return File(path)
    }
}

fun main() {
    // Access static members directly on the class name
    val path = File.defaultPath
    val file = File.create(path)
    
    // Access instance methods on the instantiated class object
    assert(file.read() == "Content of /tmp/aether.txt")
}
```

#### Object-First Declaration (Vice-Versa)
Alternatively, you can declare the named `object` first, followed immediately by the anonymous `class` definition on the same line `} class(...) {`:

```kotlin
object Configuration {
    val defaultPrefix = "SYS_"
    var loadCount = 0
    
    fun createSystem(name: String): Configuration {
        Configuration.loadCount = Configuration.loadCount + 1
        return Configuration(Configuration.defaultPrefix + name)
    }
} class (val name: String) {
    fun getFormatted(): String {
        return "Config:" + this.name
    }
}

fun main() {
    // Access static members on the object/class namespace
    assert(Configuration.loadCount == 0)
    val config = Configuration.createSystem("DB")
    assert(Configuration.loadCount == 1)
    
    // Access instance methods on the created configuration instances
    assert(config.getFormatted() == "Config:SYS_DB")
}
```

## 17. Environment Variables (`std.env`)
The `std.env` module provides tools to load environment variables from `.env` files and interact with the process's environment. Like `std.core`, `std.collections`, and `std.time`, the `std.env` module is **implicitly imported** by the compiler into every program, so no `import` statement is required.

### 17.1 Loading `.env` files
Use `Env.load()` to load an environment configuration. If no path is provided, Aether looks for `.env` in the current directory. This returns `false` silently if the file is not found.

```kotlin
fun main() {
    // Loads .env from current directory (returns true if loaded, false if not found)
    Env.load()
    
    // Or specify a custom path
    Env.load("configs/local.env")
}
```

### 17.2 Reading Variables
You can query variables using `Env.get`. If a get/check is performed before `Env.load()` is explicitly invoked, Aether automatically attempts to load the default `.env` file first.

```kotlin
fun main() {
    // Nullable string retrieval
    val host: String? = Env.get("DB_HOST")
    
    // Retrieval with default fallback values (String, Int, Bool overloads)
    val port: Int = Env.get("DB_PORT", 5432)
    val database: String = Env.get("DB_NAME", "production")
    val isDebug: Bool = Env.get("DEBUG", false)
}
```

### 17.3 Global `env()` Helper
For fast, zero-boilerplate configuration lookup, Aether provides overloaded global `env()` helper functions (which delegate directly to `Env.get`):

```kotlin
fun main() {
    // Nullable string retrieval
    val host: String? = env("DB_HOST")
    
    // Retrieval with default fallback values (String, Int, Bool overloads)
    val port: Int = env("DB_PORT", 5432)
    val database: String = env("DB_NAME", "production")
    val isDebug: Bool = env("DEBUG", false)
}
```

### 17.4 Modifying and Checking Variables
Aether allows setting, unsetting, and checking for the existence of environment variables:

```kotlin
fun main() {
    // Check if variable exists
    if (Env.exists("API_KEY") == false) {
        Env.set("API_KEY", "default-secret-key")
    }
    
    // Unset a variable
    Env.unset("TEMP_TOKEN")
}
```

---

## 18. String Escape Sequences

Aether supports Kotlin-style backslash escape sequences inside double-quoted string literals. The following escape sequences are recognized and processed by the compiler:

* `\"` – Double quote
* `\\` – Backslash
* `\n` – Newline
* `\r` – Carriage return
* `\t` – Tab
* `\b` – Backspace
* `\'` – Single quote

```kotlin
fun main() {
    val escapedQuote = "Ele disse \"Ola\""
    val backslash = "C:\\aether\\bin"
    val multiline = "Primeira Linha\nSegunda Linha"
    
    assert(escapedQuote.length == 15) // counts exact characters (excluding the backslash escape character)
}
```

The compiler's Type Checker automatically calculates the correct length of string literals in bytes after resolving these escape sequences, ensuring complete compatibility with standard library functions and C runtime operations.








