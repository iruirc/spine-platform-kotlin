data class OrderDto(val id: String, val total: Long, val currency: String)
data class Page<T>(val items: List<T>, val nextCursor: String? = null)
data class OrdersProperties(val baseUrl: String, val token: String)
class RetryableHttpException(val status: Int, val retryAfterMillis: Long? = null) : RuntimeException("HTTP $status")
