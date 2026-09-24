data class OrderDto(val id: String, val total: Long, val currency: String)
data class Page<T>(val items: List<T>, val nextCursor: String?)
interface OrdersApi { suspend fun orders(cursor: String?): Page<OrderDto> }
data class Order(val id: String)
fun OrderDto.toDomain() = Order(id)
sealed interface DataError
sealed class OrderError : Exception()
fun Throwable.toDataError(): DataError = TODO()
fun DataError.toOrderError(): OrderError = TODO()
