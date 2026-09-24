@Serializable data class OrderDto(val id: String, val total: Long, val currency: String)
@Serializable data class Page<T>(val items: List<T>, val nextCursor: String? = null)
@Serializable data class OrderDraftDto(val lines: List<String>)
interface OrdersApi {
    suspend fun orders(cursor: String?): Page<OrderDto>
    suspend fun order(id: String): OrderDto
    suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto
}
interface SessionStorage {
    suspend fun load(): BearerTokens?
    suspend fun save(tokens: BearerTokens)
}
@Serializable data class RefreshRequest(val refreshToken: String)
@Serializable data class TokenPair(val access: String, val refresh: String)
interface AppLog { fun debug(message: String) }
lateinit var appLog: AppLog
