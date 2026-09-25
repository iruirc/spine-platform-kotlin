// Order and OrderRepository are the guide's ktor-marked domain block; a marked block has one module.
data class Order(
    val id: OrderId, val customerId: CustomerId, val placedAt: java.time.Instant,
    val status: OrderStatus, val lines: List<OrderLine>,
)

interface OrderRepository {
    fun byCustomer(customer: CustomerId): List<Order>
    fun byId(id: OrderId): Order?
    fun save(order: Order): Order
}

@JvmInline value class OrderId(val value: java.util.UUID)

@JvmInline value class CustomerId(val value: java.util.UUID)

enum class OrderStatus { NEW, PAID, SHIPPED }

class Money private constructor(val cents: Long) {
    companion object {
        fun ofCents(cents: Long): Money = Money(cents)
    }
}

data class OrderLine(val sku: String, val quantity: Int, val price: Money)

fun Order.toEntity(): OrderEntity = TODO()
