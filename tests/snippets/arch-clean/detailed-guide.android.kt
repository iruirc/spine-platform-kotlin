suspend inline fun <T> catching(block: () -> T): Result<T> = Result.success(block())

inline fun <T> Result<T>.mapFailure(transform: (Throwable) -> Throwable): Result<T> = this

internal sealed class DataError : Exception() {
    data class Unreachable(val transport: java.io.IOException) : DataError()
    data class Http(val status: Int, val problemType: String?) : DataError()
    data class Malformed(val error: Throwable) : DataError()
    data object Empty : DataError()
}

internal fun okhttp3.ResponseBody.problemType(): String? = null

interface PaymentRepository {
    suspend fun refund(id: OrderId, amount: Money): Result<Unit>
}

object R {
    object string {
        const val orders_offline = 1
        const val orders_not_found = 2
        const val orders_unexpected = 3
    }
}

sealed interface UiMessage {
    data class Resource(val id: Int) : UiMessage
}

data class OrderRow(val id: String, val title: String, val subtitle: String, val total: String)

sealed interface OrdersUiState {
    data object Loading : OrdersUiState
    data class Content(val rows: List<OrderRow>) : OrdersUiState
    data class Error(val message: UiMessage) : OrdersUiState
}

sealed interface OrdersUiEvent {
    data object Appeared : OrdersUiEvent
    data object RetryClicked : OrdersUiEvent
}
