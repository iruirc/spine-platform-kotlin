interface OrderRepository
class OrderRepositoryImpl : OrderRepository
interface StockRepository
class StockRepositoryImpl : StockRepository
class PlaceOrder(private val orders: OrderRepository)
class CancelOrder(private val orders: OrderRepository)
val networkModule = module { }

@JvmInline value class OrderId(val value: String)
data class OrdersUiState(val orders: List<OrderId> = emptyList())
sealed interface OrdersEvent
class OrdersViewModel : ViewModel() {
    val state: StateFlow<OrdersUiState> = MutableStateFlow(OrdersUiState())
    fun onEvent(event: OrdersEvent) {}
}
class OrderDetailViewModel(val orderId: OrderId) : ViewModel()
@Composable
fun OrdersContent(state: OrdersUiState, onEvent: (OrdersEvent) -> Unit, onOrder: (OrderId) -> Unit) {}
