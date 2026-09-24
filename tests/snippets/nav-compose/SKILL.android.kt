@Serializable
sealed interface Route {
    @Serializable data class OrderDetail(val id: String) : Route
    @Serializable data class Invoice(val id: String) : Route
}

data class OrderDetailUiState(val title: String = "")
sealed interface OrderDetailEvent
sealed interface OrderDetailEffect {
    data object Saved : OrderDetailEffect
}

class OrderDetailViewModel : ViewModel() {
    val state: StateFlow<OrderDetailUiState> = MutableStateFlow(OrderDetailUiState())
    val effects: Flow<OrderDetailEffect> = emptyFlow()
    fun onEvent(event: OrderDetailEvent) {}
}

@Composable
fun OrderDetailScreen(
    state: OrderDetailUiState,
    onEvent: (OrderDetailEvent) -> Unit,
    onBack: () -> Unit,
    onOpenInvoice: (String) -> Unit,
) {}
