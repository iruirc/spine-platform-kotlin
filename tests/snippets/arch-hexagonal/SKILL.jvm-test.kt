class PlaceOrderUseCase(
    private val orders: OrderRepository,
    private val payments: PaymentGateway,
    private val time: CurrentTime,
) : PlaceOrder {
    override fun invoke(command: PlaceOrderCommand): Result<Order> = Result.failure(IllegalStateException())
}

val RefusingGateway = PaymentGateway { _, _ -> Result.failure(IllegalStateException("refused")) }

class FixedTime(private val at: Instant) : CurrentTime {
    override fun now(): Instant = at
}

val now = Instant.fromEpochSeconds(0)

val command = PlaceOrderCommand()
