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

Aether features a native type system for dynamic arrays, similar to `List` em Kotlin, along with ergonomic `for` and `while` loops.

**IMPORTANT:** The `[Type]` syntax is purely syntactic sugar for a **strictly immutable** `List<Type>`. You cannot push new elements, pop them, or reassign indices (e.g., `arr[0] = 5`). If you need mutability, you will need to use a mutable collection explicitly (like `MutableList<Type>`, which will be introduced in future phases).

Arrays are declared with `[Type]`, and literals use the `[1, 2, 3]` syntax.

```kotlin
fun main() {
    // Array declaration and initialization
    val numbers = [1, 2, 3, 4, 5]
    
    // Arrays can be accessed by index
    val first = numbers[0]
    
    // For-loops iterate seamlessly over arrays
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
