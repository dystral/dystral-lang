class Vector(val x: Int, val y: Int) {
    operator fun plus(other: Vector) = Vector(self.x + other.x, self.y + other.y)
}

fun main() {
    val a = Vector(10, 5)
    val b = Vector(2, 3)
    val c = a + b
    print(c.x)
    print(c.y)
    
    val s1 = "Desugaring "
    val s2 = "Works!"
    print(s1 + s2)
}
