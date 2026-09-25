@Serializable
sealed interface Route {
    @Serializable data object Home : Route
    @Serializable data class OrderDetail(val id: String) : Route
    @Serializable data class Search(val query: String? = null) : Route
}

class PendingRoute(handle: SavedStateHandle) {
    val held: StateFlow<String?> get() = TODO()
    fun hold(route: Route): Unit = TODO()
    fun consume(): Route? = TODO()
    fun drop(): Unit = TODO()
}

sealed interface Session {
    data object Loading : Session
    data object SignedOut : Session
    data class SignedIn(val userId: String) : Session
}

class SessionRepository {
    val session: StateFlow<Session> = MutableStateFlow(Session.Loading)
}

@Composable
fun AppNavHost(navController: NavHostController) {}
