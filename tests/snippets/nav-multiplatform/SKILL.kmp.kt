@Composable
fun HomeRoute(onOpenOrder: (String) -> Unit) {}

@Composable
fun OrderDetailRoute(id: String, onBack: () -> Unit) {}

data class EditorState(val hasUnsavedChanges: Boolean = false)

@Composable
fun EditorScaffold(state: EditorState, onBack: () -> Unit) {}
