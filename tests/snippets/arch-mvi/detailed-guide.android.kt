suspend inline fun <T> catching(block: () -> T): Result<T> = Result.success(block())

@Composable fun ErrorPane(message: UiMessage, onRetry: () -> Unit) {}

@Composable fun ResultList(rows: List<ResultRow>, onClick: (ResultId) -> Unit) {}
