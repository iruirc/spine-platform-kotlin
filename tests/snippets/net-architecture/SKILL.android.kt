data class OrderDto(val id: String, val total: Long, val currency: String)
data class OrderDraftDto(val lines: List<String>)
data class Order(val id: String)
fun OrderDto.toDomain() = Order(id)
sealed interface DataError
sealed class OrderError : Exception()
fun Throwable.toDataError(): DataError = TODO()
fun DataError.toOrderError(): OrderError = TODO()
data class Token(val access: String, val refreshToken: String) {
    companion object { val NONE = Token("", "") }
}
interface AuthApi { suspend fun refresh(refreshToken: String): Token }
