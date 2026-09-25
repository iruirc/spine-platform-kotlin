abstract class AppDatabase : RoomDatabase()

val order = Order(OrderId("o-1"), CustomerId("c-1"), kotlin.time.Instant.fromEpochSeconds(0), OrderStatus.Placed, "EUR", emptyList())

class FakePaymentRepository : PaymentRepository {
    val refunds = mutableListOf<OrderId>()
    override suspend fun refund(id: OrderId, amount: Money): Result<Unit> = Result.success(Unit).also { refunds += id }
}
