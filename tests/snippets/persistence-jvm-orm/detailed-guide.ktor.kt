@JvmInline value class OrderId(val value: java.util.UUID)

@JvmInline value class CustomerId(val value: java.util.UUID)

enum class OrderStatus { NEW, PAID, SHIPPED }

class Money private constructor(val cents: Long) {
    companion object {
        fun ofCents(cents: Long): Money = Money(cents)
    }
}

data class OrderLine(val sku: String, val quantity: Int, val price: Money)

class PlaceOrderCommand

fun PlaceOrderCommand.toOrder(): Order = TODO()

class DbConfig(val url: String, val user: String, val password: String, val poolSize: Int)
