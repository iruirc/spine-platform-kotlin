class Timeouts
class Config(val baseUrl: String, val timeouts: Timeouts, val dbPath: String) {
    companion object {
        fun forTests(dbPath: String) = Config("http://localhost", Timeouts(), dbPath)
    }
}
class HttpClient
fun newHttpClient(baseUrl: String, timeouts: Timeouts) = HttpClient()
class Database { companion object { fun open(path: String) = Database() } }
interface OrderRepository
class OrderRepositoryImpl(http: HttpClient, db: Database) : OrderRepository
class PlaceOrder(orders: OrderRepository, clock: Clock)
