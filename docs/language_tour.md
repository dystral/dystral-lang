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

fun main() {
    val v = Vector(1, 1)
    val r = add(5, 5)
}
```

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
