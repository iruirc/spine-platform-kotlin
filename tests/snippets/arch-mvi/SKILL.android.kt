enum class Filter { FreeOnly }

@JvmInline value class ResultId(val value: String)

data class ResultRow(val id: ResultId, val title: String)

sealed interface UiMessage

fun <T> Set<T>.toggle(item: T): Set<T> = if (item in this) this - item else this + item

sealed interface SearchEffect {
    data class OpenResult(val id: ResultId) : SearchEffect
}

class SearchViewModel : ViewModel() {
    val state: StateFlow<SearchState> = MutableStateFlow(SearchState())
    val effects: Flow<SearchEffect> = emptyFlow()
    fun dispatch(intent: SearchIntent) {}
}

@Composable fun SearchScreen(state: SearchState, onIntent: (SearchIntent) -> Unit) {}
