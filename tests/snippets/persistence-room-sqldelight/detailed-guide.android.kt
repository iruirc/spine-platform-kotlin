@JvmInline value class OrderId(val value: String)
@JvmInline value class CustomerId(val value: String)
enum class OrderStatus { PLACED }
data class OrderLine(val sku: String, val quantity: Int, val unitPriceMinor: Long)
data class Order(val id: OrderId, val customer: CustomerId, val status: OrderStatus, val lines: List<OrderLine>)

internal fun OrderWithLines.toDomain(): Order = TODO()
internal fun Order.toEntity(syncState: String): OrderEntity = TODO()
internal fun OrderLine.toEntity(orderId: OrderId): OrderLineEntity = TODO()
