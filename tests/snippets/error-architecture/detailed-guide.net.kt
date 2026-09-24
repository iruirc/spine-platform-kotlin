class OrderDto
interface OrdersApi { suspend fun order(id: String): OrderDto }
internal fun ResponseBody.problemType(): String? = TODO()
suspend inline fun <T> catching(block: () -> T): Result<T> = TODO()
inline fun <T> Result<T>.mapFailure(transform: (Throwable) -> Throwable): Result<T> = TODO()
