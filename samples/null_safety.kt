class User(val name: String, var email: String?) {
    fun greet() {
        // ...
    }
}

fun main() {
    val u: User | null = null

    // Safe call on nullable user
    val safe_email: String? = u?.email
    print(safe_email)

    // Elvis operator
    val fallback: User = u ?: User("Default name", "default@email.com")
    print(fallback.name)
    print(fallback.email)

    // Not-null assertion
    val forced_email: String = fallback.email!!
    print(forced_email)
}
