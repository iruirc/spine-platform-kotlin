suspend inline fun <T> catching(block: () -> T): Result<T> = Result.success(block())

@Composable fun LoadingPane(modifier: Modifier = Modifier) {}

@Composable fun ErrorPane(message: UiMessage, onRetry: () -> Unit, modifier: Modifier = Modifier) {}

@Composable fun OrderCard(row: OrderRow, onClick: () -> Unit) {}

@Composable fun AppTheme(content: @Composable () -> Unit) = content()

@Module
@InstallIn(SingletonComponent::class)
object OrdersBindings {
    @Provides fun repository(): OrderRepository = FakeOrderRepository()
    @Provides fun money(): MoneyFormatter = MoneyFormatter()
}
