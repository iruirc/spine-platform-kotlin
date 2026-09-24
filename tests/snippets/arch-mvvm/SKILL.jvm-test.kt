typealias IOException = java.io.IOException

class MainDispatcherExtension : org.junit.jupiter.api.extension.Extension

class Order

val beans = Order()
val money = Any()

sealed interface OrdersUiEvent {
    data object Appeared : OrdersUiEvent
    data object RetryClicked : OrdersUiEvent
}

class FakeOrderRepository {
    fun failWith(error: Throwable) {}
    fun succeedWith(orders: List<Order>) {}
}

class OrdersViewModel(repository: FakeOrderRepository, money: Any) {
    val state: StateFlow<OrdersUiState> = MutableStateFlow(OrdersUiState())
    fun onEvent(event: OrdersUiEvent) {}
}
