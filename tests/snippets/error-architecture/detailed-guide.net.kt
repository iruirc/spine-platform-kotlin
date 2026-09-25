class OrderDto
interface OrdersApi { suspend fun order(id: String): OrderDto }
internal fun ResponseBody.problemType(): String? = TODO()
suspend inline fun <T> catching(block: () -> T): Result<T> = TODO()
data class Order(val id: String, val total: Long)
fun OrderDto.toDomain(): Order = TODO()
interface OrderRepository { suspend fun order(id: String): Result<Order> }
