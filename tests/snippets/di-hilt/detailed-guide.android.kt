@Serializable @JvmInline value class OrderId(val value: String)
@Serializable data class OrderDetail(val orderId: OrderId)
data class Order(val id: OrderId)
data class OrderDraft(val note: String)

interface OrderRepository {
    fun observe(id: OrderId): Flow<Order> = emptyFlow()
}
interface OrdersApi
class OrderDao @Inject constructor()

interface OrderSync
class WorkManagerOrderSync @Inject constructor() : OrderSync

object BuildConfig { const val API_BASE_URL = "https://example.invalid/" }

sealed interface OrderUiState {
    data object Loading : OrderUiState
    data class Loaded(val order: Order) : OrderUiState
}
@Composable fun OrderDetailContent(state: OrderUiState) {}
@Composable fun OrdersRoot() {}

class AnalyticsEvent
class RemoteAnalyticsSink @Inject constructor() : AnalyticsSink { override fun track(event: AnalyticsEvent) {} }
class LogcatAnalyticsSink @Inject constructor() : AnalyticsSink { override fun track(event: AnalyticsEvent) {} }

interface DeepLinkHandler
class OrdersHandler @Inject constructor() : DeepLinkHandler
class ProfileHandler @Inject constructor() : DeepLinkHandler
