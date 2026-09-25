@Composable fun OrderCard(row: OrderRow, onClick: (String) -> Unit = {}, modifier: Modifier = Modifier) {}
@Composable fun EmptyState() {}
@Composable fun ScrollToTopButton(listState: LazyListState) {}
@Composable fun OfflineBanner() {}
class OrderDetailViewModel : ViewModel() { fun load(orderId: String) {} }
class AnalyticsTracker { var userId: String? = null }
interface ImageLoader { suspend fun load(url: String): Bitmap }
