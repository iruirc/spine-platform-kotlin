@JvmInline value class OrderId(val value: String)

data class OrderLine(val sku: String, val quantity: Int)

data class Order(val id: OrderId, val placedAt: Instant, val lines: List<OrderLine>)

fun orderLine(): OrderLine = OrderLine("sku-1", 1)
