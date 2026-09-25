data class OrderDto(val id: String, val total: Long, val currency: String)
data class OrderDraftDto(val lines: List<String>)
data class Page<T>(val items: List<T>, val nextCursor: String?)
interface OrdersApi {
    suspend fun orders(cursor: String?): Page<OrderDto>
    suspend fun order(id: String): OrderDto
    suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto
}
