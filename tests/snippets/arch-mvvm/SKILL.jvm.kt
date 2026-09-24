sealed interface UiMessage {
    data object Offline : UiMessage
}

data class OrderRow(val title: String)
