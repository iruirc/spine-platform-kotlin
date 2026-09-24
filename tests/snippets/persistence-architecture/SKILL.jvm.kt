@JvmInline value class CustomerId(val value: String)
data class Order(val id: String)
data class OrderEntity(val id: String)
data class OrderDto(val id: String)
class OrdersPage(val items: List<OrderDto>)

interface OrderDao {
    fun observeByCustomer(customer: String): Flow<List<OrderEntity>>
    suspend fun upsertAll(rows: List<OrderEntity>)
}

interface OrdersApi {
    suspend fun orders(customer: String): OrdersPage
}

interface OrderRepository {
    fun observe(customer: CustomerId): Flow<List<Order>>
    suspend fun refresh(customer: CustomerId): Result<Unit>
}

fun OrderEntity.toDomain(): Order = TODO()
fun OrderDto.toEntity(): OrderEntity = TODO()

sealed class DataError : Exception()
sealed class OrderError : Exception()
fun Throwable.toDataError(): DataError = TODO()
fun DataError.toOrderError(): OrderError = TODO()

suspend inline fun <T> catching(block: () -> T): Result<T> = TODO()
inline fun <T> Result<T>.mapFailure(transform: (Throwable) -> Throwable): Result<T> = TODO()
