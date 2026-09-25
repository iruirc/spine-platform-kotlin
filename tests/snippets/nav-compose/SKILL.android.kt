@Composable
fun HomeRoute(onOpenOrder: (String) -> Unit) {}

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

class CheckoutViewModel : ViewModel() {
    fun onCurrencyPicked(code: String) {}
}

class OrderDraftViewModel : ViewModel()

@Composable
fun ShippingRoute(draft: OrderDraftViewModel) {}
